#!/usr/bin/env python3
'''Pure reliability primitives for the RHOV BSOD detector (no cluster client).

USAGE
    reliability.py decision --misses N --threshold N --domstate S --vmi-phase P [--pvpanic] [--pod-present]
    reliability.py domstats --device DEV
    reliability.py progress-step --device DEV --state FILE [--idle-samples N]
    reliability.py validate-artifact --type T --path FILE
    reliability.py write-summary --out DIR --stage-errors FILE --mode MODE --vm VM --namespace NS [--filename F] [--run-id ID]
    reliability.py map-disk --vmi-json FILE --domain-xml FILE [--target DEV]

Details: apps/bsod-detector/src/scripts/host/README.md
'''

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import tarfile
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


def Emit(value: dict, exitCode: int = 0) -> None:
    '''Print one JSON object on STDOUT and exit with `exitCode`.'''
    print(json.dumps(value, sort_keys=True))
    raise SystemExit(exitCode)


def CrashDecision(args: argparse.Namespace) -> None:
    '''Decide observe / capture / fail from QGA miss count, domstate, VMI phase and pvpanic.'''
    state = args.domstate.strip().lower() or 'unavailable'
    phase = args.vmi_phase.strip().lower() or 'unavailable'
    if args.misses < args.threshold:
        Emit({'decision': 'observe', 'reason': 'threshold-not-reached'})
    if args.pvpanic:
        Emit({'decision': 'capture', 'reason': 'current-pvpanic-event'})
    if phase not in {'running', 'scheduled'}:
        Emit({'decision': 'fail', 'reason': f'vmi-phase-{phase}'}, 1)
    if not args.pod_present:
        Emit({'decision': 'fail', 'reason': 'launcher-unavailable'}, 1)
    if state in {'crashed', 'paused', 'pmsuspended', 'running'}:
        Emit({'decision': 'capture', 'reason': f'qga-threshold-domstate-{state}'})
    Emit({'decision': 'fail', 'reason': f'ambiguous-domstate-{state}'}, 1)


def ParseDomstats(text: str, device: str) -> int:
    '''Return write-byte count for `device` from virsh domstats text, or raise ValueError.'''
    names: dict[str, str] = {}
    writes: dict[str, int] = {}
    for raw in text.splitlines():
        line = raw.strip()
        match = re.fullmatch(r'block\.(\d+)\.name=(.+)', line)
        if match:
            names[match.group(1)] = match.group(2).strip()
            continue
        match = re.fullmatch(r'block\.(\d+)\.wr\.bytes=(\d+)', line)
        if match:
            writes[match.group(1)] = int(match.group(2))
    indexes = [index for index, name in names.items() if name == device]
    if len(indexes) != 1 or indexes[0] not in writes:
        raise ValueError(f'statistics unavailable for disk target {device}')
    return writes[indexes[0]]


def Domstats(args: argparse.Namespace) -> None:
    '''Parse domstats from STDIN for `--device` and emit writeBytes.'''
    try:
        value = ParseDomstats(sys.stdin.read(), args.device)
    except ValueError as exc:
        Emit({'status': 'unavailable', 'reason': str(exc)}, 1)
    Emit({'status': 'ok', 'device': args.device, 'writeBytes': value})


def InitialProgressState(device: str) -> dict:
    '''Empty progress state machine for one disk target.'''
    return {
        'device': device,
        'last': None,
        'observedProgress': False,
        'idleSamples': 0,
        'samples': 0,
    }


