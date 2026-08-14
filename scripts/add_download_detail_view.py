#!/usr/bin/env python3
"""Register DownloadDetailView.swift in project.pbxproj for all 4 targets."""
import re, sys, pathlib

pbx = pathlib.Path("Shirox.xcodeproj/project.pbxproj")
text = pbx.read_text()

# Use DownloadsView.swift as the template for file ref id, build file ids, group, and sources
# We'll create unique ids by replacing the last hex digit.
base = "DownloadsView"
# Find all occurrences of DownloadsView.swift in the pbxproj and clone them for DownloadDetailView.swift

# 1. FileReference entry: <id> /* DownloadsView.swift */ = {isa = PBXFileReference; ... path = DownloadsView.swift; ... };
ref_pattern = r'(\w+)\s*/\* DownloadsView\.swift \*/ = \{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = DownloadsView\.swift; sourceTree = "<group>"; \};'
ref_match = re.search(ref_pattern, text)
if not ref_match:
    print("ERROR: could not find DownloadsView.swift file reference")
    sys.exit(1)
old_ref_id = ref_match.group(1)
new_ref_id = old_ref_id[:-1] + "D"  # change last char
new_ref_line = ref_match.group(0).replace(old_ref_id, new_ref_id).replace("DownloadsView.swift", "DownloadDetailView.swift")
text = text.replace(ref_match.group(0), ref_match.group(0) + "\n\t\t" + new_ref_line)

# 2. BuildFile entries (one per target) — find all PBXBuildFile lines referencing DownloadsView.swift
build_pattern = r'(\w+)\s*/\* DownloadsView\.swift \*/;'
build_matches = re.findall(build_pattern, text)
# Each build file id appears twice: in the BuildFile section and in the Sources phase
# We need to create new build file ids for each target
new_build_ids = []
for i, old_id in enumerate(build_matches[:4]):  # limit to 4 targets
    new_id = old_id[:-2] + format(i, 'x') + "D"  # unique per target
    new_build_ids.append(new_id)
    # Add the PBXBuildFile entry right after the old one
    old_build_entry = f'{old_id} /* DownloadsView.swift */ = {{isa = PBXBuildFile; fileRef = {old_ref_id} /* DownloadsView.swift */; }};'
    new_build_entry = f'{new_id} /* DownloadDetailView.swift */ = {{isa = PBXBuildFile; fileRef = {new_ref_id} /* DownloadDetailView.swift */; }};'
    text = text.replace(old_build_entry, old_build_entry + "\n\t\t" + new_build_entry)

# 3. Group membership — add to the Downloads group
# Find the group that contains DownloadsView.swift
group_pattern = r'(/\* Downloads \*/ = \{[^}]*children = \(\s*(?:/\* [^*]+ \*/,\s*)*/\* DownloadsView\.swift \*/,)'
group_match = re.search(group_pattern, text, re.DOTALL)
if group_match:
    old_group = group_match.group(1)
    new_group = old_group + f"\n\t\t\t\t{new_ref_id} /* DownloadDetailView.swift */,"
    text = text.replace(old_group, new_group)

# 4. Sources phase — add after each DownloadsView.swift reference in Sources phases
# Find all SourcesPhase entries that contain DownloadsView.swift
sources_pattern = r'(/\* DownloadsView\.swift \*/,)'
sources_matches = re.findall(sources_pattern, text)
for i, match in enumerate(sources_matches[:4]):
    if i < len(new_build_ids):
        text = text.replace(match, match + f"\n\t\t\t\t{new_build_ids[i]} /* DownloadDetailView.swift */,",
                           1)  # replace one at a time

pbx.write_text(text)
print(f"Registered DownloadDetailView.swift with ref id {new_ref_id} and build ids {new_build_ids}")
