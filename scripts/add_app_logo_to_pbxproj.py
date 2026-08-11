#!/usr/bin/env python3
"""
#92 — Add `Shirox/Resources/app-logo.png` to the Xcode project (project.pbxproj)
as a bundled resource so `UIImage(named: "app-logo")` resolves at runtime on
iOS / tvOS / macOS / Catalyst.

This script is idempotent: if `app-logo.png` is already registered as a
PBXFileReference, it prints a "skip" message and exits without modifying the
project.

It mirrors the layout used by the existing loose resource
(`Shirox/Resources/adult_hosts.txt`):
  - One PBXFileReference (shared across targets) with
    `lastKnownFileType = image.png`.
  - One PBXBuildFile entry per app target (iOS, tvOS, macOS). Skipped for the
    ShiroxTests target (tests don't need app resources).
  - Appended to the `Resources` PBXGroup's children list.
  - Appended to each app target's PBXResourcesBuildPhase files list.

The pbxproj on disk uses space-based indentation (16 spaces for the top-level
object key, 24 spaces for nested attributes, 32 spaces for grandchildren).
The regexes below use `[ \\t]+` so they tolerate either spaces or tabs and
work regardless of how the file was written.
"""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

# Targets to add the resource to (Tests target is intentionally excluded —
# unit tests don't need app-logo.png at runtime).
TARGET_RESOURCES_PHASE_IDS = {
    "tvos":  "121D9B362FCA5378000FF9B4",  # Shirox_tvOS Resources phase
    "ios":   "AA000003000000000000CC01",  # Shirox_iOS  Resources phase
    "macos": "AA000003000000000000CC02",  # Shirox_macOS Resources phase
}
TARGET_ORDER = ["tvos", "ios", "macos"]

BASENAME = "app-logo.png"

# Whitespace helper — matches a run of spaces and/or tabs.
WS = r"[ \t]+"


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def collect_existing_ids(text):
    """Return the set of all 24-hex-char IDs that already appear in the pbxproj."""
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
    pattern = re.compile(
        r"isa\s*=\s*PBXFileReference\b[^\n]*\bpath\s*=\s*" + re.escape(basename) + r"\b"
    )
    return bool(pattern.search(text))


def find_group_block(text, group_path):
    """
    Find the PBXGroup block whose `path = <group_path>;` attribute matches.
    Returns (block_start, block_end, children_close_index) where
    children_close_index is the insertion point (start of the `);` line that
    closes the children list).
    Returns None if not found.
    """
    # Match a PBXGroup block header: `<HEXID> /* <name> */ = {` on its own line,
    # followed by `isa = PBXGroup;` on the next line.
    header_re = re.compile(
        r"^([ \t]*)([0-9A-Fa-f]{24}) /\* ([^*]+?) \*/ = \{\n"
        r"[ \t]*isa = PBXGroup;\n",
        re.MULTILINE,
    )
    for m in header_re.finditer(text):
        block_start = m.start()
        # Find the end of this block: the next `\n<indent>};` at the same
        # indent level as the block header.
        indent = m.group(1)
        end_pattern = re.compile(r"\n" + re.escape(indent) + r"\};")
        end_match = end_pattern.search(text, m.end())
        if end_match is None:
            continue
        block_end = end_match.end()
        body = text[block_start:block_end]
        # Match the `path = <group_path>;` line inside this block.
        path_re = re.compile(
            r"\n[ \t]+path\s*=\s*" + re.escape(group_path) + r"\s*;\n"
        )
        if not path_re.search(body):
            continue
        # Locate the children = ( ... ); block within this group.
        children_open_match = re.search(r"\n[ \t]+children = \(\n", body)
        if children_open_match is None:
            continue
        children_close_match = re.search(r"\n[ \t]+\);", body[children_open_match.end():])
        if children_close_match is None:
            continue
        close_line_start_in_body = children_open_match.end() + children_close_match.start()
        children_close = block_start + close_line_start_in_body + 1
        return (block_start, block_end, children_close)
    return None