def AdvanceProgress(state: dict, current: int, idleSamples: int) -> dict:
    '''Advance dump-write progress; JSON field names stay camelCase for callers.'''
    last = state['last']
    state['samples'] += 1
    if last is None:
        status, reason = 'waiting', 'baseline-recorded'
    elif current < last:
        status, reason = 'failure', 'write-counter-regressed'
    elif current > last:
        state['observedProgress'] = True
        state['idleSamples'] = 0
        status, reason = 'waiting', 'write-progress'
    elif state['observedProgress']:
        state['idleSamples'] += 1
        if state['idleSamples'] >= idleSamples:
            status, reason = 'complete', 'progress-then-quiescence'
        else:
            status, reason = 'waiting', 'quiescing'
    else:
        # No writes since baseline: MEMORY.DMP may already be complete (AutoReboot=0).
        state['idleSamples'] += 1
        if state['idleSamples'] >= idleSamples:
            status, reason = 'complete', 'pre-quiescent-at-baseline'
        else:
            status, reason = 'waiting', 'no-progress-observed'
    state['last'] = current
    return {'status': status, 'reason': reason, 'writeBytes': current, **state}


def ProgressStep(args: argparse.Namespace) -> None:
    '''Load state, parse one domstats sample from STDIN, advance, persist, emit.'''
    statePath = Path(args.state)
    state = (
        json.loads(statePath.read_text(encoding='utf-8'))
        if statePath.exists()
        else InitialProgressState(args.device)
    )
    if state.get('device') != args.device:
        Emit({'status': 'failure', 'reason': 'disk-target-changed'}, 1)
    try:
        current = ParseDomstats(sys.stdin.read(), args.device)
    except ValueError as exc:
        Emit({'status': 'failure', 'reason': 'statistics-unavailable', 'detail': str(exc)}, 1)
    result = AdvanceProgress(state, current, args.idle_samples)
    statePath.write_text(json.dumps(state, sort_keys=True), encoding='utf-8')
    Emit(result, 1 if result['status'] == 'failure' else 0)




def ValidatePng(path: Path) -> bool:
    '''Verify PNG signature, chunk CRCs, IHDR and IEND.'''
    data = path.read_bytes()
    if len(data) < 45 or not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return False
    offset = 8
    seenIhdr = False
    while offset + 12 <= len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            return False
        chunkType = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        expectedCrc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        if zlib.crc32(chunkType + payload) & 0xFFFFFFFF != expectedCrc:
            return False
        if not seenIhdr:
            if chunkType != b'IHDR' or length != 13:
                return False
            width, height = struct.unpack_from('>II', payload)[0:2]
            if width == 0 or height == 0:
                return False
            seenIhdr = True
        if chunkType == b'IEND':
            return length == 0 and end == len(data)
        offset = end
    return False


def ElfCoreLayout(header: bytes) -> tuple[int, str, int, int, int, int] | None:
    '''Parse ET_CORE ELF header: (class, order, headerSize, phOffset, entrySize, count).'''
    if len(header) < 64 or header[:4] != b'\x7fELF' or header[6] != 1:
        return None
    elfClass, endian = header[4], header[5]
    if elfClass not in {1, 2} or endian not in {1, 2}:
        return None
    order = '<' if endian == 1 else '>'
    if struct.unpack_from(order + 'H', header, 0x10)[0] != 4:
        return None
    headerSize = struct.unpack_from(order + 'H', header, 0x34 if elfClass == 2 else 0x28)[0]
    # KubeVirt memory dumps may set e_ehsize=0; accept standard size or 0.
    expected = 64 if elfClass == 2 else 52
    if headerSize not in (expected, 0):
        return None
    if headerSize == 0:
        headerSize = expected
    if elfClass == 2:
        programOffset = struct.unpack_from(order + 'Q', header, 0x20)[0]
        entrySize, count = struct.unpack_from(order + 'HH', header, 0x36)
    else:
        programOffset = struct.unpack_from(order + 'I', header, 0x1C)[0]
        entrySize, count = struct.unpack_from(order + 'HH', header, 0x2A)
    minEntry = 56 if elfClass == 2 else 32
    if count == 0 or entrySize < minEntry or count > 65535:
        return None
    return elfClass, order, headerSize, programOffset, entrySize, count


