import AppKit
import SwiftUI

/// Shared look for the main window and the menu-bar popover, so both read as one app.
/// Teal is the brand accent; status colours stay semantic (green = good, orange = needs
/// you, red = down) so they still mean something to someone scanning at a glance.
enum Theme {
    static let accent = Color.teal
    /// For FILLED controls with white text. System teal under white text is ~2.6:1, below
    /// the 4.5:1 minimum; this deeper teal clears it in both appearances.
    static let accentStrong = Color(red: 0.0, green: 0.46, blue: 0.50)
    static let ok = Color.green
    static let attention = Color.orange
    static let down = Color.red

    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
}

/// A grouped surface with an optional small-caps title, like a System Settings section.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            }
            content
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }
}

/// Status dot that breathes while live. A still dot can't tell "running" from a frozen
/// UI; the pulse is the cheapest honest liveness signal there is.
struct LiveDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            if pulsing {
                PulseRing(color: NSColor(color).withAlphaComponent(0.35), diameter: size * 2.4)
                    .frame(width: size * 2.4, height: size * 2.4)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.6), radius: pulsing ? 3 : 0)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .accessibilityHidden(true)
    }
}

/// The expanding ring behind `LiveDot`, as a Core Animation layer animation.
///
/// 3.0 drove it with a SwiftUI `repeatForever` animation. That re-ran SwiftUI's display-list
/// update for the whole window on every frame, rebuilding the shadow filters of every view in
/// it, and kept doing so while the popover and window were closed: the idle menu-bar app sat
/// at ~30% of a core for days (measured 15/10/2026, `sample`: main thread in
/// `DisplayList.ViewUpdater.update` + `GraphicsFilter.makeCAFilter`). A `CABasicAnimation`
/// runs in the render server: the app does no work per frame, and nothing renders while the
/// window is off screen. Reduce Motion gets the still ring.
struct PulseRing: NSViewRepresentable {
    var color: NSColor
    var diameter: CGFloat

    func makeNSView(context: Context) -> PulseRingView {
        let view = PulseRingView()
        view.configure(color: color, diameter: diameter)
        return view
    }

    func updateNSView(_ view: PulseRingView, context: Context) {
        view.configure(color: color, diameter: diameter)
    }
}

final class PulseRingView: NSView {
    private let ring = CAShapeLayer()
    private var configuredDiameter: CGFloat?
    static let animationKey = "agentcontroller.pulse"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Called on every SwiftUI update (every tool call bumps a counter in the same view), so it
    /// only touches what changed and never restarts a pulse that is already running.
    func configure(color: NSColor, diameter: CGFloat) {
        ring.fillColor = color.cgColor
        guard configuredDiameter != diameter else { return }
        configuredDiameter = diameter
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        needsLayout = true
        if ring.animation(forKey: Self.animationKey) == nil { restartAnimation() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartAnimation()
    }

    private func restartAnimation() {
        ring.removeAnimation(forKey: Self.animationKey)
        guard window != nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            ring.opacity = 0.5
            return
        }
        ring.opacity = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: Self.animationKey)
    }
}

/// Small metric: big monospaced value over a quiet label.
struct StatTile: View {
    let value: String
    let label: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

/// "Granted" / "Off" style capsule.
struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Copy-to-clipboard button that confirms with a checkmark for a moment.
struct CopyButton: View {
    let text: String
    var label: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Copy to clipboard")
    }
}

enum Formatters {
    /// "4s", "12m", "3h 05m", "2d 4h" — compact, monotone width.
    static func uptime(since start: Date?, now: Date) -> String {
        guard let start else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
        default: return "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        default: return "\(seconds / 3600)h ago"
        }
    }
}
