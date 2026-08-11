#!/usr/bin/env python3
"""
One-off script to register Shirox/Views/Shared/Haptics.swift in the pbxproj.

The original scripts/add_pbxproj_files.py was written when the pbxproj used
TAB indentation; the project file has since been reformatted by Xcode to use
8-space indentation, so that script's `\\t`-based regexes no longer match.
This script is whitespace-agnostic and inserts entries with the same
indentation as the existing ToastSystem.swift entries (which live in the same
Shared group, so they're a reliable indentation reference).

Idempotent: if Haptics.swift is already registered, this script is a no-op.
"""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

# Sources build phase IDs for each target (from add_pbxproj_files.py).
TARGET_SOURCES_PHASE_IDS = {
    "ios":   "95DE5ABBF64ACBFE36B79FBD",
    "macos": "71E452E51715804C32DE8FF0",
    "tvos":  "121D9B342FCA5378000FF9B4",
    "tests": "0D7C42462608CC0CC47C2FD3",
}
TARGET_ORDER = ["ios", "macos", "tvos", "tests"]

BASENAME = "Haptics.swift"


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
    """Return True if a PBXFileReference with this basename already exists."""
    pattern = re.compile(
        r"isa\s*=\s*PBXFileReference\b[^\n]*\bpath\s*=\s*" + re.escape(basename) + r"\b"
    )
    return bool(pattern.search(text))


def detect_indent_of_line(text, line_pattern):
    """Return the leading whitespace of the first line matching line_pattern."""
    m = re.search(r"(?m)^([ \t]*)" + line_pattern, text)
    if m is None:
        return ""
    return m.group(1)


