#!/usr/bin/env python3
"""
v2.24 — Register the new provider-architecture files in project.pbxproj.

Files:
  Services: TVDBProvider, KitsuProvider, AniDBProvider, MangaBakaProvider,
            ScheduleProviders, UnifiedProviderSystem
  Views/Settings: DataSourcesSettingsPage  (new "Settings" PBXGroup under Views)

Each file gets: 1 PBXFileReference + 4 PBXBuildFile entries (iOS, macOS,
tvOS, Tests) + group child entry + 4 Sources-phase entries.
A new PBXGroup "Settings" (path = Settings) is created as a child of the
Views group for the settings page.

Idempotent: skips files already registered.
"""

import os
import re
import sys
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ_PATH = os.path.join(PROJECT_ROOT, "Shirox.xcodeproj", "project.pbxproj")

FILES_TO_ADD = [
    ("Shirox/Services/TVDBProvider.swift",            "Services"),
    ("Shirox/Services/KitsuProvider.swift",           "Services"),
    ("Shirox/Services/AniDBProvider.swift",           "Services"),
    ("Shirox/Services/MangaBakaProvider.swift",       "Services"),
    ("Shirox/Services/ScheduleProviders.swift",       "Services"),
    ("Shirox/Services/UnifiedProviderSystem.swift",   "Services"),
    ("Shirox/Views/Settings/DataSourcesSettingsPage.swift", "Settings"),
]

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
        children_close_match = re.search(r"\n[ \t]*\);", body[children_open_match.end():])
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
    files_close_match = re.search(r"\n[ \t]*\);", body[files_open_match.end():])
    if files_close_match is None:
        return None
    close_line_start_in_body = files_open_match.end() + files_close_match.start()
    files_close = block_start + close_line_start_in_body + 1
    return (block_start, block_end, files_close)


def insert_before(text, index, new_lines):
    return text[:index] + "".join(new_lines) + text[index:]


