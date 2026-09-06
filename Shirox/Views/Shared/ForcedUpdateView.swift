#if canImport(UIKit)
import SwiftUI

// MARK: - Forced Update View
//
// The full-screen gate shown whenever AppUpdateManager confirms a newer
// version exists. It is presented as a fullScreenCover from the root view
// and deliberately offers NO dismissal — the cover clears only when a real
// version check confirms the app is current again (i.e. after the user
// installs the update they downloaded from GitHub and iOS relaunches the
// app), or the user exits demo mode from the gate itself.
//
// v2.18 — The gate offers exactly ONE thing: a download from GitHub. The
// "Download from GitHub" button hands the release's IPA asset URL to
// Safari (the same hop the About page's Update button has always made)
// and GitHub serves the file. How that file gets installed is between the
// user and whatever sideload tool they choose — the app deliberately
// probes for, talks to, or integrates with NO installer. v2.17's in-app
// download, SHA-256 verification, AltStore handoff and share-package
// fallback were removed wholesale: the single GitHub hop serves every
// sideload method equally, which is all the screen ever needs to do.
//
// Visual language mirrors the rest of Shirox+ exactly: Color.appAccent
// (user's chosen accent), .rounded typography with monospaced digits,
// secondary.opacity(0.08) cards in 22pt continuous corners, capsule pills
// with tint.opacity(0.12) fills, hairline .primary.opacity(0.06) strokes,
// spring(response: 0.3–0.5, dampingFraction: 0.8) motion, glow language
// from GlowToggleStyle (shadow radius scaled by glowIntensity), and
// Haptics on every meaningful interaction.
struct ForcedUpdateView: View {
    @ObservedObject private var updateManager = AppUpdateManager.shared

    @State private var appeared = false
    @State private var changelogExpanded = false
    @State private var orbitAngle: Double = 0
    @State private var breath = false
    @State private var bob: CGFloat = 0