def ValidateElf(path: Path, data: bytes, innerSize: int = 0) -> bool:
    '''Validate bare ELF ET_CORE extents and trailing zeros via ElfCoreLayout.'''
    layout = ElfCoreLayout(data)
    if layout is None:
        return False
    elfClass, order, headerSize, programOffset, entrySize, count = layout
    tableSize = entrySize * count
    bound = innerSize if innerSize > 0 else path.stat().st_size
    if programOffset < headerSize or programOffset + tableSize > bound or tableSize > 16 * 1024 * 1024:
        return False
    with path.open('rb') as stream:
        stream.seek(programOffset)
        table = stream.read(tableSize)
    maximum = programOffset + tableSize
    for index in range(count):
        entry = table[index * entrySize:(index + 1) * entrySize]
        if elfClass == 2:
            fileOffset = struct.unpack_from(order + 'Q', entry, 8)[0]
            fileSize = struct.unpack_from(order + 'Q', entry, 32)[0]
        else:
            fileOffset = struct.unpack_from(order + 'I', entry, 4)[0]
            fileSize = struct.unpack_from(order + 'I', entry, 16)[0]
        maximum = max(maximum, fileOffset + fileSize)
    if maximum > path.stat().st_size:
        return False
    with path.open('rb') as stream:
        stream.seek(maximum)
        trailing = stream.read()
    return not trailing or all(byte == 0 for byte in trailing)


def ValidateMemoryTargz(path: Path) -> tuple[bool, str]:
    '''Validate virtctl memory-dump tar.gz: exactly one *.memory.dump ET_CORE member.'''
    try:
        with tarfile.open(str(path), 'r:gz') as tar:
            members = tar.getmembers()
        dumpMembers = [m for m in members if m.isfile() and m.name.endswith('.memory.dump')]
        if len(dumpMembers) != 1:
            return False, f'tar.gz[expected-1-dump-member,got-{len(dumpMembers)}]'
        member = dumpMembers[0]
        if member.size < 64:
            return False, 'tar.gz[elf-too-small]'
        with tarfile.open(str(path), 'r:gz') as tar:
            handle = tar.extractfile(member)
            if handle is None:
                return False, 'tar.gz[member-unreadable]'
            elfBytes = handle.read(64)
        # KubeVirt memory dumps use non-standard ELF headers (e_ehsize=0, e_phentsize=0).
        # Validate by checking ELF magic + ET_CORE type only.
        if len(elfBytes) < 16 or elfBytes[:4] != b'\x7fELF':
            return False, 'tar.gz[not-elf]'
        endian = '<' if elfBytes[5] == 1 else '>'
        eType = struct.unpack_from(endian + 'H', elfBytes, 0x10)[0]
        if eType != 4:  # ET_CORE = 4
            return False, 'tar.gz[not-elf]'
        layout = ElfCoreLayout(elfBytes)
        if layout is None:
            return True, 'tar.gz[elf]'  # ELF magic + ET_CORE confirmed; layout non-standard
        _class, _order, _hdr, phOffset, phEntrySize, phCount = layout
        if phOffset + phEntrySize * phCount > member.size:
            return False, 'tar.gz[elf-phdr-outside-member]'
        return True, 'tar.gz[elf]'
    except (tarfile.TarError, EOFError, OSError, struct.error):
        return False, 'tar.gz-corrupt'
    except Exception:
        return False, 'tar.gz-corrupt'


def ValidateDump(path: Path) -> tuple[bool, str]:
    '''Validate MEMORY.DMP: check for Windows full memory dump PAGEDU64 signature.'''
    try:
        with path.open('rb') as stream:
            header = stream.read(8)
        if header == b'PAGEDU64':
            return True, 'dump'
        return False, 'dump[invalid-signature]'
    except OSError:
        return False, 'dump[unreadable]'


def ValidateEvtx(data: bytes) -> bool:
    '''Check EVTX magic only — crash-consistent snapshots may have FileFlags=1 at 0x78.'''
    return len(data) >= 4096 and data.startswith(b'ElfFile\x00')


