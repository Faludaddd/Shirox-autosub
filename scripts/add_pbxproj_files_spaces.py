#!/usr/bin/env python3
"""
One-off script to register the new Swift file added for #98
(CustomRefreshControl.swift) in the Shirox pbxproj, which uses SPACE
indentation (not tabs).

This mirrors `add_pbxproj_files.py` but with space-based regex patterns
that match the current on-disk pbxproj format. Idempotent: files already
registered are skipped.

For each new file, this script inserts:
  • 4 PBXBuildFile entries  (one per target: iOS, macOS, tvOS, Tests)
  • 1 PBXFileReference entry
  • 1 group child entry     (in the "Shared" PBXGroup's children list)
  • 4 Sources phase entries  (one per target's PBXSourcesBuildPhase)
"""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

# Indentation in the on-disk pbxproj (spaces, not tabs).
I2 = " " * 16   # group / buildfile / fileref entry indent
I3 = " " * 24   # group properties / sources-phase properties
I4 = " " * 32   # children / files entries

FILES_TO_ADD = [
    "Shirox/Views/Shared/CustomRefreshControl.swift",
]

# Sources build phase IDs for each target (looked up from pbxproj).
TARGET_SOURCES_PHASE_IDS = {
    "ios":   "95DE5ABBF64ACBFE36B79FBD",  # Shirox_iOS
    "macos": "71E452E51715804C32DE8FF0",  # Shirox_macOS
    "tvos":  "121D9B342FCA5378000FF9B4",  # Shirox_tvOS
    "tests": "0D7C42462608CC0CC47C2FD3",  # ShiroxTests
}
TARGET_ORDER = ["ios", "macos", "tvos", "tests"]


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
    """True if a PBXFileReference with this basename already exists."""
    pattern = re.compile(
        r"isa\s*=\s*PBXFileReference\b[^\n]*\bpath\s*=\s*" + re.escape(basename) + r"\b"
    )
    return bool(pattern.search(text))


def find_shared_group_children_close(text):
    """
    Find the insertion point for new child entries in the Shared PBXGroup's
    children list. Returns the absolute index in `text` of the start of the
    `);` line that closes the children list, or None if not found.
    """
    # The Shared PBXGroup block. Match its header line:
    # `<16 spaces><HEXID> /* Shared */ = {\n<24 spaces>isa = PBXGroup;\n`
    header_re = re.compile(
        re.escape(I2) + r"([0-9A-Fa-f]{24}) /\* Shared \*/ = \{\n"
        + re.escape(I3) + r"isa = PBXGroup;\n"
    )
    m = header_re.search(text)
    if not m:
        return None
    block_start = m.start()
    # Find the closing `\n<16 spaces>};` of this block.
    end_match = re.search(r"\n" + re.escape(I2) + r"};", text[m.end():])
    if not end_match:
        return None
    block_end = m.end() + end_match.end()
    body = text[block_start:block_end]
    # Find `children = (\n` ... `\n<24 spaces>);` within the body.
    children_open = re.search(r"\n" + re.escape(I3) + r"children = \(\n", body)
    if not children_open:
        return None
    children_close = re.search(r"\n" + re.escape(I3) + r"\);", body[children_open.end():])
    if not children_close:
        return None
    close_in_body = children_open.end() + children_close.start()
    # +1 to skip the `\n` and point at the start of `<24 spaces>);`
    return block_start + close_in_body + 1


