#!/usr/bin/env python3
"""extract-evtx.py — parse offline-extracted Windows .evtx event log files.

Reads one or more .evtx files (extracted from a guest disk via guestfs) and
extracts crash-relevant events defined in data/event-sources.json. Outputs
one JSON object to stdout containing the matched events and a crash-detection
verdict using the same three-tier fallback as the former collect-guest.ps1:

  1. System/1001 BugCheck (traditional BSOD)
  2. Application/1001 LiveKernelEvent
  3. System/6008 dirty shutdown

Usage:
    extract-evtx.py --data-dir <path> [--] <file.evtx> [<file2.evtx> ...]
    extract-evtx.py --help

Output (stdout JSON):
    { "ok": true, "crash": { "detected": true, "crashType": "bugcheck",
      "bugCheckCode": "0x000000D1", ... }, "events": [...], "warnings": [] }

Requires: python-evtx (pip install python-evtx).
"""

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone


class EvtxParseError(RuntimeError):
    """The EVTX dependency or input could not be parsed safely."""


def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Parse offline .evtx files for crash-relevant events."
    )
    parser.add_argument(
        "--data-dir",
        required=True,
        help="Path to the data/ directory containing bugcheck-codes.json and event-sources.json.",
    )
    parser.add_argument(
        "evtx_files",
        nargs="*",
        metavar="FILE",
        help=".evtx file(s) to parse.",
    )
    return parser.parse_args()


def load_json(path):
    """Load a JSON file and return its parsed content."""
    with open(path, "r") as f:
        return json.load(f)


def extract_events_from_evtx(evtx_path, target_events):
    """Extract matching events from a single .evtx file.

    Args:
        evtx_path: Path to the .evtx file.
        target_events: List of dicts with 'log', 'eventId', 'source' keys.

    Returns:
        List of matched event dicts.
    """
    try:
        import Evtx.Evtx as evtx
    except ImportError as exc:
        raise EvtxParseError("python-evtx is not installed") from exc

    matched = []
    target_ids = {e["eventId"] for e in target_events}

    try:
        with evtx.Evtx(evtx_path) as log:
            for record in log.records():
                try:
                    xml_str = record.xml()
                    root = ET.fromstring(xml_str)
                    ns = {"e": "http://schemas.microsoft.com/win/2004/08/events/event"}

                    eid_elem = root.find(".//e:System/e:EventID", ns)
                    if eid_elem is None:
                        continue
                    eid = int(eid_elem.text)
                    if eid not in target_ids:
                        continue

                    time_elem = root.find(".//e:System/e:TimeCreated", ns)
                    time_str = time_elem.get("SystemTime", "") if time_elem is not None else ""

                    provider_elem = root.find(".//e:System/e:Provider", ns)
                    provider = provider_elem.get("Name", "") if provider_elem is not None else ""

                    channel_elem = root.find(".//e:System/e:Channel", ns)
                    channel = channel_elem.text if channel_elem is not None else ""

                    # Extract event data as text
                    data_parts = []
                    for data_elem in root.findall(".//e:EventData/e:Data", ns):
                        text = data_elem.text or ""
                        name = data_elem.get("Name", "")
                        if name:
                            data_parts.append(f"{name}: {text}")
                        elif text:
                            data_parts.append(text)
                    message = " ".join(data_parts)

                    matched.append({
                        "log": channel,
                        "eventId": eid,
                        "time": time_str,
                        "provider": provider,
                        "message": message,
                    })
                except (ET.ParseError, TypeError, ValueError, AttributeError) as exc:
                    raise EvtxParseError(f"malformed record in {evtx_path}: {exc}") from exc
    except EvtxParseError:
        raise
    except Exception as exc:  # noqa: BLE001  # python-evtx exposes format-specific exceptions
        raise EvtxParseError(f"cannot parse {evtx_path}: {exc}") from exc

    return matched


