#!/bin/bash
# Lists source strings that a translation is missing. Keys are the Simplified Chinese text;
# the compiler extracts them from Text("…") and String(localized: "…").
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null 2>&1 || { echo "build failed"; exit 1; }
python3 - "$OUT" <<'PY'
import glob, json, subprocess, sys
keys = set()
for f in glob.glob(sys.argv[1] + '/*.stringsdata'):
    for entries in json.load(open(f)).get('tables', {}).values():
        keys.update(e['key'] for e in entries)
keys.discard('')
status = 0
for path in sorted(glob.glob('Resources/Localization/*.lproj/Localizable.strings')):
    lang = path.split('/')[-2].removesuffix('.lproj')
    if lang == 'zh-Hans':
        continue
    have = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, check=True).stdout)
    missing = sorted(keys - have.keys())
    print(f'{lang}: {len(missing)} missing')
    for k in missing:
        print('   ', k)
    status |= bool(missing)
sys.exit(status)
PY