def find_sources_phase_files_close(text, phase_id):
    """
    Find the insertion point for new file entries in a PBXSourcesBuildPhase's
    files list. Returns the absolute index, or None if not found.
    """
    header_pattern = re.compile(
        re.escape(I2) + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{"
    )
    m = header_pattern.search(text)
    if not m:
        return None
    block_start = m.start()
    body_end_match = re.search(r"\n" + re.escape(I2) + r"};", text[m.end():])
    if not body_end_match:
        return None
    block_end = m.end() + body_end_match.end()
    body = text[block_start:block_end]
    files_open = re.search(r"\n" + re.escape(I3) + r"files = \(\n", body)
    if not files_open:
        return None
    files_close = re.search(r"\n" + re.escape(I3) + r"\);", body[files_open.end():])
    if not files_close:
        return None
    close_in_body = files_open.end() + files_close.start()
    return block_start + close_in_body + 1


def find_section_end_insertion_point(text, section_end_marker):
    """
    Find the insertion point for new entries just before a section end marker
    such as `/* End PBXBuildFile section */`.
    """
    end_pos = text.find(section_end_marker)
    if end_pos == -1:
        return None
    # Walk backward to skip trailing `\n`s.
    i = end_pos
    while i > 0 and text[i - 1] == '\n':
        i -= 1
    return i + 1


def insert_before(text, index, new_lines):
    return text[:index] + "".join(new_lines) + text[index:]


def build_buildfile_line(build_id, basename, fileref_id):
    return (
        f"{I2}{build_id} /* {basename} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {fileref_id} /* {basename} */; }};\n"
    )


def build_fileref_line(fileref_id, basename):
    return (
        f"{I2}{fileref_id} /* {basename} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {basename}; sourceTree = \"<group>\"; }};\n"
    )


def build_group_child_line(fileref_id, basename):
    return f"{I4}{fileref_id} /* {basename} */,\n"


def build_sources_phase_line(build_id, basename):
    return f"{I4}{build_id} /* {basename} in Sources */,\n"


def main():
    text = read_text(PBXPROJ_PATH)
    existing_ids = collect_existing_ids(text)
    used = set()

    pending = []
    for rel_path in FILES_TO_ADD:
        basename = os.path.basename(rel_path)
        if file_already_registered(text, basename):
            print(f"[skip] {rel_path} — already present in pbxproj")
            continue
        pending.append((rel_path, basename))

    if not pending:
        print("Nothing to add — all files are already registered.")
        return 0

    file_records = []
    for rel_path, basename in pending:
        fileref_id = make_unique_id(existing_ids, used)
        build_ids = {t: make_unique_id(existing_ids, used) for t in TARGET_ORDER}
        file_records.append({
            "basename": basename,
            "fileref_id": fileref_id,
            "build_ids": build_ids,
        })

    # 1) PBXBuildFile entries — insert before `/* End PBXBuildFile section */`.
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

    # 2) PBXFileReference entries — insert before `/* End PBXFileReference section */`.
    fileref_section_end = "/* End PBXFileReference section */"
    fileref_insert_pos = find_section_end_insertion_point(text, fileref_section_end)
    if fileref_insert_pos is None:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    fileref_lines = [build_fileref_line(rec["fileref_id"], rec["basename"]) for rec in file_records]
    text = insert_before(text, fileref_insert_pos, fileref_lines)

    # 3) Shared group child entries.
    children_close = find_shared_group_children_close(text)
    if children_close is None:
        print("ERROR: Could not locate Shared PBXGroup's children list.", file=sys.stderr)
        return 1
    child_lines = [build_group_child_line(rec["fileref_id"], rec["basename"]) for rec in file_records]
    text = insert_before(text, children_close, child_lines)

    # 4) Sources build phase entries — one per target.
    for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
        files_close = find_sources_phase_files_close(text, phase_id)
        if files_close is None:
            print(f"ERROR: Could not locate PBXSourcesBuildPhase with id={phase_id}.", file=sys.stderr)
            return 1
        phase_lines = [
            build_sources_phase_line(rec["build_ids"][target], rec["basename"])
            for rec in file_records
        ]
        text = insert_before(text, files_close, phase_lines)

    write_text(PBXPROJ_PATH, text)
    print(f"Successfully added {len(file_records)} file(s) to pbxproj for 4 targets each.")
    for rec in file_records:
        print(f"  + {rec['basename']}  (fileRef={rec['fileref_id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
