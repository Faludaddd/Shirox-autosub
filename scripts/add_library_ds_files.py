#!/usr/bin/env python3
"""Add new Swift files to project.pbxproj — minimal idempotent adder."""
import os
import re
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

FILES = [
    ("Shirox/Views/Library/LibraryDesignSystem.swift", "Library"),
    ("Shirox/Views/Library/ModuleSelectorMenu.swift", "Library"),
]

def gen_id():
    return uuid.uuid4().hex[:24].upper()

with open(PBXPROJ, "r") as f:
    text = f.read()

existing_names = set(re.findall(r'/\*\s*([\w]+\.swift)\s*\*/', text))

for relpath, group in FILES:
    basename = os.path.basename(relpath)
    if basename in existing_names:
        print(f"SKIP (already in pbxproj): {basename}")
        continue

    file_ref_id = gen_id()
    build_ids = [gen_id() for _ in range(4)]

    # 1. PBXFileReference — insert before End marker
    file_ref_line = f'\t\t{file_ref_id} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {basename}; sourceTree = "<group>"; }};\n'
    text = text.replace("/* End PBXFileReference section */", file_ref_line + "/* End PBXFileReference section */", 1)
    print(f"+ PBXFileReference: {basename} ({file_ref_id})")

    # 2. PBXBuildFile entries — insert before End marker
    build_lines = ""
    for bid in build_ids:
        build_lines += f'\t\t{bid} /* {basename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {basename} */; }};\n'
    text = text.replace("/* End PBXBuildFile section */", build_lines + "/* End PBXBuildFile section */", 1)
    print(f"+ PBXBuildFile: 4 entries for {basename}")

    # 3. Find group block by name and append child
    # Look for: <id> /* <group> */ = { isa = PBXGroup; children = (
    # We'll find the line with the group name comment, then find the next "children = ("
    # and append before the matching ")"
    lines = text.split('\n')
    group_idx = None
    for i, line in enumerate(lines):
        if f'/* {group} */ = {{isa = PBXGroup;' in line or (f'/* {group} */' in line and 'PBXGroup' in lines[i+1] if i+1 < len(lines) else False):
            group_idx = i
            break
    # Alternative: search for the group comment then walk forward to "children = ("
    if group_idx is None:
        for i, line in enumerate(lines):
            if f'/* {group} */' in line and 'PBXGroup' not in line:
                # Check next ~5 lines for PBXGroup
                for j in range(i, min(i+5, len(lines))):
                    if 'isa = PBXGroup;' in lines[j]:
                        group_idx = i
                        break
                if group_idx: break

    if group_idx is not None:
        # Find "children = (" after group_idx
        children_start = None
        for i in range(group_idx, min(group_idx+10, len(lines))):
            if 'children = (' in lines[i]:
                children_start = i
                break
        if children_start is not None:
            # Find the closing ")" — first line that is just "\t\t);" after children_start
            children_end = None
            for i in range(children_start+1, min(children_start+50, len(lines))):
                if lines[i].strip() == ');':
                    children_end = i
                    break
            if children_end is not None:
                # Insert new child before the closing ")"
                new_child = f'\t\t\t{file_ref_id} /* {basename} */,'
                lines.insert(children_end, new_child)
                text = '\n'.join(lines)
                print(f"+ Added to group '{group}' children: {basename}")
            else:
                print(f"WARN: no children close paren for {group}")
        else:
            print(f"WARN: no children = ( for {group}")
    else:
        print(f"WARN: group '{group}' not found for {basename}")

    # 4. Add to each Sources build phase — find all "Sources */ = {"
    # Re-split since text changed
    lines = text.split('\n')
    sources_indices = []
    for i, line in enumerate(lines):
        if '/* Sources */ = {' in line and 'PBXSourcesBuildPhase' in (lines[i+1] if i+1 < len(lines) else ''):
            sources_indices.append(i)
    # Fallback: match by looking for PBXSourcesBuildPhase in nearby lines
    if len(sources_indices) < 4:
        sources_indices = []
        for i, line in enumerate(lines):
            if '/* Sources */ = {' in line:
                # check next 3 lines for isa = PBXSourcesBuildPhase
                for j in range(i, min(i+4, len(lines))):
                    if 'isa = PBXSourcesBuildPhase;' in lines[j]:
                        sources_indices.append(i)
                        break

    # For each Sources phase, find "files = (" and append a build file entry before ")"
    inserted = 0
    for src_idx in sources_indices[:4]:
        bid = build_ids[inserted]
        # find files = ( after src_idx
        for i in range(src_idx, min(src_idx+10, len(lines))):
            if 'files = (' in lines[i]:
                files_start = i
                # find closing )
                for j in range(files_start+1, min(files_start+100, len(lines))):
                    if lines[j].strip() == ');':
                        new_entry = f'\t\t\t{bid} /* {basename} in Sources */,'
                        lines.insert(j, new_entry)
                        inserted += 1
                        break
                break
    text = '\n'.join(lines)
    print(f"+ Added to {inserted} Sources phases: {basename}")

with open(PBXPROJ, "w") as f:
    f.write(text)

print("Done.")
