import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {

    static let shared = AboutWindowController()

    private init() {
        let rootView = AboutView()
        let vc = NSHostingController(rootView: rootView)
        vc.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: vc)
        window.title = "About Me Or Them"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Particle model

private struct Particle: Identifiable {
    let id: Int
    let birthDate: Date
    let lifetime: Double
    let startX: Double
    let startY: Double
    let vx: Double
    let vy: Double
    let color: Color
}

// MARK: - FireworksState

@MainActor private final class FireworksState: ObservableObject {
    @Published private(set) var particles: [Particle] = []
    private var emitTimer: Timer?
    private var nextID = 0
    static let gravity = 220.0
    private static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .cyan]

    func start(windowSize: CGSize) {
        emitBurst(windowSize: windowSize)
        emitTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.emitBurst(windowSize: windowSize)
                self.pruneExpired()
            }
        }
    }

    func stop() {
        emitTimer?.invalidate()
        emitTimer = nil
        particles = []
    }

    func emitBurst(windowSize: CGSize) {
        let originX = windowSize.width / 2
        let originY = 80.0
        let newParticles = (0..<7).map { _ -> Particle in
            let angle = Double.random(in: (-Double.pi * 0.9)...(-Double.pi * 0.1))
            let speed = Double.random(in: 120...380)
            let lifetime = Double.random(in: 2.5...4.5)
            let colorIndex = Int.random(in: 0..<Self.colors.count)
            let p = Particle(
                id: nextID,
                birthDate: Date(),
                lifetime: lifetime,
                startX: originX,
                startY: originY,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed,
                color: Self.colors[colorIndex]
            )
            nextID += 1
            return p
        }
        particles.append(contentsOf: newParticles)
    }

    func pruneExpired() {
        let now = Date()
        particles.removeAll { now.timeIntervalSince($0.birthDate) >= $0.lifetime }
    }
}

// MARK: - About view

private struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    private static let authorImage: NSImage? = {
        Bundle.module.url(forResource: "author", withExtension: "jpg")
            .flatMap { NSImage(contentsOf: $0) }
    }()

    @StateObject private var fireworks = FireworksState()
    @State private var showAuthor = false

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                ZStack {
                    iconImage
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                        .onTapGesture(count: 2) { triggerEasterEgg() }
                }
                .frame(width: 96, height: 96)

                Text("Me Or Them")
                    .font(.system(size: 24, weight: .bold))

                Text("Version \(version)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Network Quality Monitor")
                    .font(.body)
                    .foregroundColor(.secondary)

                Divider()
                    .padding(.vertical, 4)

                Text("Developed by Christian \u{201C}Kanzie\u{201D} Nilsson")
                    .font(.body)

                Text("kanzie@kanzie.com")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer().frame(height: 4)

                Text("Distributed under the MIT License")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Copyright \u{00A9} 2026 Christian Nilsson")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(32)

            if !fireworks.particles.isEmpty {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        let now = timeline.date
                        for p in fireworks.particles {
                            let t = now.timeIntervalSince(p.birthDate)
                            guard t >= 0, t < p.lifetime else { continue }
                            let x = p.startX + p.vx * t
                            let y = p.startY + p.vy * t + 0.5 * FireworksState.gravity * t * t
                            let alpha = max(0.0, 1.0 - t / p.lifetime)
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)),
                                with: .color(p.color.opacity(alpha))
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 340)
        .onDisappear { fireworks.stop() }
    }

    private var iconImage: Image {
        if showAuthor, let img = Self.authorImage {
            return Image(nsImage: img)
        }
        return Image(nsImage: NSApp.applicationIconImage ?? NSImage())
    }

    private func triggerEasterEgg() {
        showAuthor = true
        fireworks.stop()
        fireworks.start(windowSize: CGSize(width: 340, height: 360))
    }
}