def find_resources_phase_block(text, phase_id):
    """
    Find the PBXResourcesBuildPhase block whose ID matches.
    Returns (block_start, block_end, files_close_index) where files_close_index
    is the insertion point (start of the `);` line that closes the files list).
    Returns None if not found.
    """
    header_pattern = re.compile(
        r"^([ \t]*)" + re.escape(phase_id) + r"\s*/\*\s*Resources\s*\*/\s*=\s*\{",
        re.MULTILINE,
    )
    m = header_pattern.search(text)
    if not m:
        return None
    block_start = m.start()
    indent = m.group(1)
    end_pattern = re.compile(r"\n" + re.escape(indent) + r"\};")
    end_match = end_pattern.search(text, m.end())
    if end_match is None:
        return None
    block_end = end_match.end()
    body = text[block_start:block_end]
    # Locate `files = ( ... );`.
    files_open_match = re.search(r"\n[ \t]+files = \(\n", body)
    if files_open_match is None:
        # Files list might be empty: `files = (\n<indent>);` — handle that too.
        empty_match = re.search(r"\n[ \t]+files = \(\n[ \t]+\);", body)
        if empty_match is None:
            return None
        files_open = block_start + empty_match.start() + len("\n[ \t]+files = (\n".replace("[ \t]+", "    "))
        # The above is fragile; just compute the insertion point as the
        # position right after `files = (\n`.
        idx = text.find("files = (", block_start) + len("files = (\n")
        return (block_start, block_end, idx)
    files_close_match = re.search(r"\n[ \t]+\);", body[files_open_match.end():])
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
    such as `/* End PBXBuildFile section */`. The new entries land on a new
    line after the last existing entry, and the empty line that precedes the
    end marker is preserved after the new entries.
    """
    end_pos = text.find(section_end_marker)
    if end_pos == -1:
        return None
    i = end_pos
    while i > 0 and text[i - 1] == '\n':
        i -= 1
    return i + 1


def build_buildfile_line(build_id, basename, fileref_id):
    # Indentation matches the existing PBXBuildFile entries (16 spaces).
    return (
        f"                {build_id} /* {basename} in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {fileref_id} /* {basename} */; }};\n"
    )


def build_fileref_line(fileref_id, basename):
    # Indentation matches the existing PBXFileReference entries (16 spaces).
    # `lastKnownFileType = image.png` matches how Xcode records loose PNGs.
    return (
        f"                {fileref_id} /* {basename} */ = "
        f"{{isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = image.png; "
        f"path = {basename}; sourceTree = \"<group>\"; }};\n"
    )


def build_group_child_line(fileref_id, basename):
    # Indentation matches existing children entries inside a PBXGroup (32 spaces).
    return f"                                {fileref_id} /* {basename} */,\n"


def build_resources_phase_line(build_id, basename):
    # Indentation matches existing files entries inside a Resources build phase (32 spaces).
    return f"                                {build_id} /* {basename} in Resources */,\n"


def main():
    text = read_text(PBXPROJ_PATH)
    existing_ids = collect_existing_ids(text)
    used = set()

    # Idempotency check.
    if file_already_registered(text, BASENAME):
        print(f"[skip] {BASENAME} — already present in pbxproj")
        return 0

    # Pre-generate IDs: 1 fileRef + 3 buildFiles (one per app target).
    fileref_id = make_unique_id(existing_ids, used)
    build_ids = {t: make_unique_id(existing_ids, used) for t in TARGET_ORDER}

    # 1) Insert PBXBuildFile entries just before `/* End PBXBuildFile section */`.
    buildfile_section_end = "/* End PBXBuildFile section */"
    buildfile_insert_pos = find_section_end_insertion_point(text, buildfile_section_end)
    if buildfile_insert_pos is None:
        print("ERROR: PBXBuildFile section end marker not found.", file=sys.stderr)
        return 1
    buildfile_lines = [
        build_buildfile_line(build_ids[t], BASENAME, fileref_id)
        for t in TARGET_ORDER
    ]
    text = insert_before(text, buildfile_insert_pos, buildfile_lines)

    # 2) Insert PBXFileReference entry just before `/* End PBXFileReference section */`.
    fileref_section_end = "/* End PBXFileReference section */"
    fileref_insert_pos = find_section_end_insertion_point(text, fileref_section_end)
    if fileref_insert_pos is None:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    fileref_lines = [build_fileref_line(fileref_id, BASENAME)]
    text = insert_before(text, fileref_insert_pos, fileref_lines)

    # 3) Insert group child entry at the end of the `Resources` PBXGroup's
    #    children list. `path = Resources` is what identifies this group.
    block_info = find_group_block(text, "Resources")
    if block_info is None:
        print("ERROR: Could not locate PBXGroup with path='Resources'.", file=sys.stderr)
        return 1
    _, _, children_close = block_info
    child_lines = [build_group_child_line(fileref_id, BASENAME)]
    text = insert_before(text, children_close, child_lines)

    # 4) Insert Resources build phase entries at the end of each target's
    #    files list.
    for target, phase_id in TARGET_RESOURCES_PHASE_IDS.items():
        block_info = find_resources_phase_block(text, phase_id)
        if block_info is None:
            print(f"ERROR: Could not locate PBXResourcesBuildPhase with id={phase_id}.", file=sys.stderr)
            return 1
        _, _, files_close = block_info
        phase_lines = [build_resources_phase_line(build_ids[target], BASENAME)]
        text = insert_before(text, files_close, phase_lines)

    write_text(PBXPROJ_PATH, text)
    print(f"Successfully added {BASENAME} to pbxproj for {len(TARGET_ORDER)} target(s).")
    print(f"  fileRef = {fileref_id}")
    for t in TARGET_ORDER:
        print(f"  {t} buildFile = {build_ids[t]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
