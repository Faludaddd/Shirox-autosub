#!/usr/bin/env python3
"""Register the v2.34 onboarding files (GuidedTour.swift, OnboardingDemos.swift)
into the Shirox Xcode project for the three app targets (iOS, macOS, tvOS) —
NOT ShiroxTests, matching how OnboardingView.swift itself is registered.
Based on the battle-tested add_pbxproj_files.py machinery."""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

FILES_TO_ADD = [
    ("Shirox/Views/Onboarding/GuidedTour.swift", "Onboarding"),
    ("Shirox/Views/Onboarding/OnboardingDemos.swift", "Onboarding"),
]

TARGET_SOURCES_PHASE_IDS = {
    "ios":   "95DE5ABBF64ACBFE36B79FBD",  # Shirox_iOS
    "macos": "71E452E51715804C32DE8FF0",  # Shirox_macOS
    "tvos":  "121D9B342FCA5378000FF9B4",  # Shirox_tvOS
}
TARGET_ORDER = ["ios", "macos", "tvos"]


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def collect_existing_ids(text):
    return set(re.findall(r"\b[0-9A-Fa-f]{24}\b", text))


def make_unique_id(existing_ids, used):
    while True:
        candidate = uuid.uuid4().hex.upper()[:24]
        if candidate not in existing_ids and candidate not in used:
            used.add(candidate)
            return candidate


def file_already_registered(text, basename):
    pattern = re.compile(
        r"isa\s*=\s*PBXFileReference\b[^\n]*\bpath\s*=\s*" + re.escape(basename) + r"\b"
    )
    return bool(pattern.search(text))


def find_group_block(text, group_path):
    header_re = re.compile(
        r"(?m)^\s+([0-9A-Fa-f]{24}) /\* ([^*]+?) \*/ = \{\n"
        r"\s+isa = PBXGroup;\n"
    )
    for m in header_re.finditer(text):
        block_start = m.start()
        end_match = re.search(r"\n\s+};", text[m.end():])
        if end_match is None:
            continue
        block_end = m.end() + end_match.end()
        body = text[block_start:block_end]
        path_re = re.compile(r"\n\s+path\s*=\s*" + re.escape(group_path) + r"\s*;\n")
        if not path_re.search(body):
            continue
        children_open_match = re.search(r"\n\s+children = \(\n", body)
        if children_open_match is None:
            continue
        children_close_match = re.search(r"\n\s+\);", body[children_open_match.end():])
        if children_close_match is None:
            continue
        close_line_start_in_body = children_open_match.end() + children_close_match.start()
        children_close = block_start + close_line_start_in_body + 1
        return (block_start, block_end, children_close)
    return None


def find_sources_phase_block(text, phase_id):
    header_pattern = re.compile(
        r"(?m)^\s*" + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{"
    )
    m = header_pattern.search(text)
    if not m:
        return None
    block_start = m.start()
    body_end_match = re.search(r"\n\s+};", text[m.end():])
    if body_end_match is None:
        return None
    block_end = m.end() + body_end_match.end()
    body = text[block_start:block_end]
    files_open_match = re.search(r"\n\s+files = \(\n", body)
    if files_open_match is None:
        return None
    files_close_match = re.search(r"\n\s+\);", body[files_open_match.end():])
    if files_close_match is None:
        return None
    close_line_start_in_body = files_open_match.end() + files_close_match.start()
    files_close = block_start + close_line_start_in_body + 1
    return (block_start, block_end, files_close)


def insert_before(text, index, new_lines):
    return text[:index] + "".join(new_lines) + text[index:]


def find_section_end_insertion_point(text, section_end_marker):
    end_pos = text.find(section_end_marker)
    if end_pos == -1:
        return None
    i = end_pos
    while i > 0 and text[i - 1] == '\n':
        i -= 1
    return i + 1


def build_buildfile_line(build_id, basename, fileref_id):
    return (
        f"\t\t{build_id} /* {basename} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {fileref_id} /* {basename} */; }};\n"
    )


def build_fileref_line(fileref_id, basename):
    return (
        f"\t\t{fileref_id} /* {basename} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {basename}; sourceTree = \"<group>\"; }};\n"
    )


def build_group_child_line(fileref_id, basename):
    return f"\t\t\t\t{fileref_id} /* {basename} */,\n"


def build_sources_phase_line(build_id, basename):
    return f"\t\t\t\t{build_id} /* {basename} in Sources */,\n"


def main():
    text = read_text(PBXPROJ_PATH)
    existing_ids = collect_existing_ids(text)
    used = set()

    pending = []
    for rel_path, group in FILES_TO_ADD:
        basename = os.path.basename(rel_path)
        if file_already_registered(text, basename):
            print(f"[skip] {rel_path} — already present in pbxproj")
            continue
        pending.append((rel_path, group, basename))

    if not pending:
        print("Nothing to add — all files are already registered.")
        return 0

    file_records = []
    for rel_path, group, basename in pending:
        fileref_id = make_unique_id(existing_ids, used)
        build_ids = {t: make_unique_id(existing_ids, used) for t in TARGET_ORDER}
        file_records.append({
            "basename": basename,
            "group": group,
            "fileref_id": fileref_id,
            "build_ids": build_ids,
        })

    buildfile_section_end = "/* End PBXBuildFile section */"
    buildfile_insert_pos = find_section_end_insertion_point(text, buildfile_section_end)
    if buildfile_insert_pos is None:
        print("ERROR: PBXBuildFile section end marker not found.", file=sys.stderr)
        return 1
    buildfile_lines = []
    for rec in file_records:
        for target in TARGET_ORDER:
            buildfile_lines.append(build_buildfile_line(
                rec["build_ids"][target], rec["basename"], rec["fileref_id"]
            ))
    text = insert_before(text, buildfile_insert_pos, buildfile_lines)

    fileref_section_end = "/* End PBXFileReference section */"
    fileref_insert_pos = find_section_end_insertion_point(text, fileref_section_end)
    if fileref_insert_pos is None:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    fileref_lines = [build_fileref_line(rec["fileref_id"], rec["basename"]) for rec in file_records]
    text = insert_before(text, fileref_insert_pos, fileref_lines)

    for group_path, recs in [(g, [r for r in file_records if r["group"] == g]) for g in {r["group"] for r in file_records}]:
        block_info = find_group_block(text, group_path)
        if block_info is None:
            print(f"ERROR: Could not locate PBXGroup with path={group_path!r}.", file=sys.stderr)
            return 1
        _, _, children_close = block_info
        child_lines = [build_group_child_line(rec["fileref_id"], rec["basename"]) for rec in recs]
        text = insert_before(text, children_close, child_lines)

    for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
        block_info = find_sources_phase_block(text, phase_id)
        if block_info is None:
            print(f"ERROR: Could not locate PBXSourcesBuildPhase with id={phase_id}.", file=sys.stderr)
            return 1
        _, _, files_close = block_info
        phase_lines = [build_sources_phase_line(rec["build_ids"][target], rec["basename"]) for rec in file_records]
        text = insert_before(text, files_close, phase_lines)

    write_text(PBXPROJ_PATH, text)
    print(f"Successfully added {len(file_records)} file(s) to pbxproj for {len(TARGET_ORDER)} targets each.")
    for rec in file_records:
        print(f"  + {rec['basename']}  (group={rec['group']}, fileRef={rec['fileref_id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
