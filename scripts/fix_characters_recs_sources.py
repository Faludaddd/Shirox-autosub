#!/usr/bin/env python3
"""Distribute CharactersAndRecommendations.swift build entries to all 4 Sources phases."""
import os, re

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

with open(PBXPROJ, "r") as f:
    text = f.read()

basename = "CharactersAndRecommendations.swift"
build_ids = re.findall(r'([A-F0-9]{24}) /\* ' + re.escape(basename) + r' in Sources \*/', text)
print(f"Build IDs for {basename}: {build_ids}")

# Find all Sources phases
phase_starts = [m.start() for m in re.finditer(r'/\* Sources \*/ = \{', text)]
print(f"Found {len(phase_starts)} Sources phases")

phases_to_update = []
for ps in phase_starts:
    files_match = re.search(r'files = \(', text[ps:])
    if not files_match: continue
    files_start = ps + files_match.end()
    close_match = re.search(r'\n\s*\);', text[files_start:])
    if not close_match: continue
    close_pos = files_start + close_match.start()
    phases_to_update.append((ps, files_start, close_pos))

# Find unused build IDs
used = set()
for ps, fs, cp in phases_to_update:
    phase_text = text[fs:cp]
    for bid in build_ids:
        if bid in phase_text:
            used.add(bid)
unused = [b for b in build_ids if b not in used]
print(f"Unused IDs: {unused}")

# Add to phases missing the file
lib_idx = 0
additions = []
for ps, fs, cp in phases_to_update:
    phase_text = text[fs:cp]
    if not any(bid in phase_text for bid in build_ids):
        if lib_idx < len(unused):
            bid = unused[lib_idx]
            lib_idx += 1
            additions.append((cp, f'\n\t\t\t{bid} /* {basename} in Sources */,'))

for cp, entry in sorted(additions, key=lambda x: -x[0]):
    text = text[:cp] + entry + text[cp:]
    print(f"Added entry at pos {cp}")

with open(PBXPROJ, "w") as f:
    f.write(text)
print("Done.")
