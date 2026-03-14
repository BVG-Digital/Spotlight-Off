// WelcomeView.swift
// First-launch onboarding screen.
//
// Shown automatically on first launch (hasSeenWelcome UserDefaults key absent).
// Also accessible via "Setup Guide…" in the menu bar dropdown.
//
// Design: deep dark background with Liquid Glass surfaces on macOS 26 Tahoe;
// graceful dark frosted-glass card fallback on macOS 14–25.
//
// Glass elements on macOS 26:
//   • Steps card  — .glassEffect(.regular, in: RoundedRectangle)
//   • Step circles — .glassEffect(.regular.tint(accentColor), in: .circle)
//   • Get Started  — .glassEffect(.regular.tint(accentColor), in: RoundedRectangle)
//
// Fallback on macOS 14–25:
//   • Cards use a semi-transparent white fill + hairline stroke
//   • Step circles use a solid accent-coloured fill
//   • Buttons use solid accent fill

import ServiceManagement
import SwiftUI

// MARK: - Welcome View

struct WelcomeView: View {
    var onDismiss: () -> Void

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hasFDA: Bool = false
    @State private var buttonPulse = false

    private var allComplete: Bool { hasFDA && launchAtLogin }

    /// Checks whether Full Disk Access has been granted by attempting to read
    /// the TCC database, which is only readable with FDA.
    private static func checkFDA() -> Bool {
        FileManager.default.isReadableFile(
            atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
        )
    }

    /// Starts a gentle repeating pulse on the Get Started button to draw
    /// attention to it once all setup steps are complete.
    private func startPulse() {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            buttonPulse = true
        }
    }

    /// Computed binding so toggling here updates SMAppService immediately,
    /// and the same state is reflected in the General tab without any extra work.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    LogStore.shared.log("Launch at login error: \(error)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    var body: some View {
        ZStack {
            // Greyscale midnight base.
            Color(white: 0.055)
                .ignoresSafeArea()

            // Subtle colour blooms so Liquid Glass (macOS 26) has something
            // to refract. On older OS versions these just add gentle depth.
            GeometryReader { geo in
                // Top-centre: cool blue-grey bloom
                RadialGradient(
                    colors: [Color(red: 0.20, green: 0.35, blue: 0.60).opacity(0.55), .clear],
                    center: .init(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.75
                )
                .ignoresSafeArea()

                // Bottom-leading: warm purple accent
                RadialGradient(
                    colors: [Color(red: 0.35, green: 0.18, blue: 0.50).opacity(0.35), .clear],
                    center: .init(x: 0.05, y: 1.0),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.65
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                headerSection
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                Divider()
                    .overlay(Color.white.opacity(0.10))

                // No ScrollView — all three steps are visible at once.
                stepsSection
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                Divider()
                    .overlay(Color.white.opacity(0.10))

                footerSection
                    .padding(20)
            }
        }
        .frame(width: 460, height: 580)
        .onAppear {
            hasFDA = Self.checkFDA()
            if allComplete { startPulse() }
        }
        // Re-check when the user returns from System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in hasFDA = Self.checkFDA() }
        .onChange(of: allComplete) { _, complete in
            if complete { startPulse() } else { buttonPulse = false }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 56, height: 56)
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text("Welcome to Spotlight Off")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Set up in three steps — takes less than a minute.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStepRow(
                number: 1,
                title: "Allow Full Disk Access",
                description: "Required for silent mdutil control — no password dialog on every mount. Find Spotlight Off in System Settings and toggle it on.",
                actionLabel: hasFDA ? nil : "Open Privacy & Security →",
                actionURL: hasFDA ? nil : "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
                isComplete: hasFDA
            )
            stepDivider
            SetupStepRow(
                number: 2,
                title: "Run at Login",
                description: "Keeps Spotlight Off active in your menu bar so every drive is covered from the moment you log in.",
                actionLabel: nil,
                actionURL: nil,
                toggleBinding: launchAtLoginBinding,
                isComplete: launchAtLogin
            )
            stepDivider
            SetupStepRow(
                number: 3,
                title: "Ready to go",
                description: "Plug in any external drive — Spotlight Off silently disables indexing in the background. No further setup needed.",
                actionLabel: nil,
                actionURL: nil,
                isComplete: hasFDA && launchAtLogin
            )
        }
        .glassCard()
    }

    private var stepDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.06))
            .padding(.horizontal, 14)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 10) {
            getStartedButton
            Link("View on GitHub", destination: URL(string: "https://github.com/BVG-Digital/Spotlight-Off")!)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    @ViewBuilder
    private var getStartedButton: some View {
        let buttonTint = Color(red: 0.20, green: 0.30, blue: 0.50).opacity(0.55)

        if #available(macOS 26, *) {
            Button(action: onDismiss) {
                HStack(spacing: 8) {
                    if allComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(allComplete ? "You're all set" : "Get Started")
                        .font(.system(size: 15, weight: .semibold))
                        .animation(nil, value: allComplete)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .glassEffect(.regular.tint(buttonTint), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .scaleEffect(buttonPulse ? 1.018 : 1.0)
            .animation(.easeInOut(duration: 0.25), value: allComplete)
        } else {
            Button(action: onDismiss) {
                HStack(spacing: 8) {
                    if allComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(allComplete ? "You're all set" : "Get Started")
                        .font(.system(size: 15, weight: .semibold))
                        .animation(nil, value: allComplete)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0.20, green: 0.30, blue: 0.50).opacity(0.45))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                )
                .scaleEffect(buttonPulse ? 1.018 : 1.0)
                .animation(.easeInOut(duration: 0.25), value: allComplete)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Glass Card Modifier

private extension View {
    /// Applies a Liquid Glass card background on macOS 26+, and a dark
    /// frosted-glass-style card on macOS 14–25.
    @ViewBuilder
    func glassCard() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            // .ultraThinMaterial gives a real blur + translucency on macOS 12–25,
            // which reads as frosted glass against the dark background.
            self.background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
        }
    }
}

// MARK: - Setup Step Row

private struct SetupStepRow: View {
    let number: Int
    let title: String
    let description: String
    let actionLabel: String?
    let actionURL: String?
    var actionCallback: (() -> Void)? = nil
    var toggleBinding: Binding<Bool>? = nil
    var isComplete: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            stepNumber
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                // URL action
                if let label = actionLabel,
                   let urlString = actionURL,
                   let url = URL(string: urlString) {
                    Button(label) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
                // Callback action (e.g. open in-app window)
                if let label = actionLabel, actionURL == nil,
                   let callback = actionCallback {
                    Button(label) { callback() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
            }
            Spacer()
            // Inline toggle — sits on the trailing edge, vertically centred with title
            if let binding = toggleBinding {
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var stepNumber: some View {
        if isComplete {
            // Green checkmark replaces the number when the step is done.
            if #available(macOS 26, *) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .glassEffect(.regular.tint(Color.green.opacity(0.7)), in: .circle)
                    .padding(.top, 1)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.85))
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 1)
            }
        } else if #available(macOS 26, *) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .glassEffect(.regular.tint(Color.accentColor), in: .circle)
                .padding(.top, 1)
        } else {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 1)
        }
    }
}
