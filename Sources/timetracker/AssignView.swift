import SwiftUI

enum AssignScope: String, CaseIterable, Identifiable {
    case current = "Current activity"
    case lastHour = "Last 1 hour"
    case thisBlock = "This block"
    case pin = "Pin until I change it"
    var id: String { rawValue }
}

/// Pick a ticket AND choose exactly what time span it applies to, with a plain-language
/// "what this affects" line so it's never ambiguous whether you're tagging now, the past
/// hour, the whole 4h timesheet block, or pinning the next several hours.
struct AssignView: View {
    let tickets: [Ticket]
    let candidates: [String]
    let blockName: String        // "PM"
    let blockRange: String       // "13:00–00:00"
    let blockActive: String      // "2h10"
    let currentlyPinned: String?

    @State var ticket: String
    @State var scope: AssignScope = .thisBlock
    var onApply: (String, AssignScope) -> Void
    var onUnpin: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assign ticket").font(.title2).bold()

            if let p = currentlyPinned {
                HStack {
                    Label("Pinned to \(p)", systemImage: "pin.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Unpin", action: onUnpin)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                TextField("Ticket (e.g. CLOUDINFRA-1234)", text: $ticket)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Menu("Pick") {
                    if !candidates.isEmpty {
                        Section("Best guesses") {
                            ForEach(candidates, id: \.self) { k in Button(label(k)) { ticket = k } }
                        }
                    }
                    if tickets.contains(where: { $0.common }) {
                        Section("Common") {
                            ForEach(tickets.filter { $0.common }, id: \.key) { t in Button("\(t.key) — \(t.summary.prefix(40))") { ticket = t.key } }
                        }
                    }
                    Section("Assigned to me") {
                        ForEach(tickets.filter { !$0.common }, id: \.key) { t in Button("\(t.key) — \(t.summary.prefix(40))") { ticket = t.key } }
                    }
                }
                .frame(width: 70)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Apply to").font(.subheadline).bold().foregroundStyle(.secondary)
                ForEach(AssignScope.allCases) { s in
                    Button { scope = s } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: scope == s ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(scope == s ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.rawValue)
                                Text(affects(s)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply") { onApply(ticket.trimmingCharacters(in: .whitespaces).uppercased(), scope) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticket.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func affects(_ s: AssignScope) -> String {
        switch s {
        case .current: return "Tags the current focus only, until you switch apps/context."
        case .lastHour: return "Re-tags the last 60 minutes of activity."
        case .thisBlock: return "Sets the timesheet row for \(blockName) (\(blockRange), ~\(blockActive) active) and re-tags it."
        case .pin: return "Tags everything from now until you Unpin — covers the next hours."
        }
    }

    private func label(_ key: String) -> String {
        if let t = tickets.first(where: { $0.key == key }) { return "\(key) — \(t.summary.prefix(36))" }
        return key
    }
}