def detect_crash(events, bugcheck_codes):
    """Apply three-tier crash detection fallback to extracted events.

    Args:
        events: List of event dicts from extract_events_from_evtx.
        bugcheck_codes: Dict mapping hex code strings to name/description.

    Returns:
        Crash result dict.
    """
    crash = {
        "detected": False,
        "crashType": None,
        "bugCheckCode": None,
        "bugCheckName": None,
        "parameters": [],
        "crashTime": None,
    }

    # Tier 1: System/1001 BugCheck (must be System provider, event ID 1001, correct code)
    for evt in events:
        if evt["eventId"] == 1001 and "System" in evt.get("log", ""):
            msg = evt.get("message", "")
            m = re.search(r"bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)", msg, re.IGNORECASE)
            if not m:
                m = re.search(r"(0x[0-9a-fA-F]{8})", msg)
            if m:
                crash["detected"] = True
                crash["crashType"] = "bugcheck"
                crash["crashTime"] = evt.get("time", "")
                code = "0x" + m.group(1)[2:].upper().zfill(8)
                crash["bugCheckCode"] = code
                crash["bugCheckName"] = bugcheck_codes.get(code, {}).get("name")
                if m.lastindex and m.lastindex >= 2:
                    crash["parameters"] = [p.strip() for p in m.group(2).split(",")]
                return crash

    # Tier 2: Application/1001 LiveKernelEvent (must be Application provider, event ID 1001)
    for evt in events:
        if evt["eventId"] == 1001 and "Application" in evt.get("log", ""):
            msg = evt.get("message", "")
            if "LiveKernelEvent" in msg:
                crash["detected"] = True
                crash["crashType"] = "livekernelevent"
                crash["crashTime"] = evt.get("time", "")
                p1 = re.search(r"P1:\s*([0-9a-fA-F]+)", msg)
                if p1:
                    code = "0x" + p1.group(1).upper().zfill(8)
                    crash["bugCheckCode"] = code
                    crash["bugCheckName"] = bugcheck_codes.get(code, {}).get("name")
                return crash

    # Tier 3: System/6008 dirty shutdown (must be System provider, event ID 6008)
    for evt in events:
        if evt["eventId"] == 6008 and "System" in evt.get("log", ""):
            crash["detected"] = True
            crash["crashType"] = "dirtyshutdown"
            crash["crashTime"] = evt.get("time", "")
            return crash

    return crash


def main():
    """Main entry point for the .evtx parser."""
    args = parse_args()
    warnings = []

    if not args.evtx_files:
        json.dump({"ok": False, "error": "no .evtx files provided",
                   "crash": {"detected": False, "crashType": None},
                   "events": [], "warnings": []}, sys.stdout, indent=2)
        print()
        return 1

    # Load data files
    bc_path = os.path.join(args.data_dir, "bugcheck-codes.json")
    es_path = os.path.join(args.data_dir, "event-sources.json")

    try:
        bugcheck_codes = load_json(bc_path).get("codes", {})
        target_events = load_json(es_path).get("events", [])
    except (OSError, json.JSONDecodeError) as exc:
        json.dump({"ok": False, "error": f"cannot load parser data: {exc}",
                   "events": [], "warnings": warnings}, sys.stdout, indent=2)
        print()
        return 1

    # Extract events from all provided .evtx files
    all_events = []
    for evtx_file in args.evtx_files:
        try:
            if not os.path.isfile(evtx_file):
                raise EvtxParseError(f"file not found: {evtx_file}")
            matched = extract_events_from_evtx(evtx_file, target_events)
            all_events.extend(matched)
        except EvtxParseError as exc:
            json.dump({"ok": False, "error": str(exc), "events": all_events,
                       "warnings": warnings}, sys.stdout, indent=2)
            print()
            return 1

    # Detect crash
    crash = detect_crash(all_events, bugcheck_codes)

    result = {
        "ok": True,
        "parsedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "crash": crash,
        "events": all_events,
        "warnings": warnings,
    }

    json.dump(result, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
