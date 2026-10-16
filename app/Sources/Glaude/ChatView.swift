import SwiftUI

/// The expanded panel: session switcher, conversation, pending prompt card, reply box.
struct ChatView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var panelSize: PanelSizeModel
    let onClose: () -> Void
    let onOpenTerminal: (Session) -> Void
    let onToggleSize: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let session = store.selected {
                MessageList(session: session)
                if let pending = session.pending {
                    PendingCard(request: pending, store: store, openTerminal: { onOpenTerminal(session) }).id(pending.id)
                }
                InputBar(store: store, session: session)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BlurBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.sessions) { s in
                        SessionChip(session: s, selected: s.id == store.selected?.id) { store.select(s.id) }
                    }
                }
            }
            if let session = store.selected {
                iconButton("terminal", help: "Show this session's terminal") { onOpenTerminal(session) }
            }
            iconButton(panelSize.isLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: panelSize.isLarge ? "Make smaller" : "Make larger") { onToggleSize() }
            iconButton("xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sparkle").font(.system(size: 26)).foregroundStyle(Color.glaudeAccent)
            Text("No Claude sessions yet").font(.system(size: 13, weight: .semibold))
            Text("Install the plugin, then start `claude` in a terminal:\n`/plugin install glaude --marketplace vaseemcholakkan123/Glaude`")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct SessionChip: View {
    let session: Session
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(session.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        if session.pending != nil { return .glaudeAccent }
        switch session.state {
        case .idle: return .secondary.opacity(0.5)
        case .working: return .blue
        case .needsYou: return .glaudeAccent
        case .done: return .glaudeDone
        }
    }
}

// MARK: Messages

private struct MessageList: View {
    let session: Session

