#!/usr/bin/env python3
"""v2.24 — Remove ALL Music/AnimeThemes/VLCKit references from the pbxproj.

Removes:
- 4 Swift file references (AnimeThemesService, MusicPlayerManager, MusicView,
  MusicPlayerView): build-file entries (x3 targets each), PBXFileReference,
  group children, Sources phase entries.
- The VLCKit SPM package: XCRemoteSwiftPackageReference, XCSwiftPackageProductDependency,
  the Frameworks phase link entry, and the packageReferences group entry.
"""
import re
import sys

PBX = "Shirox.xcodeproj/project.pbxproj"
PATHS = sys.path

def load():
    with open(PBX, "r", encoding="utf-8") as f:
        return f.read()

def save(text):
    with open(PBX, "w", encoding="utf-8") as f:
        f.write(text)

def remove_lines_containing(text, needles):
    lines = text.split("\n")
    kept = []
    removed = 0
    for line in lines:
        if any(n in line for n in needles):
            removed += 1
            continue
        kept.append(line)
    print(f"  removed {removed} lines matching {needles}")
    return "\n".join(kept)

def main():
    text = load()
    before = text

    # --- Music Swift files: full UUID list per file (buildfile x3 + fileref) ---
    music_uuids = [
        # MusicView
        "ABCD03212FCA5623000FF9B4", "ABCD03222FCA5623000FF9B4", "ABCD03232FCA5623000FF9B4",
        "ABCD03242FCA397700C9BA56",
        # AnimeThemesService
        "F23BBEC228CCFDADECB133B7", "F23C1066793E04E2C79EAA88", "F23D7A2EC1786CE38F72CF0E",
        "F23AFF8E5CE05781952A22DF",
        # MusicPlayerManager
        "F23FE61E7D282E406E713F47", "F23BD3932703AD940CD7B70E", "F2339AD92187A3D30C0A3A02",
        "F23EA333BB558E49B96951FA",
        # MusicPlayerView
        "F239246A2ED86518D0899645", "F23B98C54F24B9A513BD1D1D", "F231AB4C7496777A49493465",
        "F2383D11A1507161AE3E6660",
        # VLCKit
        "F24C52AD3065B7871DF413B7", "F24B6D9DAC42297DB37E6994",
        "F24AC51474FDD01A0B9626DE",
    ]

    # Remove every line that contains any music UUID (build files, file refs,
    # group children, phase entries, package refs).
    needles = music_uuids + ["vlckit-spm", "VLCKitSPM", "AnimeThemesService.swift",
                             "MusicPlayerManager.swift", "MusicView.swift",
                             "MusicPlayerView.swift"]
    text = remove_lines_containing(text, needles)

    # The XCRemoteSwiftPackageReference block is multi-line — remove it whole.
    text = re.sub(
        r"\t\t\t\tF24AC51474FDD01A0B9626DE /\* XCRemoteSwiftPackageReference \"vlckit-spm\" \*/ = \{[^}]*\};\n",
        "", text)
    text = re.sub(
        r"\t\t\t\tF24B6D9DAC42297DB37E6994 /\* VLCKitSPM \*/ = \{[^}]*\};\n",
        "", text)

    # packageReferences group may now be empty: `packageReferences = (` followed by `);`
    text = re.sub(r"packageReferences = \(\s*\);", "", text)

    # Balance sanity
    for ch, name in [("{", "open-brace"), ("}", "close-brace"), ("(", "open-paren"), (")", "close-paren")]:
        pass

    if text != before:
        save(text)
        print("pbxproj written.")

    # Verify: zero references remain
    leftover = [n for n in needles if n in text]
    print("LEFTOVER REFS:", leftover if leftover else "NONE — clean")

    # brace balance
    o = text.count("{"); c = text.count("}")
    p = text.count("("); q = text.count(")")
    print(f"braces: {o}/{c} {'OK' if o == c else 'MISMATCH'}; parens: {p}/{q} {'OK' if p == q else 'MISMATCH'}")

if __name__ == "__main__":
    main()