def ArtifactType(path: Path, requested: str) -> tuple[bool, str]:
    '''Classify and structurally validate one artifact for the requested kind.'''
    with path.open('rb') as stream:
        data = stream.read(4096)
    if requested == 'screenshot':
        if data.startswith(b'\x89PNG\r\n\x1a\n'):
            return ValidatePng(path), 'png'
        return False, 'unknown'
    if requested == 'memory':
        if data[:2] == b'\x1f\x8b':
            return ValidateMemoryTargz(path)
        return ValidateElf(path, data), 'elf'
    if requested == 'evtx':
        return ValidateEvtx(data), 'evtx'
    if requested == 'dump':
        return ValidateDump(path)
    if requested == 'json':
        try:
            json.loads(path.read_text(encoding='utf-8'))
            return True, 'json'
        except (json.JSONDecodeError, UnicodeDecodeError):
            return False, 'invalid-json'
    return bool(data) and b'\x00' not in data[:4096], 'text'


def Sha256File(path: Path) -> str:
    '''Return the hex SHA-256 digest of `path`.'''
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def ValidateArtifact(args: argparse.Namespace) -> None:
    '''Validate one file and emit format + sha256, or fail with a structured error.'''
    path = Path(args.path)
    if not path.is_file() or path.stat().st_size <= 0:
        Emit({'ok': False, 'path': str(path), 'error': 'missing-or-empty'}, 1)
    valid, detected = ArtifactType(path, args.type)
    if not valid:
        Emit({'ok': False, 'path': str(path), 'error': 'invalid-signature', 'format': detected}, 1)
    digest = Sha256File(path)
    Emit({
        'ok': True,
        'path': str(path),
        'size': path.stat().st_size,
        'format': detected,
        'sha256': digest,
    })


def Classify(path: Path) -> str | None:
    '''Map a filename to an artifact kind, or None if unclassified.'''
    name = path.name.lower()
    if name == 'checksums.sha256':
        return 'checksums'
    if name.endswith('.png') and 'screenshot' in name:
        return 'screenshot'
    if (name.endswith('.elf') or name.endswith('.elf.tar.gz')) and 'memory' in name:
        return 'memory'
    if name.endswith('.dmp'):
        return 'dump'
    if name.endswith('.evtx'):
        return 'evtx'
    if name.endswith('.json'):
        return 'json'
    if name.endswith(('.log', '.xml')):
        return 'log'
    return None


REQUIRED_TYPES = {
    'natural-rhov': {'screenshot', 'memory', 'evtx', 'log', 'json', 'checksums'},
    'intentional-rhov': {'screenshot', 'memory', 'log', 'json'},
    # dump not required (KVM pagefile / VirtIO Balloon); evtx may live under guestFS_* only
    'rhov-snapshot-recovery': {'memory', 'evtx', 'json', 'checksums'},
    'fixture': {'screenshot', 'memory', 'evtx', 'log'},
}

SEMANTIC_RESULTS = {'parse-dump-header.json', 'events.json'}
REQUIRED_RESULT_FILES = {
    'natural-rhov': SEMANTIC_RESULTS,
    'intentional-rhov': set(),
    'rhov-snapshot-recovery': SEMANTIC_RESULTS,
}

# Summary files written after checksums.sha256 — never expected in the manifest.
SUMMARY_EXCLUDED = {
    'evidence-summary.json',
    'recovery-summary.json',
    'extraction-summary.json',
}


