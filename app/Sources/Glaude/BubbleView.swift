import SwiftUI

extension Color {
    static let glaudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)  // warm clay
    static let glaudeDone = Color(red: 0.30, green: 0.72, blue: 0.45)
    static let diffAdded = Color(red: 0.25, green: 0.70, blue: 0.40)
    static let diffRemoved = Color(red: 0.90, green: 0.33, blue: 0.30)
}

/// Whether the bubble is out or tucked into the screen edge as a slim tab, for the
/// "only when Claude needs you" setting.
final class BubbleDock: ObservableObject {
    @Published var collapsed = false
    /// A brief green glow on the tab when a session finishes while collapsed.
    @Published var glow = false
    @Published var onLeftEdge = false

    static let tabSize = NSSize(width: 14, height: 56)
    static let bubbleSize = NSSize(width: 64, height: 64)
}

/// The floating 48pt button: idle (faded), working (spinning ring),
/// needs you (orange, pulsing), done (green check until you look).
struct BubbleView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var dock: BubbleDock
    let onHover: (Bool) -> Void
    // Explicit State/FocusState values instead of the @State/@FocusState macros, which
    // newer SDKs implement in a compiler plugin that the Command Line Tools don't ship.
    private let hoveringState = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { hoveringState.wrappedValue }
        nonmutating set { hoveringState.wrappedValue = newValue }
    }

    var body: some View {
        if dock.collapsed {
            EdgeTab(state: store.aggregateState, glow: dock.glow, onLeftEdge: dock.onLeftEdge)
                .contentShape(Rectangle())
                .onHover { onHover($0) }
                .help(helpText(store.aggregateState))
        } else {
            bubble
        }
    }

    private var bubble: some View {
        let state = store.aggregateState
        let animating = state == .working || state == .needsYou
        return TimelineView(.animation(paused: !animating)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topTrailing) {
                face(state, t: t)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .padding(8)
                if !store.sessions.isEmpty {
                    Text("\(store.sessions.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Circle().fill(state == .needsYou ? Color.glaudeAccent : Color.black.opacity(0.75)))
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        .padding(4)
                }
            }
        }
        .frame(width: 64, height: 64)
        .opacity(state == .idle && !hovering ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: state)
        .contentShape(Rectangle())
        .onHover { hovering = $0; onHover($0) }
        .help(helpText(state))
    }

    @ViewBuilder
    private func face(_ state: SessionState, t: TimeInterval) -> some View {
        ZStack {
            Circle().fill(state == .needsYou ? Color.glaudeAccent : Color(nsColor: .windowBackgroundColor))
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)

            switch state {
            case .idle:
                icon("sparkle", color: .secondary)
            case .working:
                Circle()
                    .trim(from: 0, to: 0.68)
                    .stroke(
                        AngularGradient(colors: [.glaudeAccent.opacity(0), .glaudeAccent], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .padding(3)
                    .rotationEffect(.radians(t * 4.5))
                icon("sparkle", color: .glaudeAccent)
                    .scaleEffect(1 + 0.08 * sin(t * 3))
            case .needsYou:
                Circle()
                    .stroke(Color.glaudeAccent.opacity(0.6 * (1 - ripple(t))), lineWidth: 2)
                    .scaleEffect(1 + 0.45 * ripple(t))
                icon("hand.raised.fill", color: .white)
            case .done:
                Circle().stroke(Color.glaudeDone, lineWidth: 3).padding(2)
                icon("checkmark", color: .glaudeDone)
            }
        }
        .scaleEffect(state == .needsYou ? 1 + 0.05 * sin(t * 6) : 1)
    }

    private func icon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(color)
    }

    private func ripple(_ t: TimeInterval) -> Double {
        (t * 0.9).truncatingRemainder(dividingBy: 1)
    }

    private func helpText(_ state: SessionState) -> String {
        switch state {
        case .idle: return store.sessions.isEmpty ? "Glaude: no Claude sessions" : "Glaude: idle"
        case .working: return "Claude is working"
        case .needsYou: return "Claude needs you"
        case .done: return "Claude finished"
        }
    }
}

/// The collapsed bubble: a slim pill in the screen edge, glowing green when a session
/// finishes and breathing while Claude works. Hover or click to bring the bubble out.
private struct EdgeTab: View {
    let state: SessionState
    let glow: Bool
    let onLeftEdge: Bool

    var body: some View {
        TimelineView(.animation(paused: state != .working || glow)) { timeline in
            let breath = 0.55 + 0.25 * sin(timeline.date.timeIntervalSinceReferenceDate * 2.5)
            Capsule()
                .fill(glow ? Color.glaudeDone : state == .working ? Color.glaudeAccent.opacity(breath) : Color.secondary.opacity(0.45))
                .frame(width: 5, height: 40)
                .shadow(color: glow ? Color.glaudeDone.opacity(0.9) : .clear, radius: glow ? 7 : 0)
                .animation(.easeInOut(duration: 0.3), value: glow)
        }
        .frame(width: BubbleDock.tabSize.width, height: BubbleDock.tabSize.height,
               alignment: onLeftEdge ? .leading : .trailing)
        .padding(onLeftEdge ? .leading : .trailing, 1)
    }
}

/// The small card that pops out next to the bubble when a session finishes or needs you.
struct PeekView: View {
    let title: String
    let detail: String
    let footer: String
    let tint: Color
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if !footer.isEmpty {
                    Text(footer).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 256, alignment: .leading)
            .padding(12)
            .background(BlurBackground())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
    }
}

struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