def find_section_end_insertion_point(text, section_end_marker):
    """
    Find the insertion point for new entries on the line BEFORE the section
    end marker. The marker line may be indented (the v2.23 pbxproj had
    `                /* End PBXBuildFile section */`), so we locate the
    marker, then back up to the START of its line and insert there —
    never inside the marker's `/*` (which is exactly the corruption that
    broke CI build 34164191391).
    """
    end_pos = text.find(section_end_marker)
    if end_pos == -1:
        return None
    # Back up to the start of the marker's line (right after the preceding \n).
    i = end_pos
    while i > 0 and text[i - 1] != '\n':
        i -= 1
    # If the marker line is the first thing after the last entry (no blank
    # line), i now points at the marker line start — inserting here is safe.
    # When a blank line separates them, prefer inserting after the previous
    # content line (keep the blank line adjacent to the marker).
    if i >= 2 and text[i - 2] == '\n':
        # There's an empty line before the marker: insert at its start.
        return i - 1
    return i


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

    needs_settings_group = any(g == "Settings" for _, g, _ in pending)
    settings_group_exists = find_group_block(text, "Settings") is not None

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

    # 1) Create the "Settings" PBXGroup if needed (child of Views group).
    #    The group definition embeds its file children directly —
    #    find_group_block cannot parse an empty children list, so the
    #    DataSourcesSettingsPage child entry is written here and step 4
    #    skips the "Settings" group lookup entirely.
    settings_children_embedded = False
    settings_group_id = None
    if needs_settings_group and not settings_group_exists:
        views_block = find_group_block(text, "Views")
        if views_block is None:
            print("ERROR: Views group not found.", file=sys.stderr)
            return 1
        settings_group_id = make_unique_id(existing_ids, used)
        settings_children = [rec for rec in file_records if rec["group"] == "Settings"]
        embedded_child_lines = "".join(
            f"                                {rec['fileref_id']} /* {rec['basename']} */,\n"
            for rec in settings_children
        )
        group_def = (
            f"                {settings_group_id} /* Settings */ = {{\n"
            f"                        isa = PBXGroup;\n"
            f"                        children = (\n"
            f"{embedded_child_lines}"
            f"                        );\n"
            f"                        path = Settings;\n"
            f"                        sourceTree = \"<group>\";\n"
            f"                }};\n"
        )
        # Insert the group definition right before the Views group block.
        text = insert_before(text, views_block[0], [group_def])
        # Child reference to the new group inside Views' children
        # (recompute the Views block after the edit shifted offsets).
        views_block = find_group_block(text, "Views")
        _, _, views_children_close = views_block
        child_ref = f"                                {settings_group_id} /* Settings */,\n"
        text = insert_before(text, views_children_close, [child_ref])
        settings_children_embedded = True
        print(f"Created PBXGroup 'Settings' ({settings_group_id}) under Views.")
    elif settings_group_exists:
        # Reuse: find the existing Settings group's ID from Views' children.
        views_block = find_group_block(text, "Views")
        m = re.search(r"([0-9A-Fa-f]{24}) /\* Settings \*/,\n", text[views_block[0]:views_block[1]])
        settings_group_id = m.group(1) if m else None

    # 2) PBXBuildFile entries before End PBXBuildFile section.
    buildfile_insert_pos = find_section_end_insertion_point(text, "/* End PBXBuildFile section */")
    if buildfile_insert_pos is None:
        print("ERROR: PBXBuildFile section end marker not found.", file=sys.stderr)
        return 1
    buildfile_lines = []
    for rec in file_records:
        for target in TARGET_ORDER:
            buildfile_lines.append(
                f"\t\t{rec['build_ids'][target]} /* {rec['basename']} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {rec['fileref_id']} /* {rec['basename']} */; }};\n"
            )
    text = insert_before(text, buildfile_insert_pos, buildfile_lines)

    # 3) PBXFileReference entries before End PBXFileReference section.
    fileref_insert_pos = find_section_end_insertion_point(text, "/* End PBXFileReference section */")
    if fileref_insert_pos is None:
        print("ERROR: PBXFileReference section end marker not found.", file=sys.stderr)
        return 1
    fileref_lines = [
        f"\t\t{rec['fileref_id']} /* {rec['basename']} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {rec['basename']}; sourceTree = \"<group>\"; }};\n"
        for rec in file_records
    ]
    text = insert_before(text, fileref_insert_pos, fileref_lines)

    # 4) Group child entries (skip Settings — embedded at creation time).
    by_group = {}
    for rec in file_records:
        if settings_children_embedded and rec["group"] == "Settings":
            continue
        by_group.setdefault(rec["group"], []).append(rec)
    for group_path, recs in by_group.items():
        block_info = find_group_block(text, group_path)
        if block_info is None:
            print(f"ERROR: Could not locate PBXGroup with path={group_path!r}.", file=sys.stderr)
            return 1
        _, _, children_close = block_info
        child_lines = [f"\t\t\t\t{rec['fileref_id']} /* {rec['basename']} */,\n" for rec in recs]
        text = insert_before(text, children_close, child_lines)

    # 5) Sources build phase entries.
    for target, phase_id in TARGET_SOURCES_PHASE_IDS.items():
        block_info = find_sources_phase_block(text, phase_id)
        if block_info is None:
            print(f"ERROR: Could not locate PBXSourcesBuildPhase with id={phase_id}.", file=sys.stderr)
            return 1
        _, _, files_close = block_info
        phase_lines = [
            f"\t\t\t\t{rec['build_ids'][target]} /* {rec['basename']} in Sources */,\n"
            for rec in file_records
        ]
        text = insert_before(text, files_close, phase_lines)

    write_text(PBXPROJ_PATH, text)
    print(f"Successfully added {len(file_records)} file(s) to pbxproj for 4 targets each.")
    for rec in file_records:
        print(f"  + {rec['basename']}  (group={rec['group']}, fileRef={rec['fileref_id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