def WriteSummary(args: argparse.Namespace) -> None:
    '''Scan artifacts, enforce fail-closed checksums, write evidence-summary.json.'''
    out = Path(args.out).resolve()
    stageErrors: list[dict] = []
    stageFile = Path(args.stage_errors)
    if stageFile.exists():
        for number, line in enumerate(stageFile.read_text(encoding='utf-8').splitlines(), 1):
            if not line.strip():
                continue
            try:
                stageErrors.append(json.loads(line))
            except json.JSONDecodeError:
                stageErrors.append({'stage': 'summary', 'error': f'invalid stage error line {number}'})

    artifacts: list[dict] = []
    invalid: list[dict] = []
    required = REQUIRED_TYPES.get(args.mode)
    if required is None:
        stageErrors.append({'stage': 'summary', 'error': f'unknown summary mode: {args.mode}'})
        required = set()
    found = {kind: 0 for kind in required}

    manifestHashes: dict[str, str] = {}
    manifestPath = out / 'checksums.sha256'
    manifestPresent = manifestPath.exists()
    if manifestPresent:
        seenManifestPaths: set[str] = set()
        for lineNum, line in enumerate(manifestPath.read_text(encoding='utf-8').splitlines(), 1):
            if not line.strip() or line.startswith('#'):
                continue
            parts = line.split(maxsplit=1)
            if len(parts) != 2 or not re.fullmatch(r'[0-9a-f]{64}', parts[0]):
                stageErrors.append({
                    'stage': 'checksum',
                    'error': f'malformed manifest entry at line {lineNum}',
                })
                continue
            pathKey = parts[1].strip().lstrip('./').lstrip('/')
            if not pathKey:
                stageErrors.append({
                    'stage': 'checksum',
                    'error': f'empty path in manifest at line {lineNum}',
                })
                continue
            if pathKey in seenManifestPaths:
                stageErrors.append({
                    'stage': 'checksum',
                    'error': f'duplicate manifest entry: {pathKey}',
                })
                continue
            seenManifestPaths.add(pathKey)
            manifestHashes[pathKey] = parts[0]

    for path in sorted(out.rglob('*')):
        if not path.is_file() or path.is_symlink() or path.name in SUMMARY_EXCLUDED or path == stageFile:
            continue
        kind = Classify(path)
        if kind is None:
            continue
        valid, detected = ArtifactType(path, kind)
        semanticError = None
        if valid and path.name in SEMANTIC_RESULTS:
            value = json.loads(path.read_text(encoding='utf-8'))
            if value.get('ok') is not True:
                valid = False
                semanticError = 'stage-result-reports-failure'

        actualHash = Sha256File(path)
        relativePath = str(path.relative_to(out))
        # Logs and checksums.sha256 are exempt from manifest coverage.
        if manifestPresent and kind != 'log' and relativePath != 'checksums.sha256':
            if relativePath not in manifestHashes:
                valid = False
                semanticError = semanticError or 'manifest-entry-missing'
            elif manifestHashes[relativePath] != actualHash:
                valid = False
                semanticError = 'manifest-hash-mismatch'

        record = {
            'path': relativePath,
            'type': kind,
            'format': detected,
            'size': path.stat().st_size,
            'sha256': actualHash,
            'valid': valid,
        }
        if semanticError:
            record['error'] = semanticError
        artifacts.append(record)
        if valid and kind in found:
            found[kind] += 1
        if not valid:
            invalid.append(record)

    if manifestPresent and manifestHashes:
        for orphan in sorted(manifestHashes.keys()):
            if not (out / orphan).exists():
                stageErrors.append({
                    'stage': 'checksum',
                    'error': f'manifest entry without file: {orphan}',
                })

    missing = sorted(kind for kind, count in found.items() if count == 0)
    artifactPaths = {item['path'] for item in artifacts}
    for filename in sorted(REQUIRED_RESULT_FILES.get(args.mode, set())):
        if filename not in artifactPaths:
            missing.append(f'json:{filename}')
    # Only required-type invalid artifacts flip ok; supplementary dump stays visible.
    invalidRequired = [item for item in invalid if item['type'] in (required or set())]
    ok = not stageErrors and not invalidRequired and not missing
    summary = {
        'ok': ok,
        'mode': args.mode,
        'vm': args.vm,
        'namespace': args.namespace,
        'runId': args.run_id,
        'artifacts': artifacts,
        'stageErrors': stageErrors,
        'invalidArtifacts': invalid,
        'missingRequiredArtifactTypes': missing,
    }
    target = out / args.filename
    temporary = target.with_suffix(target.suffix + '.tmp')
    temporary.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    os.replace(temporary, target)
    print(json.dumps(summary, sort_keys=True))
    raise SystemExit(0 if ok else 1)


