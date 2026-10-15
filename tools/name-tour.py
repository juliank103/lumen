"""Names the screen tour's screenshots (exported from the UI test results by `xcresulttool export attachments`) by
their attachment names, in tour order, and drops a screenshot identical to the one before it (scrolling past the end).
Usage: python3 tools/name-tour.py <export folder with manifest.json> <output folder>"""
import json, os, re, shutil, sys

source, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
with open(os.path.join(source, 'manifest.json')) as f:
    manifest = json.load(f)
items = []
for test in manifest if isinstance(manifest, list) else [manifest]:
    for attachment in test.get('attachments', []):
        name = attachment.get('suggestedHumanReadableName') or attachment['exportedFileName']
        name = re.sub(r'_\d+_[0-9A-Fa-f-]{36}(?=\.\w+$)', '', name)
        if not re.match(r'^\d{3}-', name):
            continue  # Xcode's own attachments (UI snapshots, synthesized events, screen recording).
        items.append((name, os.path.join(source, attachment['exportedFileName'])))
previous = None
kept = 0
for name, path in sorted(items):
    data = open(path, 'rb').read()
    if data == previous:
        continue
    previous = data
    shutil.copyfile(path, os.path.join(target, name if name.endswith('.png') else name + '.png'))
    kept += 1
print(f'{kept} screenshots ({len(items) - kept} duplicates dropped)')
