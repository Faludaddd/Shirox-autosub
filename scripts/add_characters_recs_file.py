#!/usr/bin/env python3
"""Add CharactersAndRecommendations.swift to project.pbxproj."""
import os, re, uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

def gen_id():
    return uuid.uuid4().hex[:24].upper()

with open(PBXPROJ, "r") as f:
    text = f.read()

basename = "CharactersAndRecommendations.swift"
existing = set(re.findall(r'/\*\s*([\w]+\.swift)\s*\*/', text))
if basename in existing:
    print(f"SKIP: {basename} already in pbxproj")
    exit(0)

file_ref_id = gen_id()
build_ids = [gen_id() for _ in range(4)]

# 1. PBXFileReference
file_ref_line = f'\t\t{file_ref_id} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {basename}; sourceTree = "<group>"; }};\n'
text = text.replace("/* End PBXFileReference section */", file_ref_line + "/* End PBXFileReference section */", 1)

# 2. PBXBuildFile entries
build_lines = ""
for bid in build_ids:
    build_lines += f'\t\t{bid} /* {basename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {basename} */; }};\n'
text = text.replace("/* End PBXBuildFile section */", build_lines + "/* End PBXBuildFile section */", 1)

# 3. Add to Shared group
lines = text.split('\n')
group_idx = None
for i, line in enumerate(lines):
    if '/* Shared */' in line and 'PBXGroup' not in line:
        for j in range(i, min(i+5, len(lines))):
            if 'isa = PBXGroup;' in lines[j]:
                group_idx = i
                break
        if group_idx: break

if group_idx is not None:
    children_start = None
    for i in range(group_idx, min(group_idx+10, len(lines))):
        if 'children = (' in lines[i]:
            children_start = i
            break
    if children_start is not None:
        children_end = None
        for i in range(children_start+1, min(children_start+50, len(lines))):
            if lines[i].strip() == ');':
                children_end = i
                break
        if children_end is not None:
            new_child = f'\t\t\t{file_ref_id} /* {basename} */,'
            lines.insert(children_end, new_child)
            text = '\n'.join(lines)
            print(f"+ Added to group 'Shared' children: {basename}")

# 4. Add to all 4 Sources phases
lines = text.split('\n')
sources_indices = []
for i, line in enumerate(lines):
    if '/* Sources */ = {' in line:
        for j in range(i, min(i+4, len(lines))):
            if 'isa = PBXSourcesBuildPhase;' in lines[j]:
                sources_indices.append(i)
                break

inserted = 0
for src_idx in sources_indices[:4]:
    bid = build_ids[inserted]
    for i in range(src_idx, min(src_idx+10, len(lines))):
        if 'files = (' in lines[i]:
            files_start = i
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