    /// Consecutive tool calls collapse into one compact block.
    private enum Row: Identifiable {
        case item(ChatItem)
        case tools([ChatItem])
        var id: UUID {
            switch self {
            case .item(let item): return item.id
            case .tools(let items): return items[0].id
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        for item in session.items {
            if case .tool = item.kind {
                if case .tools(let run)? = rows.last {
                    rows[rows.count - 1] = .tools(run + [item])
                } else {
                    rows.append(.tools([item]))
                }
            } else {
                rows.append(.item(item))
            }
        }
        return rows
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.items.isEmpty {
                        Text("Waiting for activity in \(session.name)…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .item(let item): MessageRow(item: item).id(row.id)
                        case .tools(let items): ToolRun(items: items).id(row.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.id) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct MessageRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text.count > 600 ? String(text.prefix(600)) + "…" : text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.glaudeAccent.opacity(0.22)))
            }
        case .assistant(let text):
            Text(markdown(text.count > 2500 ? String(text.prefix(2500)) + "…" : text))
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
                .padding(.trailing, 24)
        case .note(let text):
            Label(text, systemImage: "bell")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .summary(let files, let commands):
            SummaryCard(files: files, commands: commands)
        case .tool:
            EmptyView()
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ToolRun: View {
    let items: [ChatItem]
    // Explicit State/FocusState values instead of the @State/@FocusState macros, which
    // newer SDKs implement in a compiler plugin that the Command Line Tools don't ship.
    private let expandedState = State<Bool>(initialValue: false)
    private var expanded: Bool {
        get { expandedState.wrappedValue }
        nonmutating set { expandedState.wrappedValue = newValue }
    }

    var body: some View {
        let visible = expanded ? items : Array(items.suffix(4))
        VStack(alignment: .leading, spacing: 3) {
            if items.count > visible.count {
                Button("+\(items.count - visible.count) earlier steps") { expanded = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(visible) { item in
                if case .tool(let symbol, let text) = item.kind {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 9.5)).frame(width: 12)
                        Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 4)
    }
}

private struct SummaryCard: View {
    let files: [String]
    let commands: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(headline, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.glaudeDone)
            ForEach(files.prefix(6), id: \.self) { file in
                Text(file).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if files.count > 6 {
                Text("+\(files.count - 6) more").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.glaudeDone.opacity(0.1)))
    }

    private var headline: String {
        var parts = ["Done"]
        if !files.isEmpty { parts.append("\(files.count) file\(files.count == 1 ? "" : "s") changed") }
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Pending prompt

private struct PendingCard: View {
    let request: PendingRequest
    @ObservedObject var store: SessionStore
    let openTerminal: () -> Void
    // See the note on ChatView's first State value: no @State macro.
    private let picksState = State<[String: Set<String>]>(initialValue: [:])
    private var picks: [String: Set<String>] {
        get { picksState.wrappedValue }
        nonmutating set { picksState.wrappedValue = newValue }
    }
    private let otherState = State<[String: String]>(initialValue: [:])
    private var other: [String: String] {
        get { otherState.wrappedValue }
        nonmutating set { otherState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.kind {
            case .permission(let tool, let detail):
                Label("Allow \(tool)?", systemImage: "hand.raised.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.glaudeAccent)
                if !detail.isEmpty {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                }
                HStack {
                    terminalButton
                    Spacer()
                    Button("Deny") { store.answerPermission(request, allow: false) }
                    Button("Allow") { store.answerPermission(request, allow: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.glaudeAccent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)

            case .questions(let questions):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(questions) { question in questionView(question) }
                    }
                }
                .frame(maxHeight: 220)
                HStack {
                    terminalButton
                    Spacer()
                    Button("Send") { store.answerQuestions(request, answers: answers(questions)) }
                        .buttonStyle(.borderedProminent)
                        .tint(.glaudeAccent)
                        .disabled(answers(questions).count < questions.count)
                }
                .controlSize(.small)

            case .terminal(let title, let detail):
                Label(title, systemImage: "hand.raised.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.glaudeAccent)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("Waiting for you in the terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open terminal", action: openTerminal)
                        .buttonStyle(.borderedProminent)
                        .tint(.glaudeAccent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.glaudeAccent.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.glaudeAccent.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var terminalButton: some View {
        Button("Answer in terminal") { store.answerInTerminal(request) }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func questionView(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !question.header.isEmpty {
                Text(question.header.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(question.text).font(.system(size: 12, weight: .semibold))
            ForEach(question.options, id: \.self) { option in
                let chosen = picks[question.text, default: []].contains(option.label)
                Button { toggle(option.label, in: question) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: chosen ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                 : (question.multiSelect ? "square" : "circle"))
                            .foregroundStyle(chosen ? Color.glaudeAccent : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).font(.system(size: 11.5))
                            if !option.description.isEmpty {
                                Text(option.description).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            TextField("Other…", text: Binding(
                get: { other[question.text, default: ""] },
                set: { other[question.text] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5))
        }
    }

    private func toggle(_ label: String, in question: Question) {
        var set = picks[question.text, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        picks[question.text] = set
    }

    /// Question text → answer. "Other" text wins; multi-select answers are comma-joined.
    private func answers(_ questions: [Question]) -> [String: String] {
        var result: [String: String] = [:]
        for question in questions {
            let typed = other[question.text, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = question.options.map(\.label).filter { picks[question.text, default: []].contains($0) }
            if !typed.isEmpty {
                result[question.text] = typed
            } else if !chosen.isEmpty {
                result[question.text] = chosen.joined(separator: ", ")
            }
        }
        return result
    }
}

// MARK: Input

private struct InputBar: View {
    @ObservedObject var store: SessionStore
    let session: Session
    // See the note on ChatView's first State value: no @State macro.
    private let draftState = State<String>(initialValue: "")
    private var draft: String {
        get { draftState.wrappedValue }
        nonmutating set { draftState.wrappedValue = newValue }
    }
    private let focusedState = FocusState<Bool>()
    private var focused: Bool {
        get { focusedState.wrappedValue }
        nonmutating set { focusedState.wrappedValue = newValue }
    }

    var body: some View {
        if store.canReply(session) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Claude…", text: draftState.projectedValue, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...8)
                    .focused(focusedState.projectedValue)
                    .onSubmit(send)
                    // Return sends; Shift+Return adds a line (at the end of the draft).
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        draft += "\n"
                        return .handled
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? Color.secondary : Color.glaudeAccent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.04))
            .onAppear { focused = true }
        } else {
            Text("Install the glaude plugin to reply from here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.04))
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text, to: session.id)
        draft = ""
    }
}
