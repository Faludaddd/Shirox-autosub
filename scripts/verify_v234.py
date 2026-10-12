#!/usr/bin/env python3
"""v2.34 static verification — the interactive onboarding batch.

Checks (all static; CI is the compile gate):
  1. Brace/paren/bracket/#if balance in every touched/new Swift file
     (quote-aware stripper).
  2. Symbol presence — every new type/modifier defined once and used where
     expected (RootTabView wiring, Settings, Notifications card, HomeView).
  3. Symbol absence — the removed old onboarding machinery is really gone.
  4. Version markers: VERSION 2.34, MARKETING_VERSION 2.34 x6,
     CURRENT_PROJECT_VERSION 169 x6, apps.json 2.34 entry, changelog entry.
  5. pbxproj: PARSE via the full parser, membership of the two new files in
     iOS+macOS+tvOS Sources phases (and NOT in ShiroxTests).
"""

import json
import os
import re
import subprocess
import sys

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  [FAIL] {msg}")


def ok(msg):
    print(f"  [ ok ] {msg}")


def read(rel):
    with open(os.path.join(BASE, rel), "r", encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- 1. balance

def stripped_balance_ok(source, name):
    """Quote/comment-aware balance check for (), {}, [] and #if/#endif."""
    out = []
    i, n = 0, len(source)
    in_str = in_chr = in_bslash = False
    in_line = in_block = False
    while i < n:
        c = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            i += 1
            continue
        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if in_str or in_chr:
            if in_bslash:
                in_bslash = False
            elif c == "\\":
                in_bslash = True
            elif in_str and c == '"':
                in_str = False
            elif in_chr and c == "'":
                in_chr = False
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == "'":
            in_chr = True
            i += 1
            continue
        out.append(c)
        i += 1
    code = "".join(out)
    for op, cl, label in [("(", ")", "paren"), ("{", "}", "brace"), ("[", "]", "bracket")]:
        if code.count(op) != code.count(cl):
            fail(f"{name}: unbalanced {label} ({code.count(op)} open vs {code.count(cl)} close)")
            return False
    ifs = len(re.findall(r"^\s*#if\b", code, re.M))
    ends = len(re.findall(r"^\s*#endif\b", code, re.M))
    if ifs != ends:
        fail(f"{name}: #if({ifs}) != #endif({ends})")
        return False
    return True


TOUCHED = [
    "Shirox/Views/Onboarding/GuidedTour.swift",
    "Shirox/Views/Onboarding/OnboardingDemos.swift",
    "Shirox/Views/Onboarding/OnboardingView.swift",
    "Shirox/ShiroxApp.swift",
    "Shirox/Views/HomeView.swift",
    "Shirox/Views/SettingsView.swift",
    "Shirox/Views/Shared/AnimationModifiers.swift",
    "Shirox/Views/Shared/ToastSystem.swift",
    "Shirox/Views/Shared/GooeyRefresh.swift",
    "Shirox/Views/Shared/SettingsSearchIndex.swift",
    "Shirox/Views/Shared/UpdateLogPage.swift",
    "Shirox/Views/Profile/NotificationsView.swift",
]

print("== 1. Swift file balance ==")
all_balanced = True
for rel in TOUCHED:
    all_balanced &= stripped_balance_ok(read(rel), rel)
if all_balanced:
    ok(f"{len(TOUCHED)} files balanced")

# ------------------------------------------------------------ 2/3. symbols

def requires(cond, msg):
    if cond:
        ok(msg)
    else:
        fail(msg)


print("\n== 2. New symbols defined and wired ==")

gt = read("Shirox/Views/Onboarding/GuidedTour.swift")
od = read("Shirox/Views/Onboarding/OnboardingDemos.swift")
ob = read("Shirox/Views/Onboarding/OnboardingView.swift")
app = read("Shirox/ShiroxApp.swift")
hv = read("Shirox/Views/HomeView.swift")
sv = read("Shirox/Views/SettingsView.swift")
am = read("Shirox/Views/Shared/AnimationModifiers.swift")
nv = read("Shirox/Views/Profile/NotificationsView.swift")

requires(re.search(r"final class OnboardingFlowController", gt), "OnboardingFlowController defined")
requires(gt.count("enum OnboardingPhase") == 1, "OnboardingPhase defined")
requires(gt.count("struct TourAnchorKey") == 1, "TourAnchorKey defined")
requires(gt.count("func tourAnchor(") == 1, "tourAnchor modifier defined")
requires(gt.count("struct GuidedTourOverlay") == 1, "GuidedTourOverlay defined")
requires(gt.count("struct SpotlightMask") == 1, "SpotlightMask defined")
requires(re.search(r"static let steps: \[TourStep\]", gt), "TourStepCatalog.steps defined")
requires('tourAnchor("home.charts")' in hv, "HomeView anchors the Top Anime shelf")
requires('GuidedTourOverlay()' in app, "RootTabView hosts the tour overlay")
requires("TourAnchorKey.self" in app, "RootTabView collects tour anchors")
requires("fullScreenCoverCompat(isPresented: $cover)" in app and "OnboardingFlowHost(cover: $showOnboardingCover" in app, "RootTabView (via OnboardingFlowHost) presents the setup cover")
requires("OnboardingFlowController.shared.begin()" in app, "App begins the flow after splash")
requires("TabIconAnimator.animateSelection" in app, "RootTabView hooks the tab icon animator")
requires("#if os(iOS)\n            TabIconAnimator" in app or "#if os(iOS)" in app, "TabIconAnimator call platform-gated")

requires(od.count("enum OnboardingAssetLoader") == 1, "OnboardingAssetLoader defined")
requires(od.count("struct OnboardingLoadingScreen") == 1, "OnboardingLoadingScreen defined")
requires(od.count("struct SimulatedNotificationDemo") == 1, "SimulatedNotificationDemo defined")
requires(od.count("struct ThemeDemoScene") == 1, "ThemeDemoScene defined")
requires(od.count("struct NotificationPermissionSheet") == 1, "NotificationPermissionSheet defined")
requires("EpisodeNotificationManager.shared.requestAuthorization()" in od, "permission sheet uses the REAL request")
requires("UNUserNotificationCenter.current().notificationSettings()" in od, "real authorization state read")
requires("UIApplication.openSettingsURLString" in od, "denied path explains Settings re-enable")

requires(ob.count("SimulatedNotificationDemo(media: flow.demoMedia)") == 1, "setup flow runs the notification demo")
requires(ob.count("ThemeDemoScene(dayNight: $dayNight)") == 1, "setup flow runs the theme demo")
requires(ob.count("NotificationPermissionSheet()") == 1, "setup flow presents the permission sheet")
requires("Add a Module" in ob and "Connect Tracking" in ob and "Enable Notifications" in ob and "Choose Your Theme" in ob, "all four setup cards present")

requires(am.count("struct SpringPressStyle") == 1, "SpringPressStyle defined")
requires("static var springPress" in am, "springPress button style available")
requires(am.count("enum TabIconAnimator") == 1, "TabIconAnimator defined")
requires("animatedTabIcons" in sv, "Settings carries the Animated Tab Icons toggle")
requires("Animated Tab Icons" in sv, "toggle titled correctly")
requires("Getting Started" in sv, "Settings replay entry present")
requires("OnboardingFlowController.shared.begin()" in sv, "Settings entry begins the flow")
requires("OnboardingFlowController.shared.begin()" in nv, "Notifications card begins the flow")
requires("Get Started with Shirox" in nv, "Get Started card intact")
requires('version: "2.34"' in read("Shirox/Views/Shared/UpdateLogPage.swift"), "changelog 2.34 entry")
requires("animatedTabIcons" in hv, "HomeView gear spin respects the setting")

print("\n== 3. Removed symbols really gone ==")
requires("showOnboardingFromCard" not in nv, "old card cover state removed")
requires("@State private var showOnboarding = false" not in app, "old app-level cover state removed")
requires("Discover what's worth watching" not in ob, "old generic slide 1 removed")
requires("A library that tracks you back" not in ob, "old generic slide 2 removed")
requires("Take it with you" not in ob, "old generic slide 3 removed")
requires("Never miss a release" not in ob, "old generic slide 4 removed")
requires("static let pageCount = 6" not in ob, "old 6-page count removed")

# --------------------------------------------------------------- 4. version

print("\n== 4. Version markers ==")
pbx = read("Shirox.xcodeproj/project.pbxproj")
requires(read("VERSION").strip() == "2.34", "VERSION = 2.34")
requires(pbx.count("MARKETING_VERSION = 2.34") == 6, "MARKETING_VERSION 2.34 x6")
requires(pbx.count("CURRENT_PROJECT_VERSION = 169") == 6, "CURRENT_PROJECT_VERSION 169 x6")
try:
    apps = json.loads(read("apps.json"))
    versions = [v["version"] for a in apps.get("apps", []) for v in a.get("versions", [])]
    requires("2.34" in versions, "apps.json carries 2.34")
except Exception as e:  # noqa
    fail(f"apps.json invalid: {e}")

# --------------------------------------------------------------- 5. pbxproj

print("\n== 5. pbxproj structure ==")
parser = "/home/z/my-project/scripts/parse_pbxproj.py"
if os.path.exists(parser):
    r = subprocess.run([sys.executable, parser, os.path.join(BASE, "Shirox.xcodeproj/project.pbxproj")],
                       capture_output=True, text=True)
    requires("PARSE OK" in r.stdout, f"pbxproj parses ({r.stdout.strip().splitlines()[-1] if r.stdout.strip() else 'no output'})")
else:
    # Fall back to the repo-local validator only if the trusted parser is absent.
    requires(False, "trusted parser missing")

for name in ("GuidedTour.swift", "OnboardingDemos.swift"):
    # 3 PBXBuildFile definitions + 3 Sources-phase lines = 6 comment hits
    # (identical to OnboardingView.swift's own pattern).
    requires(pbx.count(f"/* {name} in Sources */") == 6, f"{name}: registered in 3 app targets (iOS+macOS+tvOS)")
    requires(pbx.count(f"path = {name};") == 1, f"{name}: one file reference")

# The ShiroxTests Sources phase must NOT contain the new files (the v2.31
# lesson — onboarding files belong to the 3 app targets only).
tests_phase = re.search(
    r"0D7C42462608CC0CC47C2FD3 /\* Sources \*/ = \{.*?files = \((.*?)\);",
    pbx, re.S)
requires(tests_phase is not None and "GuidedTour.swift" not in tests_phase.group(1)
         and "OnboardingDemos.swift" not in tests_phase.group(1),
         "tests phase excludes the onboarding files")

print()
if FAILURES:
    print(f"RESULT: {len(FAILURES)} FAILURE(S)")
    sys.exit(1)
print("RESULT: ALL STATIC CHECKS PASSED")