def find_phase_block(text, phase_id):
    """
    Find the PBXSourcesBuildPhase block whose ID matches.
    Returns (block_start, block_end, files_close_index) where files_close_index
    points at the start of the `);` line (the insertion point for new file entries).
    Uses whitespace-agnostic matching so it works with either tab or space
    indentation.
    """
    header_re = re.compile(
        r"(?m)^([ \t]*)" + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{"
    )
    m = header_re.search(text)
    if not m:
        return None
    block_start = m.start()
    body_end_match = re.search(r"\n[ \t]*\};[ \t]*\n", text[m.end():])
    if body_end_match is None:
        return None
    block_end = m.end() + body_end_match.end()
    body = text[block_start:block_end]
    files_open_match = re.search(r"\n[ \t]*files[ \t]*=[ \t]*\(\n", body)
    if files_open_match is None:
        return None
    files_close_match = re.search(r"\n[ \t]*\);[ \t]*\n", body[files_open_match.end():])
    if files_close_match is None:
        return None
    close_line_start_in_body = files_open_match.end() + files_close_match.start()
    files_close = block_start + close_line_start_in_body + 1
    return (block_start, block_end, files_close)


def insert_before(text, index, new_text):
    return text[:index] + new_text + text[index:]


def main():
    text = read_text(PBXPROJ_PATH)

    if file_already_registered(text, BASENAME):
        print(f"[skip] {BASENAME} is already registered in pbxproj.")
        return 0

    existing_ids = collect_existing_ids(text)
    used = set()

    fileref_id = make_unique_id(existing_ids, used)
    build_ids = {t: make_unique_id(existing_ids, used) for t in TARGET_ORDER}

    # ---- 1. PBXBuildFile entries (insert just before /* End PBXBuildFile section */) ----
    # Use ToastSystem.swift's PBXBuildFile entries as the indentation reference.
    buildfile_indent = detect_indent_of_line(
        text,
        r"[0-9A-Fa-f]{24}[ \t]*/\* ToastSystem\.swift in Sources \*/"
        r"[ \t]*=[ \t]*\{isa = PBXBuildFile;",
    )
    if not buildfile_indent:
        print("ERROR: could not detect PBXBuildFile indent.", file=sys.stderr)
        return 1

    buildfile_lines = []
    for target in TARGET_ORDER:
        bid = build_ids[target]
        buildfile_lines.append(
            f"{buildfile_indent}{bid} /* {BASENAME} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {fileref_id} /* {BASENAME} */; }};\n"
        )
    end_marker = "/* End PBXBuildFile section */"
    end_pos = text.find(end_marker)
    if end_pos == -1:
        print("ERROR: PBXBuildFile section end marker not found.", file=sys.stderr)
        return 1
    # Walk back over trailing newlines to keep the empty line above the marker.
    i = end_pos
    while i > 0 and text[i - 1] == '\n':
        i -= 1
    insert_pos = i + 1
    text = insert_before(text, insert_pos, "".join(buildfile_lines))

    # ---- 2. PBXFileReference entry (insert just before /* End PBXFileReference section */) ----
    fileref_indent = detect_indent_of_line(
        text,
        r"[0-9A-Fa-f]{24}[ \t]*/\* ToastSystem\.swift \*/"
        r"[ \t]*=[ \t]*\{isa = PBXFileReference;",
    )
    if not fileref_indent:
        print("ERROR: could not detect PBXFileReference indent.", file=sys.stderr)
        return 1

    fileref_line = (
        f"{fileref_indent}{fileref_id} /* {BASENAME} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {BASENAME}; sourceTree = \"<group>\"; }};\n"
    )
    end_marker = "/* End PBXFileReference section */"
    end_pos = text.find(end_marker)
    if end_pos == -1:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    i = end_pos
    while i > 0 and text[i - 1] == '\n':
        i -= 1
    insert_pos = i + 1
    text = insert_before(text, insert_pos, fileref_line)

    # ---- 3. Group child entry inside the Shared PBXGroup's children list ----
    # Use ToastSystem.swift's group child entry as the indentation reference.
    child_indent = detect_indent_of_line(
        text,
        r"[0-9A-Fa-f]{24}[ \t]*/\* ToastSystem\.swift \*/,",
    )
    if not child_indent:
        print("ERROR: could not detect group child indent.", file=sys.stderr)
        return 1
    child_line = f"{child_indent}{fileref_id} /* {BASENAME} */,\n"

    # Find the ToastSystem.swift group child entry and insert right after it.
    # The same fileRef ID (1ED5C58C75D046CCB3CEEE12) appears in 4 build files
    # too, so anchor on the group-child pattern (ends with `/* ToastSystem.swift */,`).
    anchor_re = re.compile(
        r"(?m)^([ \t]*)[0-9A-Fa-f]{24}[ \t]*/\* ToastSystem\.swift \*/,[ \t]*\n"
    )
    am = anchor_re.search(text)
    if am is None:
        print("ERROR: ToastSystem.swift group child anchor not found.", file=sys.stderr)
        return 1
    insert_pos = am.end()
    text = insert_before(text, insert_pos, child_line)

    # ---- 4. Sources build phase entries (one per target) ----
    # For each target's Sources phase, find the ToastSystem.swift entry and
    # insert a Haptics.swift entry right after it (matching indentation).
    sources_indent = detect_indent_of_line(
        text,
        r"[0-9A-Fa-f]{24}[ \t]*/\* ToastSystem\.swift in Sources \*/,",
    )
    if not sources_indent:
        print("ERROR: could not detect Sources phase entry indent.", file=sys.stderr)
        return 1

    # Map each ToastSystem build ID to its phase so we use the right Haptics
    # build ID per phase. The ToastSystem.swift build IDs (one per target) are
    # scattered across the 4 Sources phases; we insert Haptics.swift right
    # after each ToastSystem.swift entry, using the build ID for that target.
    toast_build_to_target = {}
    toast_fileref = "1ED5C58C75D046CCB3CEEE12"
    bf_re = re.compile(
        r"(?m)^([ \t]*)([0-9A-Fa-f]{24})[ \t]*/\* ToastSystem\.swift in Sources \*/"
        r"[ \t]*=[ \t]*\{isa = PBXBuildFile; fileRef = "
        + re.escape(toast_fileref)
        + r"[ \t]*/\* ToastSystem\.swift \*/; \};"
    )
    for m in bf_re.finditer(text):
        bid = m.group(2)
        # Figure out which target this build ID is registered under by checking
        # which Sources phase references it.
        for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
            phase_block = find_phase_block(text, phase_id)
            if phase_block is None:
                continue
            bs, be, _ = phase_block
            if bid in text[bs:be]:
                continue  # this is the Sources PHASE, not the PBXBuildFile section
        # The build file ID itself doesn't tell us the target directly, but the
        # Sources phase entry that references it does. Find which phase has a
        # `/* ToastSystem.swift in Sources */` entry with this build ID.
        for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
            phase_block = find_phase_block(text, phase_id)
            if phase_block is None:
                continue
            bs, be, _ = phase_block
            phase_body = text[bs:be]
            if re.search(r"\b" + re.escape(bid) + r"\b", phase_body):
                toast_build_to_target[bid] = target
                break

    # For each ToastSystem.swift Sources phase entry, insert Haptics.swift after.
    sources_anchor_re = re.compile(
        r"(?m)^([ \t]*)[0-9A-Fa-f]{24}[ \t]*/\* ToastSystem\.swift in Sources \*/,[ \t]*\n"
    )
    # IMPORTANT: process matches from end to start so earlier insertions don't
    # shift the offsets of later matches in the (mutating) text.
    matches = list(sources_anchor_re.finditer(text))
    matches.reverse()

    inserted_count = 0
    for m in matches:
        # Extract the build ID from the matched line.
        line = text[m.start():m.end()]
        bid_m = re.search(r"\b([0-9A-Fa-f]{24})\b", line)
        if bid_m is None:
            continue
        bid = bid_m.group(1)
        target = toast_build_to_target.get(bid)
        if target is None:
            # Fallback: detect target by phase ID at the insertion point.
            # Walk forward to find the containing phase header.
            continue
        haptics_bid = build_ids[target]
        indent = m.group(1)
        new_line = f"{indent}{haptics_bid} /* {BASENAME} in Sources */,\n"
        text = insert_before(text, m.end(), new_line)
        inserted_count += 1

    if inserted_count == 0:
        print("ERROR: could not insert any Sources phase entries.", file=sys.stderr)
        return 1
    if inserted_count < len(TARGET_ORDER):
        print(f"WARNING: only inserted {inserted_count}/{len(TARGET_ORDER)} Sources phase entries.", file=sys.stderr)

    write_text(PBXPROJ_PATH, text)
    print(f"Successfully registered {BASENAME} in pbxproj.")
    print(f"  fileRef = {fileref_id}")
    for t in TARGET_ORDER:
        print(f"  {t} buildFile = {build_ids[t]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
