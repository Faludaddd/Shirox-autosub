#!/usr/bin/env python3
"""
v2.24 pre-flight verification — mirrors the verify_v223.py pattern:
 - swift brace/paren balance on every changed/new file
 - music-code zero-reference audit
 - pbxproj registration + VLCKit absence + version consistency
 - provider chain wiring (UnifiedProviderSystem usage per screen)
 - update-flow labels (DOWNLOAD NOW / DELETE FILE / FIND FILE)
"""
import json
import os
import re
import subprocess
import sys

os.chdir("/home/z/my-project/Shirox")
failures = []


def check(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def balance(path):
    """Proper Swift tokenizer: strings (incl. \"\"\" multiline) are skipped
    BEFORE comments, so URLs like https://... inside strings never get
    chopped as line comments. Comments are then skipped. Only real
    braces/parens are counted."""
    text = open(path).read()
    i, n = 0, len(text)
    depth_b, depth_p = 0, 0
    while i < n:
        c = text[i]
        if c == '"':
            # Triple-quoted multi-line string?
            if text[i:i+3] == '"""':
                i += 3
                while i < n and text[i:i+3] != '"""':
                    i += 1
                i = min(i + 3, n)
                continue
            # Regular string (handles \ escapes and \(interpolation)).
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i+1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i+1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i+1] == '/'):
                i += 1
            i += 2
            continue
        if c == '{':
            depth_b += 1
        elif c == '}':
            depth_b -= 1
        elif c == '(':
            depth_p += 1
        elif c == ')':
            depth_p -= 1
        i += 1
    return depth_b, depth_p


# 1. Swift balance on every changed + new file
swift_files = [
    "Shirox/Services/TVDBProvider.swift",
    "Shirox/Services/KitsuProvider.swift",
    "Shirox/Services/AniDBProvider.swift",
    "Shirox/Services/MangaBakaProvider.swift",
    "Shirox/Services/ScheduleProviders.swift",
    "Shirox/Services/UnifiedProviderSystem.swift",
    "Shirox/Services/AniListService.swift",
    "Shirox/Services/MALDiscoveryService.swift",
    "Shirox/Services/AppUpdateManager.swift",
    "Shirox/ShiroxApp.swift",
    "Shirox/ViewModels/AniListDetailViewModel.swift",
    "Shirox/ViewModels/BrowseViewModel.swift",
    "Shirox/ViewModels/HomeViewModel.swift",
    "Shirox/ViewModels/SearchViewModel.swift",
    "Shirox/Views/AniListDetailView.swift",
    "Shirox/Views/AniListMangaDetailView.swift",
    "Shirox/Views/HomeView.swift",
    "Shirox/Views/MangaHomeView.swift",
    "Shirox/Views/SettingsView.swift",
    "Shirox/Views/Settings/DataSourcesSettingsPage.swift",
    "Shirox/Views/Shared/ForcedUpdateView.swift",
    "Shirox/Views/Shared/SettingsSearchIndex.swift",
    "Shirox/Views/Shared/UpdateLogPage.swift",
]
for f in swift_files:
    b, p = balance(f)
    check(f"balance {f.split('/')[-1]}", b == 0 and p == 0, f"braces={b} parens={p}")

# 2. Music zero-reference audit (code — changelog text is history, excluded)
music_gone = True
for root_dir in ["Shirox/", "ShiroxTests/"]:
    out = subprocess.run(
        ["grep", "-rn", "-l", "-E",
         "AnimeThemesService|MusicPlayerManager|MusicPlayerView|MusicView|AnimeSong|VLCKit|vlckit",
         root_dir],
        capture_output=True, text=True).stdout.strip()
    hits = [l for l in out.splitlines() if l and "UpdateLogPage" not in l]
    if hits:
        music_gone = False
        print("   music refs:", hits)
check("Music code fully removed (changelog history excluded)", music_gone)

# 3. pbxproj: new files registered, VLCKit absent, version bumped
pbx = open("Shirox.xcodeproj/project.pbxproj").read()
for f in ["TVDBProvider", "KitsuProvider", "AniDBProvider", "MangaBakaProvider",
          "ScheduleProviders", "UnifiedProviderSystem", "DataSourcesSettingsPage"]:
    count = pbx.count(f"{f}.swift")
    check(f"pbxproj registers {f}.swift (>=10 refs)", count >= 10, f"count={count}")
check("pbxproj VLCKit gone", "vlc" not in pbx.lower())
check("MARKETING_VERSION 2.24 x6", pbx.count("MARKETING_VERSION = 2.24") == 6,
      f"count={pbx.count('MARKETING_VERSION = 2.24')}")
