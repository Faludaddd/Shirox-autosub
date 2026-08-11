#!/usr/bin/env python3
"""
Add new Swift source files to the Shirox Xcode project (project.pbxproj).

For each file, this script:
  - Generates one PBXFileReference (shared across targets)
  - Generates four PBXBuildFile entries (one per target: iOS, macOS, tvOS, Tests)
  - Appends a group child entry to the appropriate group's children list
  - Appends a Sources build phase entry to each target's Sources phase

The script is idempotent: if any of the files is already present in the
pbxproj (matched by file basename), it is skipped.
"""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

# Files to register: (relative path, group name)
# Group names must match an existing PBXGroup "path" attribute in the pbxproj.
FILES_TO_ADD = [
    ("Shirox/Services/EpisodeNotificationManager.swift",   "Services"),
    ("Shirox/Services/WesternScheduleService.swift",       "Services"),
    ("Shirox/Models/UnifiedScheduleEntry.swift",           "Models"),
    ("Shirox/Views/Shared/TransparentNavBarModifier.swift", "Shared"),
    ("Shirox/Views/Shared/AnimatedBackgroundView.swift",   "Shared"),
    ("Shirox/Views/Shared/ToastSystem.swift",              "Shared"),
    ("Shirox/Views/Shared/Haptics.swift",                  "Shared"),
    # #98 — custom pull-to-refresh overlay used by HomeView.
    ("Shirox/Views/Shared/CustomRefreshControl.swift",     "Shared"),
    # #102 — ActivityKit attributes + manager for the Episode Live Activity.
    #        The file body is wrapped in `#if os(iOS) ... #endif` so adding
    #        it to the macOS / tvOS targets is safe (empty translation unit
    #        there). ActivityKit APIs are additionally guarded with
    #        `@available(iOS 16.1, *)` to keep the iOS 15 deployment target
    #        building cleanly.
    ("Shirox/Views/Shared/EpisodeLiveActivity.swift",      "Shared"),
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
    """Return the set of all 24-hex-char IDs that already appear in the pbxproj."""
    # IDs in pbxproj are 24 hex chars, uppercase or lowercase, but typically uppercase.
    return set(re.findall(r"\b[0-9A-Fa-f]{24}\b", text))


def make_unique_id(existing_ids, used):
    """Generate a 24-hex-char ID that doesn't appear in existing_ids or used."""
    while True:
        candidate = uuid.uuid4().hex.upper()[:24]
        if candidate not in existing_ids and candidate not in used:
            used.add(candidate)
            return candidate


def file_already_registered(text, basename):
    """Return True if a PBXFileReference with the given basename already exists."""
    # Match a PBXFileReference line that references this filename.
    pattern = re.compile(
        r"isa\s*=\s*PBXFileReference\b[^\n]*\bpath\s*=\s*" + re.escape(basename) + r"\b"
    )
    return bool(pattern.search(text))


def find_group_block(text, group_path):
    """
    Find the PBXGroup block whose `path = <group_path>;` attribute matches.

    A PBXGroup block has the structure:
        \t\t<HEXID> /* <name> */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\t...
        \t\t\t);
        \t\t\tpath = <group_path>;
        \t\t\tsourceTree = "<group>";
        \t\t};

    Returns (block_start, block_end, children_close_index) where:
      - block_start/end bound the whole block (including trailing `};`)
      - children_close_index is the index of the `);` that closes the children list.
    Returns None if not found.
    """
    # Match each PBXGroup block header. The header line is
    # `\t\t<HEXID> /* <name> */ = {` immediately followed (next line) by
    # `\t\t\tisa = PBXGroup;`.
    header_re = re.compile(
        r"\t\t([0-9A-Fa-f]{24}) /\* ([^*]+?) \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
    )
    for m in header_re.finditer(text):
        block_start = m.start()
        # Find the end of this block: the next `\n\t\t};` at the same indent level.
        # Since PBXGroup blocks do not nest, the next `\n\t\t};` after the header
        # is the closing brace of this block.
        end_match = re.search(r"\n\t\t};", text[m.end():])
        if end_match is None:
            continue
        block_end = m.end() + end_match.end()
        body = text[block_start:block_end]
        # Check the path attribute matches.
        path_re = re.compile(r"\n\t\t\tpath\s*=\s*" + re.escape(group_path) + r"\s*;\n")
        if not path_re.search(body):
            continue
        # Find children = ( ... );
        children_open_match = re.search(r"\n\t\t\tchildren = \(\n", body)
        if children_open_match is None:
            continue
        children_close_match = re.search(r"\n\t\t\t\);", body[children_open_match.end():])
        if children_close_match is None:
            continue
        # children_close_match matched `\n\t\t\t);` starting at offset
        # children_open_match.end() within body.
        # We want the insertion point to be the start of the `\t\t\t);` line,
        # i.e. immediately AFTER the `\n` that precedes `\t\t\t);`.
        close_line_start_in_body = children_open_match.end() + children_close_match.start()
        # `close_line_start_in_body` is the index of the `\n` in body.
        # +1 skips that `\n` so we point at the `\t` of `\t\t\t);`.
        children_close = block_start + close_line_start_in_body + 1
        return (block_start, block_end, children_close)
    return None


def find_sources_phase_block(text, phase_id):
    """
    Find the PBXSourcesBuildPhase block whose ID matches.

    A PBXSourcesBuildPhase block has the structure:
        \t\t<phase_id> /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t\t...
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t};

    Returns (block_start, block_end, files_close_index) where files_close_index
    points at the start of the `\t\t\t);` line (the insertion point for new
    files entries).
    Returns None if not found.
    """
    # Match the block header: `\t\t<phase_id> /* Sources */ = {`
    header_pattern = re.compile(
        r"\t\t" + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{"
    )
    m = header_pattern.search(text)
    if not m:
        return None
    block_start = m.start()
    # Find `\n\t\t\tfiles = (\n` and the matching `\n\t\t\t);`.
    body_end_match = re.search(r"\n\t\t};", text[m.end():])
    if body_end_match is None:
        return None
    block_end = m.end() + body_end_match.end()
    body = text[block_start:block_end]
    files_open_match = re.search(r"\n\t\t\tfiles = \(\n", body)
    if files_open_match is None:
        return None
    files_close_match = re.search(r"\n\t\t\t\);", body[files_open_match.end():])
    if files_close_match is None:
        return None
    close_line_start_in_body = files_open_match.end() + files_close_match.start()
    files_close = block_start + close_line_start_in_body + 1
    return (block_start, block_end, files_close)


def insert_before(text, index, new_lines):
    """Insert new_lines (a list of strings, each ending in \n) before the given index."""
    return text[:index] + "".join(new_lines) + text[index:]


def find_section_end_insertion_point(text, section_end_marker):
    """
    Find the insertion point for new entries just before a section end marker
    such as `/* End PBXBuildFile section */`.

    The text typically looks like:
        ...last_entry;\n
        \n
        /* End PBXBuildFile section */\n

    We want to insert new entries AFTER the last existing entry (and its `\n`),
    and BEFORE the empty line that precedes the end marker. So the insertion
    point is the position right after `last_entry;\n` (i.e., the start of the
    empty line).

    Returns the insertion index, or None if the marker cannot be located.
    """
    end_pos = text.find(section_end_marker)
    if end_pos == -1:
        return None
    # Walk backward from end_pos to skip any trailing `\n` and the empty line.
    # The pattern is `\n\n/* End ... */` — two `\n`s before the marker.
    # We want to insert right after the first `\n` (so the new entries appear
    # on a new line after the last existing entry, and the empty line is
    # preserved before the end marker).
    # Find the `\n\n` immediately preceding the end marker.
    i = end_pos
    while i > 0 and text[i - 1] == '\n':
        i -= 1
    # `i` is now the position of the first `\n` of the trailing `\n...` sequence.
    # Insert right after this `\n` (i.e., at position i+1) — that's the start
    # of the empty line, which means new entries land on a new line after the
    # last existing entry.
    # But if there are TWO `\n`s (empty line), we want to keep the empty line
    # AFTER our new entries, so we should insert at position `i+1` (start of
    # the empty line) — this would put the empty line AFTER our entries.
    return i + 1


def insert_after(text, anchor_substr, new_lines, occurrence=1):
    """
    Insert new_lines immediately after the Nth occurrence of anchor_substr.
    The new content is inserted at the position immediately following the anchor.
    """
    idx = -1
    for _ in range(occurrence):
        idx = text.find(anchor_substr, idx + 1)
        if idx == -1:
            raise ValueError(f"Anchor not found: {anchor_substr!r}")
    insert_pos = idx + len(anchor_substr)
    return text[:insert_pos] + "".join(new_lines) + text[insert_pos:]


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

    # Idempotency: collect files that still need to be added.
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

    # Pre-generate IDs for every pending file (1 fileRef + 4 buildFiles each).
    file_records = []  # list of dicts: {basename, group, fileref_id, build_ids: {target: id}}
    for rel_path, group, basename in pending:
        fileref_id = make_unique_id(existing_ids, used)
        build_ids = {t: make_unique_id(existing_ids, used) for t in TARGET_ORDER}
        file_records.append({
            "basename": basename,
            "group": group,
            "fileref_id": fileref_id,
            "build_ids": build_ids,
        })

    # 1) Insert PBXBuildFile entries just before `/* End PBXBuildFile section */`.
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

    # 2) Insert PBXFileReference entries just before `/* End PBXFileReference section */`.
    fileref_section_end = "/* End PBXFileReference section */"
    fileref_insert_pos = find_section_end_insertion_point(text, fileref_section_end)
    if fileref_insert_pos is None:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    fileref_lines = [build_fileref_line(rec["fileref_id"], rec["basename"]) for rec in file_records]
    text = insert_before(text, fileref_insert_pos, fileref_lines)

    # 3) Insert group child entries at the end of each group's children list.
    # Group by group path to insert all children for a group in one shot.
    by_group = {}
    for rec in file_records:
        by_group.setdefault(rec["group"], []).append(rec)

    for group_path, recs in by_group.items():
        block_info = find_group_block(text, group_path)
        if block_info is None:
            print(f"ERROR: Could not locate PBXGroup with path={group_path!r}.", file=sys.stderr)
            return 1
        _, _, children_close = block_info
        child_lines = [build_group_child_line(rec["fileref_id"], rec["basename"]) for rec in recs]
        text = insert_before(text, children_close, child_lines)

    # 4) Insert Sources build phase entries at the end of each target's files list.
    for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
        block_info = find_sources_phase_block(text, phase_id)
        if block_info is None:
            print(f"ERROR: Could not locate PBXSourcesBuildPhase with id={phase_id}.", file=sys.stderr)
            return 1
        _, _, files_close = block_info
        phase_lines = []
        for rec in file_records:
            phase_lines.append(build_sources_phase_line(rec["build_ids"][target], rec["basename"]))
        text = insert_before(text, files_close, phase_lines)

    write_text(PBXPROJ_PATH, text)
    print(f"Successfully added {len(file_records)} file(s) to pbxproj for 4 targets each.")
    for rec in file_records:
        print(f"  + {rec['basename']}  (group={rec['group']}, fileRef={rec['fileref_id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
