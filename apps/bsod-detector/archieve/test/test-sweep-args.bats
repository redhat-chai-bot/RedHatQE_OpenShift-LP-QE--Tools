#!/usr/bin/env bats

load test-helper

@test "sweep-crashme CODES array has 19 entries" {
  count=$(grep -cE '^\s+"0x[0-9a-fA-F]+ ' "$REPO_ROOT/src/scripts/crash-injector/sweep-crashme.sh")
  [ "$count" -eq 19 ]
}

@test "each CODES entry has exactly 5 fields (code + 4 params)" {
  bad=""
  while IFS= read -r line; do
    stripped=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"$//')
    fields=$(echo "$stripped" | wc -w)
    if [ "$fields" -ne 5 ]; then
      bad="BAD: $line (got $fields fields)"
    fi
  done < <(grep -E '^\s+"0x[0-9a-fA-F]+ ' "$REPO_ROOT/src/scripts/crash-injector/sweep-crashme.sh")
  [ -z "$bad" ]
}

@test "sweep-crashme codes match trigger-methods.json codes" {
  sweep_codes=$(grep -oP '^\s+"(0x[0-9a-fA-F]+)' "$REPO_ROOT/src/scripts/crash-injector/sweep-crashme.sh" | \
    sed 's/.*"//;s/^0x/0x/' | tr '[:lower:]' '[:upper:]' | sed 's/^0X/0x/' | sort)

  json_codes=$(jq -r '.codes | keys[]' "$DATA_DIR/trigger-methods.json" | sort)

  [ "$sweep_codes" = "$json_codes" ]
}

@test "sweep-crashme parameters match trigger-methods.json" {
  python3 -c "
import json, re, sys

with open('$DATA_DIR/trigger-methods.json') as f:
    tm = json.load(f)['codes']

with open('$REPO_ROOT/src/scripts/crash-injector/sweep-crashme.sh') as f:
    script = f.read()

pattern = re.compile(r'\"(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\"')
matches = pattern.findall(script)

errors = []
for code, p1, p2, p3, p4 in matches:
    norm = '0x' + code[2:].upper().zfill(8)
    if norm not in tm:
        errors.append(f'{norm} in sweep but not in trigger-methods.json')
        continue
    expected = tm[norm]['parameters']
    actual = [p1, p2, p3, p4]
    for i, (e, a) in enumerate(zip(expected, actual)):
        if int(e, 16) != int(a, 16):
            errors.append(f'{norm} param[{i}]: expected {e}, got {a}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
"
}