check("VERSION file 2.24", open("VERSION").read().strip() == "2.24")

import json
apps = json.load(open("apps.json"))
check("apps.json versions[0] = 2.24", apps["apps"][0]["versions"][0]["version"] == "2.24")
check("no top-level version key (schema unchanged)", "version" not in apps)

log = open("Shirox/Views/Shared/UpdateLogPage.swift").read()
check("UpdateLogPage has 2.24 entry", 'version: "2.24"' in log)
check("UpdateLogPage Removed category renders", 'title: "Removed"' in log)

# 4. Provider chain wiring
ups = open("Shirox/Services/UnifiedProviderSystem.swift").read()
check("anime chain order", "recommendedAnimeOrder: [MetaProviderKind] = [.tvdb, .mal, .anilist, .kitsu, .anidb]" in ups)
check("manga chain order", "recommendedMangaOrder: [MetaProviderKind] = [.mangabaka, .mal, .anilist]" in ups)
check("schedule chain order", "recommendedScheduleOrder: [MetaProviderKind] = [.anichart, .animeschedule, .mal, .anilist]" in ups)
check("health states present", all(s in ups for s in [".healthy", ".degraded", ".rateLimited", ".unavailable", ".offline", ".unknown"]))
check("field-level fallback (tvdbDetailFields)", "func tvdbDetailFields" in ups)
check("field-level fallback (mangaDetailFields)", "func mangaDetailFields" in ups)
check("in-flight dedup", "inFlight" in ups)
check("failure cache", "failureCache" in ups)

home_vm = open("Shirox/ViewModels/HomeViewModel.swift").read()
check("HomeViewModel through UnifiedProviderSystem",
      "UnifiedProviderSystem.shared.trending()" in home_vm)
search_vm = open("Shirox/ViewModels/SearchViewModel.swift").read()
check("SearchViewModel through UnifiedProviderSystem", "UnifiedProviderSystem" in search_vm)
browse_vm = open("Shirox/ViewModels/BrowseViewModel.swift").read()
check("BrowseViewModel through UnifiedProviderSystem", "UnifiedProviderSystem" in browse_vm)
detail_vm = open("Shirox/ViewModels/AniListDetailViewModel.swift").read()
check("DetailViewModel TVDB-first enrichment", "tvdbDetailFields" in detail_vm)
home_v = open("Shirox/Views/HomeView.swift").read()
check("Schedule through unified chain", "scheduleEntries" in home_v)
manga_v = open("Shirox/Views/MangaHomeView.swift").read()
check("Manga home through unified chain", "UnifiedProviderSystem" in manga_v)
settings = open("Shirox/Views/SettingsView.swift").read()
check("Settings links Data Sources page", "DataSourcesSettingsPage()" in settings)
idx = open("Shirox/Views/Shared/SettingsSearchIndex.swift").read()
check("Settings search indexes Data Sources", "Data Sources" in idx)

# 5. Update flow labels
fuv = open("Shirox/Views/Shared/ForcedUpdateView.swift").read()
check("DOWNLOAD NOW present", '"Download Now"' in fuv)
check("UPDATE NOW gone", '"Update Now"' not in fuv)
check("DELETE FILE present", "deletePackage" in fuv and "Delete Downloaded File" in fuv)
check("FIND FILE present", "DocumentBrowserSheet" in fuv)
check("file-exists check (no fake completion)", "hasDownloadedPackage" in fuv)
aum = open("Shirox/Services/AppUpdateManager.swift").read()
check("semantic comparison", "normalizedComponents" in aum)


def strip_comments(source):
    out = []
    for line in source.splitlines():
        # Doc/line comments (URLs inside real strings would be in quotes;
        # AppUpdateManager URLs are quoted, so '//' on a bare line is a comment).
        if "://" in line:
            # keep quoted URLs intact — remove only comment parts after code
            quote = line.find('"')
            slash = line.find("//")
            if slash != -1 and (quote == -1 or slash < quote):
                line = line[:slash]
        else:
            slash = line.find("//")
            if slash != -1:
                line = line[:slash]
        out.append(line)
    return "\n".join(out)


check("no demo/simulate mode (code, not prose)", "simulateOutdated" not in strip_comments(aum))

# 6. Drag-and-drop present
dsp = open("Shirox/Views/Settings/DataSourcesSettingsPage.swift").read()
check("drag handle gesture", "LongPressGesture(minimumDuration: 0.25)" in dsp
      and "sequenced(before: DragGesture" in dsp)
check("drag commits persisted order", "commitDrop" in dsp and "setOrder" in dsp)

print()
if failures:
    print(f"{len(failures)} FAILURES: {failures}")
    sys.exit(1)
print("ALL CHECKS GREEN")
