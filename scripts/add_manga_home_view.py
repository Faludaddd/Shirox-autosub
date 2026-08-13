#!/usr/bin/env python3
"""Add MangaHomeView.swift to the Shirox Xcode project's Views group."""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")
BASENAME = "MangaHomeView.swift"
GROUP_PATH = "Views"  # Existing top-level group

TARGET_SOURCES_PHASE_IDS = {
    "ios":   "95DE5ABBF64ACBFE36B79FBD",
    "macos": "71E452E51715804C32DE8FF0",
    "tvos":  "121D9B342FCA5378000FF9B4",
    "tests": "0D7C42462608CC0CC47C2FD3",
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


def main():
    text = read_text(PBXPROJ_PATH)
    existing_ids = collect_existing_ids(text)
    used = set()

    if file_already_registered(text, BASENAME):
        print(f"[skip] {BASENAME} — already present in pbxproj")
        return 0

    fileref_id = make_unique_id(existing_ids, used)
    build_ids = {t: make_unique_id(existing_ids, used) for t in TARGET_ORDER}

    # 1) PBXBuildFile entries
    buildfile_section_end = "/* End PBXBuildFile section */"
    buildfile_insert_pos = find_section_end_insertion_point(text, buildfile_section_end)
    if buildfile_insert_pos is None:
        print("ERROR: PBXBuildFile section end marker not found.", file=sys.stderr)
        return 1
    buildfile_lines = []
    for target in TARGET_ORDER:
        buildfile_lines.append(
            f"\t\t{build_ids[target]} /* {BASENAME} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {fileref_id} /* {BASENAME} */; }};\n"
        )
    text = insert_before(text, buildfile_insert_pos, buildfile_lines)

    # 2) PBXFileReference entry
    fileref_section_end = "/* End PBXFileReference section */"
    fileref_insert_pos = find_section_end_insertion_point(text, fileref_section_end)
    if fileref_insert_pos is None:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    fileref_line = (
        f"\t\t{fileref_id} /* {BASENAME} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {BASENAME}; sourceTree = \"<group>\"; }};\n"
    )
    text = insert_before(text, fileref_insert_pos, [fileref_line])

    # 3) Group child entry — add to Views group
    block_info = find_group_block(text, GROUP_PATH)
    if block_info is None:
        print(f"ERROR: Could not locate PBXGroup with path={GROUP_PATH!r}.", file=sys.stderr)
        return 1
    _, _, children_close = block_info
    child_line = f"\t\t\t\t{fileref_id} /* {BASENAME} */,\n"
    text = insert_before(text, children_close, [child_line])

    # 4) Sources build phase entries
    for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
        block_info = find_sources_phase_block(text, phase_id)
        if block_info is None:
            print(f"ERROR: Could not locate PBXSourcesBuildPhase with id={phase_id}.", file=sys.stderr)
            return 1
        _, _, files_close = block_info
        phase_line = f"\t\t\t\t{build_ids[target]} /* {BASENAME} in Sources */,\n"
        text = insert_before(text, files_close, [phase_line])

    write_text(PBXPROJ_PATH, text)
    print(f"Added {BASENAME} (group={GROUP_PATH}, fileRef={fileref_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