    private var info: AppUpdateManager.UpdateInfo? {
        switch updateManager.state {
        case .available(let info), .dismissed(let info): return info
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            background
            ScrollView(showsIndicators: false) {
                VStack(spacing: 26) {
                    Color.clear.frame(height: 8)
                    identityMark
                        .modifier(Entrance(index: 0, appeared: appeared))
                    heroEmblem
                        .modifier(Entrance(index: 1, appeared: appeared, hero: true))
                    titleBlock
                        .modifier(Entrance(index: 2, appeared: appeared))
                    if let info {
                        versionTransition(current: info.currentVersion, next: info.newVersion)
                            .modifier(Entrance(index: 3, appeared: appeared))
                        changelogCard(info)
                            .modifier(Entrance(index: 4, appeared: appeared))
                        ctaButton(info)
                            .modifier(Entrance(index: 5, appeared: appeared))
                        footerBlock
                            .modifier(Entrance(index: 6, appeared: appeared))
                    } else {
                        ProgressView()
                            .padding(.top, 40)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            Haptics.warning()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            // Ambient loops — orbit drift, blob breathing, icon float.
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { orbitAngle = 360 }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { breath = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { bob = 5 }
        }
    }

    // MARK: - CTA

    /// The single action this screen offers: open the release's IPA on
    /// GitHub in Safari. Nothing is downloaded inside the app, and no
    /// installer is probed or launched — the user's sideload tool fetches
    /// the file from GitHub itself.
    private func ctaButton(_ info: AppUpdateManager.UpdateInfo) -> some View {
        Button {
            Haptics.light()
            UIApplication.shared.open(info.downloadURL)
        } label: {
            Label("Download from GitHub", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(UpdatePrimaryButtonStyle())
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Circle()
                .fill(RadialGradient(colors: [Color.appAccent.opacity(0.20), Color.appAccent.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 210))
                .frame(width: 360, height: 360)
                .offset(x: 150, y: -290)
                .scaleEffect(breath ? 1.12 : 0.9)
            Circle()
                .fill(RadialGradient(colors: [Color.purple.opacity(0.13), Color.purple.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 180))
                .frame(width: 300, height: 300)
                .offset(x: -160, y: 340)
                .scaleEffect(breath ? 0.92 : 1.1)
        }
        .ignoresSafeArea()
    }

    // MARK: - Identity

    private var identityMark: some View {
        VStack(spacing: 8) {
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.appAccent.opacity(0.35), radius: 10, y: 4)
            Text("SHIROX+")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hero

    private var heroEmblem: some View {
        ZStack {
            // Ambient glow behind the disc.
            Circle()
                .fill(Color.appAccent.opacity(0.16))
                .frame(width: 185, height: 185)
                .blur(radius: 36)
                .scaleEffect(breath ? 1.08 : 0.94)

            // Dashed orbit + three travelling sparkles. The whole container
            // rotates; each dot is pre-rotated 120° apart on the ring.
            ZStack {
                Circle()
                    .stroke(Color.appAccent.opacity(0.38),
                            style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 8]))
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == 0 ? Color.appAccent : Color.secondary.opacity(0.55))
                        .frame(width: i == 0 ? 6 : 4)
                        .offset(y: -106)
                        .rotationEffect(.degrees(Double(i) * 120))
                }
            }
            .frame(width: 212, height: 212)
            .rotationEffect(.degrees(orbitAngle))

            emblemDisc
        }
        .frame(width: 250, height: 250)
    }

    private var emblemDisc: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .stroke(LinearGradient(colors: [Color.appAccent.opacity(0.85), Color.purple.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5)
            Circle()
                .fill(Color.appAccent.opacity(0.07))
                .padding(12)

            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [Color.appAccent, Color.purple.opacity(0.8)],
                                                 startPoint: .top, endPoint: .bottom))
                .offset(y: bob)
        }
        .frame(width: 150, height: 150)
        .shadow(color: Color.appAccent.opacity(Color.glowEnabled ? 0.35 : 0),
                radius: Color.glowEnabled ? Color.glowRadiusLarge * 0.45 : 0, y: 10)
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(spacing: 8) {
            Text("Update Required")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("A required update is available for Shirox+ — grab it from GitHub below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Version transition

    private func versionTransition(current: String, next: String) -> some View {
        HStack(spacing: 10) {
            Text(current)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.8))

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appAccent)
                .scaleEffect(x: appeared ? 1 : 0.1, y: 1)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.35), value: appeared)

            Text(next)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.7)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.appAccent.opacity(0.4), radius: 8, y: 3)
        }
    }

    // MARK: - Changelog

    private func changelogCard(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("What's New")
                    .font(.headline)
                Spacer()
                if let date = info.releaseDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            Text(info.changelog)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(changelogExpanded ? nil : 7)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: changelogExpanded)
            if info.changelog.count > 420 {
                Button(changelogExpanded ? "Show Less" : "Show All") {
                    Haptics.light()
                    changelogExpanded.toggle()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Footer

    private var footerBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text("This update is required to keep using Shirox+.")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)

            if let last = updateManager.lastSuccessfulCheck {
                Text("Checked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if updateManager.simulateOutdated {
                Button {
                    Haptics.selection()
                    updateManager.exitDemo()
                } label: {
                    Label("Exit demo mode", systemImage: "xmark.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.appAccent.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Entrance stagger

/// Fades + slides a section in when the gate first appears, staggered by
/// index so the screen composes itself top-to-bottom.
private struct Entrance: ViewModifier {
    let index: Int
    let appeared: Bool
    var hero = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : (hero ? 0.82 : 0.97))
            .offset(y: appeared ? 0 : 24)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.07 * Double(index)),
                       value: appeared)
    }
}

// MARK: - Button style

/// The prominent CTA — gradient capsule with the app's glow language
/// (shadow radius scaled by the global glow settings) and a press spring.
/// Matches the app's bold .rounded typography.
private struct UpdatePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.72)],
                                                  startPoint: .top, endPoint: .bottom))
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                }
            )
            .shadow(color: Color.appAccent.opacity(Color.glowEnabled ? 0.45 : 0),
                    radius: Color.glowEnabled ? Color.glowRadiusLarge * 0.4 : 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
#endif
