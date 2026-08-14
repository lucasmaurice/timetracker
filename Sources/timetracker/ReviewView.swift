import Charts
import SwiftUI

/// A ranked alternative for a block (key + description + fused score).
struct ReviewAlt: Identifiable {
    let key: String; let summary: String; let score: Double
    var id: String { key }
}

/// One editable timesheet block in the review screen.
struct ReviewBlock: Identifiable {
    let block: String          // block id ("1"..."N")
    let rangeText: String
    let activeSeconds: Double
    let idleSeconds: Double
    let slices: [Slice]        // time by ticket (proportion bar)
    let recap: String          // what you did (repo · files · session · app)
    let guessKey: String?      // the system's best guess for the block
    let guessSummary: String?  // its description
    let guessWhy: String?      // why it was picked (source · confidence)
    let alternatives: [ReviewAlt]
    let originalGuess: String   // for change detection ("" if none)
    var ticket: String          // editable final ticket
    var note: String            // editable
    var confirmed: Bool = false // explicit ✓ (teaches the model even if unchanged)
    var id: String { block }
}

final class ReviewModel: ObservableObject {
    @Published var dayText: String
    @Published var blocks: [ReviewBlock]
    let tickets: [Ticket]
    let noTicketLabel: String

    init(dayText: String, blocks: [ReviewBlock], tickets: [Ticket], noTicketLabel: String) {
        self.dayText = dayText
        self.blocks = blocks
        self.tickets = tickets
        self.noTicketLabel = noTicketLabel
    }

    /// Resolve a ticket key to its description (for inline display).
    func summary(for key: String) -> String? {
        tickets.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.summary
    }
}

/// Review screen: per-block cards that show what you did, the system's best guess *and why*,
/// ranked alternatives with descriptions, a searchable picker, and explicit confirm / no-ticket —
/// so confirming or correcting both fills the timesheet and teaches the guesser.
struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    var onSave: () -> Void
    var onShift: (Int) -> Void
    var onSubmitTempo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header.padding([.horizontal, .top], 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($model.blocks) { $block in
                        BlockCard(block: $block, model: model)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Submit to Tempo…", action: onSubmitTempo).controlSize(.large)
                Spacer()
                Text("Corrections & ✓ confirms teach the guesser").font(.caption).foregroundStyle(.secondary)
                Button("Save & export", action: onSave).keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 640, minHeight: 580)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Review").font(.title2).bold()
            Spacer()
            Button { onShift(-1) } label: { Image(systemName: "chevron.left") }
            Text(model.dayText).font(.system(.body, design: .monospaced)).frame(width: 96)
            Button { onShift(1) } label: { Image(systemName: "chevron.right") }
        }
    }
}

private struct BlockCard: View {
    @Binding var block: ReviewBlock
    @ObservedObject var model: ReviewModel

    private var isNoTicket: Bool { block.ticket.caseInsensitiveCompare(model.noTicketLabel) == .orderedSame }
    private var isEdited: Bool {
        !block.ticket.isEmpty && block.ticket.caseInsensitiveCompare(block.originalGuess) != .orderedSame
    }
    private var tint: Color {
        if block.confirmed { return .green }
        if isEdited { return .orange }
        return .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(block.rangeText).font(.system(.title3, design: .monospaced)).bold()
                Spacer()
                Text("active \(Summary.hm(block.activeSeconds)) · idle \(Summary.hm(block.idleSeconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if block.slices.isEmpty {
                Text("No activity in this block.").font(.caption).foregroundStyle(.secondary)
            } else {
                if !block.recap.isEmpty {
                    Label(block.recap, systemImage: "doc.text.magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Chart(block.slices) { s in
                    BarMark(x: .value("Hours", s.hours), y: .value("row", ""))
                        .foregroundStyle(by: .value("Ticket", s.label))
                }
                .chartLegend(.hidden).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 16)
                Text(block.slices.prefix(5).map { "\($0.label) \(Summary.hm($0.seconds))" }.joined(separator: "  ·  "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }

            // Best guess + why + one-click confirm + alternatives.
            if let g = block.guessKey {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(g)\(block.guessSummary.map { " — \($0.prefix(48))" } ?? "")").font(.callout).lineLimit(1)
                        if let why = block.guessWhy { Text(why).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { block.ticket = g; block.confirmed = true } label: {
                        Label("Confirm", systemImage: "checkmark.circle.fill")
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    if !block.alternatives.isEmpty {
                        Menu("Alternatives") {
                            ForEach(block.alternatives) { a in
                                Button(String(format: "%@ (%.2f) — %@", a.key, a.score, String(a.summary.prefix(40)))) {
                                    block.ticket = a.key; block.confirmed = false
                                }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                .padding(8)
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            // Final ticket + inline description + searchable picker + no-ticket.
            HStack(spacing: 8) {
                Image(systemName: block.confirmed ? "checkmark.circle.fill" : (isEdited ? "pencil.circle" : "circle"))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("Ticket (e.g. CLOUDINFRA-1234)", text: $block.ticket).textFieldStyle(.roundedBorder)
                    if !isNoTicket, let s = model.summary(for: block.ticket) {
                        Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: 280)
                TicketPicker(tickets: model.tickets) { block.ticket = $0 }
                Button("No ticket") { block.ticket = model.noTicketLabel; block.confirmed = true }
                    .controlSize(.small)
            }

            TextField("note (optional summary override)", text: $block.note).textFieldStyle(.roundedBorder)
        }
        .padding(14)
        .background(tint.opacity(block.confirmed || isEdited ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(block.confirmed ? 0.4 : 0.15), lineWidth: 1))
    }
}

/// Searchable ticket picker in a popover — filters key + description as you type.
private struct TicketPicker: View {
    let tickets: [Ticket]
    let onPick: (String) -> Void
    @State private var show = false
    @State private var query = ""

    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "magnifyingglass") }
            .controlSize(.small)
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search tickets…", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(filtered, id: \.key) { t in
                                Button { onPick(t.key); show = false; query = "" } label: {
                                    HStack(spacing: 8) {
                                        Text(t.key).font(.system(.caption, design: .monospaced)).bold().frame(width: 130, alignment: .leading)
                                        Text(t.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(10).frame(width: 380, height: 300)
            }
    }

    private var filtered: [Ticket] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(tickets.prefix(80)) }
        return tickets.filter { $0.key.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
            .prefix(80).map { $0 }
    }
}
