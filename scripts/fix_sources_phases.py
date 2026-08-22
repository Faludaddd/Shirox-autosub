#!/usr/bin/env python3
"""Add LibraryDesignSystem.swift + ModuleSelectorMenu.swift build file entries
to the 3 remaining PBXSourcesBuildPhase blocks (iOS, macOS, tvOS targets).
The Tests target already has them.
"""
import os
import re

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

with open(PBXPROJ, "r") as f:
    text = f.read()

# Build file IDs we already created in the PBXBuildFile section
# We need to use the EXISTING build IDs — one per phase. Since each phase
# needs its own build file ID, and we created 4 per file, we distribute them.
# But we don't know which ID went to which phase. Let's just check: the Tests
# phase already has entries with IDs 7C0C6605... and F68950F5.... So the other
# 3 IDs for each file go to the other 3 phases.
#
# LibraryDesignSystem.swift existing in Tests phase: 7C0C6605ED1F492BB9DFF5C2
# ModuleSelectorMenu.swift existing in Tests phase: F68950F5BF8543B59C2CA4A6
#
# Remaining build IDs (from add_library_ds_files.py output):
# LibraryDesignSystem: 995B9032301847B689999977, 07DD4D5C2BBD44819992CE6E, 7F4F2D7382E74A0CBB8868A1
# ModuleSelectorMenu: 71A75A1C... was the file ref ID. The build IDs were generated
#   but we don't have them recorded. Let me find them in the pbxproj.

# Find all build file IDs for our two files
lib_ds_build_ids = re.findall(
    r'([A-F0-9]{24}) /\* LibraryDesignSystem\.swift in Sources \*/',
    text
)
mod_sel_build_ids = re.findall(
    r'([A-F0-9]{24}) /\* ModuleSelectorMenu\.swift in Sources \*/',
    text
)
print(f"LibraryDesignSystem build IDs: {lib_ds_build_ids}")
print(f"ModuleSelectorMenu build IDs: {mod_sel_build_ids}")

# Find all PBXSourcesBuildPhase blocks
# Pattern: /* Sources */ = { ... isa = PBXSourcesBuildPhase; ... files = ( ... ); ... };
# We split by "/* Sources */ = {" to find each phase
phase_starts = [m.start() for m in re.finditer(r'/\* Sources \*/ = \{', text)]
print(f"Found {len(phase_starts)} Sources phases")

# For each phase, find the files = ( ... ) block
# We need the FIRST "files = (" after each phase start, and its matching ");"
phases_to_update = []
for ps in phase_starts:
    # Find "files = (" after ps
    files_match = re.search(r'files = \(', text[ps:])
    if not files_match:
        print(f"WARN: no files = ( found for phase at {ps}")
        continue
    files_start = ps + files_match.end()
    # Find the matching ");" — it's the first line that is just whitespace + ");"
    close_match = re.search(r'\n\s*\);', text[files_start:])
    if not close_match:
        print(f"WARN: no ); found for phase at {ps}")
        continue
    close_pos = files_start + close_match.start()
    phases_to_update.append((ps, files_start, close_pos))

print(f"Will update {len(phases_to_update)} phases")

# For each phase, check which files are missing and add them
# Phase 0 (Tests) already has both. Phases 1, 2, 3 need them.
# We'll use build IDs in order: phase 1 gets index 1, phase 2 gets index 2, etc.
# But we need to map phases to build IDs. Let's just use the IDs that aren't
# already in any phase.

# Find which build IDs are already used in any phase
used_lib_ds = set()
used_mod_sel = set()
for ps, fs, cp in phases_to_update:
    phase_text = text[fs:cp]
    for bid in lib_ds_build_ids:
        if bid in phase_text:
            used_lib_ds.add(bid)
    for bid in mod_sel_build_ids:
        if bid in phase_text:
            used_mod_sel.add(bid)

unused_lib_ds = [b for b in lib_ds_build_ids if b not in used_lib_ds]
unused_mod_sel = [b for b in mod_sel_build_ids if b not in used_mod_sel]
print(f"Unused LibraryDesignSystem IDs: {unused_lib_ds}")
print(f"Unused ModuleSelectorMenu IDs: {unused_mod_sel}")

# Process phases in reverse to keep indices valid
# For each phase that's missing entries, add one from the unused pool
additions_per_phase = []  # list of (close_pos, [entries to add])
lib_idx = 0
mod_idx = 0
for ps, fs, cp in phases_to_update:
    phase_text = text[fs:cp]
    entries = []
    # Check LibraryDesignSystem
    if not any(bid in phase_text for bid in lib_ds_build_ids):
        if lib_idx < len(unused_lib_ds):
            bid = unused_lib_ds[lib_idx]
            lib_idx += 1
            entries.append(f'\t\t\t{bid} /* LibraryDesignSystem.swift in Sources */,')
    # Check ModuleSelectorMenu
    if not any(bid in phase_text for bid in mod_sel_build_ids):
        if mod_idx < len(unused_mod_sel):
            bid = unused_mod_sel[mod_idx]
            mod_idx += 1
            entries.append(f'\t\t\t{bid} /* ModuleSelectorMenu.swift in Sources */,')
    if entries:
        additions_per_phase.append((cp, entries))

# Apply additions in reverse order
for cp, entries in sorted(additions_per_phase, key=lambda x: -x[0]):
    insertion = '\n' + '\n'.join(entries)
    text = text[:cp] + insertion + text[cp:]
    print(f"Added {len(entries)} entries at pos {cp}")

with open(PBXPROJ, "w") as f:
    f.write(text)

print("Done.")
