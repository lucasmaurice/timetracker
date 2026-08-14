import SwiftUI

struct TeachRow: Identifiable {
    let id = UUID()
    let timeText: String
    let summary: String
    let doc: String
    let guessed: String
    var ticket: String
    var saved = false
}

final class TeachModel: ObservableObject {
    @Published var count: Int
    @Published var currentSummary: String
    @Published var currentTicket: String
    @Published var currentSaved = false
    @Published var rows: [TeachRow]
    let hasCurrent: Bool
    let tickets: [Ticket]

    init(count: Int, currentSummary: String, currentTicket: String, hasCurrent: Bool,
         rows: [TeachRow], tickets: [Ticket]) {
        self.count = count
        self.currentSummary = currentSummary
        self.currentTicket = currentTicket
        self.hasCurrent = hasCurrent
        self.rows = rows
        self.tickets = tickets
    }
}

/// "Teach the guesser": confirm/correct the ticket for the current activity and recent
/// segments. Each save writes a labeled example (stored in SQLite) that the content memory,
/// signature bias, and LLM few-shot all learn from. Great for an initial training period.
struct TeachView: View {
    @ObservedObject var model: TeachModel
    var onSaveCurrent: (String) -> Void
    var onSaveRow: (Int, String) -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Teach the guesser").font(.title2).bold()
                Spacer()
                Text("\(model.count) examples saved").foregroundStyle(.secondary)
                Button("Refresh", action: onRefresh)
            }
            Text("Each save is a labeled example stored locally. The more you label, the better the guesses — no model retraining, it learns from your examples.")
                .font(.caption).foregroundStyle(.secondary)

            if model.hasCurrent {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Right now").font(.subheadline).bold().foregroundStyle(.secondary)
                    Text(model.currentSummary).font(.callout).lineLimit(2)
                    HStack {
                        ticketField($model.currentTicket)
                        Button(model.currentSaved ? "Saved ✓" : "Save example") {
                            onSaveCurrent(model.currentTicket.trimmingCharacters(in: .whitespaces).uppercased())
                            model.currentSaved = true
                        }
                        .disabled(model.currentTicket.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("Recent activity — label to backfill").font(.subheadline).bold().foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { idx, row in
                        HStack(spacing: 8) {
                            Text(row.timeText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Text(row.summary).font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            ticketField($model.rows[idx].ticket).frame(width: 180)
                            Button(row.saved ? "✓" : "Save") {
                                onSaveRow(idx, model.rows[idx].ticket.trimmingCharacters(in: .whitespaces).uppercased())
                                model.rows[idx].saved = true
                            }
                            .disabled(model.rows[idx].ticket.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 560)
    }

    private func ticketField(_ binding: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField("ticket", text: binding).textFieldStyle(.roundedBorder)
            Menu("▾") {
                if model.tickets.contains(where: { $0.common }) {
                    Section("Common") {
                        ForEach(model.tickets.filter { $0.common }, id: \.key) { t in
                            Button("\(t.key) — \(t.summary.prefix(36))") { binding.wrappedValue = t.key }
                        }
                    }
                }
                Section("Assigned") {
                    ForEach(model.tickets.filter { !$0.common }, id: \.key) { t in
                        Button("\(t.key) — \(t.summary.prefix(36))") { binding.wrappedValue = t.key }
                    }
                }
            }
            .frame(width: 28)
        }
    }
}