def MapDisk(args: argparse.Namespace) -> None:
    '''Map a libvirt disk target to a unique VMI PVC/DataVolume claim.'''
    try:
        vmi = json.loads(Path(args.vmi_json).read_text(encoding='utf-8'))
        root = ET.parse(args.domain_xml).getroot()
    except (OSError, json.JSONDecodeError, ET.ParseError) as exc:
        Emit({'ok': False, 'error': f'invalid mapping input: {exc}'}, 1)

    targets: dict[str, str] = {}
    for disk in root.findall('.//devices/disk'):
        target = disk.find('target')
        alias = disk.find('alias')
        if target is None or alias is None:
            continue
        device = target.get('dev', '')
        aliasName = alias.get('name', '')
        if aliasName.startswith('ua-') and device:
            targets[device] = aliasName[3:]

    volumes = {item.get('name'): item for item in vmi.get('spec', {}).get('volumes', [])}
    candidates = []
    for target, diskName in targets.items():
        if args.target and target != args.target:
            continue
        volume = volumes.get(diskName, {})
        claim = (volume.get('persistentVolumeClaim') or {}).get('claimName')
        claim = claim or (volume.get('dataVolume') or {}).get('name')
        if claim:
            candidates.append({
                'diskTarget': target,
                'diskName': diskName,
                'guestPvc': claim,
            })

    if len(candidates) != 1:
        Emit({
            'ok': False,
            'error': 'disk target does not map uniquely to a PVC/DataVolume',
            'requestedTarget': args.target or None,
            'candidates': candidates,
        }, 1)
    Emit({'ok': True, **candidates[0]})


def BuildParser() -> argparse.ArgumentParser:
    '''CLI subcommands for shell and fixture callers.'''
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest='command', required=True)

    decision = commands.add_parser('decision')
    decision.add_argument('--misses', type=int, required=True)
    decision.add_argument('--threshold', type=int, required=True)
    decision.add_argument('--domstate', required=True)
    decision.add_argument('--vmi-phase', required=True)
    decision.add_argument('--pvpanic', action='store_true')
    decision.add_argument('--pod-present', action='store_true')
    decision.set_defaults(func=CrashDecision)

    stats = commands.add_parser('domstats')
    stats.add_argument('--device', required=True)
    stats.set_defaults(func=Domstats)

    progress = commands.add_parser('progress-step')
    progress.add_argument('--device', required=True)
    progress.add_argument('--state', required=True)
    progress.add_argument('--idle-samples', type=int, default=3)
    progress.set_defaults(func=ProgressStep)

    artifact = commands.add_parser('validate-artifact')
    artifact.add_argument(
        '--type',
        choices=['screenshot', 'memory', 'dump', 'evtx', 'json', 'log'],
        required=True,
    )
    artifact.add_argument('--path', required=True)
    artifact.set_defaults(func=ValidateArtifact)

    summary = commands.add_parser('write-summary')
    summary.add_argument('--out', required=True)
    summary.add_argument('--stage-errors', required=True)
    summary.add_argument('--mode', required=True)
    summary.add_argument('--vm', required=True)
    summary.add_argument('--namespace', required=True)
    summary.add_argument('--filename', default='evidence-summary.json')
    summary.add_argument('--run-id', default='')
    summary.set_defaults(func=WriteSummary)

    mapping = commands.add_parser('map-disk')
    mapping.add_argument('--vmi-json', required=True)
    mapping.add_argument('--domain-xml', required=True)
    mapping.add_argument('--target', default='')
    mapping.set_defaults(func=MapDisk)
    return result


if __name__ == '__main__':
    parsed = BuildParser().parse_args()
    parsed.func(parsed)
