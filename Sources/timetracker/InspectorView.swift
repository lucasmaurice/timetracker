import SwiftUI

/// A snapshot of every layer's raw output for the current moment.
struct InspectorData {
    var hasState = false
    var contextDoc = ""
    var signatures: [String] = []
    var finalTicket: String?
    var finalSource: String?
    var finalConfidence: Double?
    var pinned: String?
    var category: String?
    var lexical: [TicketGuess] = []
    var memory: [(ticket: String, score: Double, doc: String)] = []
    var embedding: [TicketGuess] = []
    var ranking: [(key: String, factors: [(label: String, factor: Double)], total: Double)] = []
    var llmKey: String?
    var llmReason: String?
    var llmConfidence: Double?
    var llmAge: String?
    var llmPrompt = ""
}

/// "Microscope": shows the context/tags and what each layer (lexical / memory / embeddings /
/// LLM) produced for the current activity, plus the exact prompt the LLM receives and the
/// final decision. Read-only; Refresh recomputes from the live state.
struct InspectorView: View {
    let data: InspectorData
    var onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("System inspector").font(.title2).bold()
                    Spacer()
                    Button("Refresh", action: onRefresh)
                }

                if !data.hasState {
                    Text("No current activity (idle or paused).").foregroundStyle(.secondary)
                } else {
                    decision
                    section("Context / tags attached to current work",
                            "Everything the system gathered for this moment — app, URL, AI-session meaning, repo/branch, files, processes, meeting. This is what every layer matches against.") {
                        mono(data.contextDoc)
                        if !data.signatures.isEmpty {
                            Text("signatures: " + data.signatures.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 20) {
                        section("① Lexical (token overlap)",
                                "IDF-weighted shared jargon. Abstains (empty) when nothing overlaps.") { guesses(data.lexical) }
                        section("③ Embeddings (nomic)",
                                "Semantic similarity for synonyms. Weak discriminator — feeds the LLM shortlist.") { guesses(data.embedding) }
                    }
                    section("② Memory (your labeled examples)",
                            "k-NN over tickets you've taught. High score = you've labeled very similar work before.") {
                        if data.memory.isEmpty { dim("no labels matched") }
                        else {
                            ForEach(Array(data.memory.enumerated()), id: \.offset) { _, m in
                                HStack(alignment: .top) {
                                    Text(String(format: "%.2f", m.score)).font(.system(.caption, design: .monospaced)).frame(width: 40, alignment: .leading)
                                    Text(m.ticket).bold().frame(width: 130, alignment: .leading)
                                    Text(m.doc.prefix(70)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    section("Ranking weights applied",
                            "Each match score is multiplied by these factors (Settings → Ranking weights). Shows why a ticket ranks up/down.") {
                        if data.ranking.isEmpty { dim("no ranked candidates") }
                        else {
                            ForEach(Array(data.ranking.enumerated()), id: \.offset) { _, r in
                                let f = r.factors.map { "\($0.label) ×\(String(format: "%.2f", $0.factor))" }.joined(separator: " · ")
                                HStack(alignment: .top) {
                                    Text(r.key).bold().frame(width: 130, alignment: .leading)
                                    Text(f.isEmpty ? "neutral" : f).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("= ×\(String(format: "%.2f", r.total))").font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                    section("④ LLM (\(data.llmKey == nil ? "no result yet" : "qwen3"))",
                            "The local model picks from the shortlist using the full prompt below. Runs periodically / at prompt-time, not on every refresh.") { llmBlock }
                    DisclosureGroup("What the LLM sees (exact prompt)") { mono(data.llmPrompt) }
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 760)
    }

    private var decision: some View {
        let conf = data.finalConfidence.map { String(format: " · %.2f", $0) } ?? ""
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FINAL").font(.caption).foregroundStyle(.secondary)
                Text(data.finalTicket ?? "—").font(.system(size: 22, weight: .bold))
                    .foregroundStyle(data.finalTicket == nil ? Color.secondary : Color.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("via \(data.finalSource ?? "none")\(conf)").font(.callout)
                if let cat = data.category { Text("category: \(cat)").font(.caption).foregroundStyle(.secondary) }
                if let p = data.pinned { Label("pinned to \(p)", systemImage: "pin.fill").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var llmBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let k = data.llmKey {
                HStack {
                    Text(k).bold()
                    if let c = data.llmConfidence { Text(String(format: "%.2f", c)).foregroundStyle(.purple) }
                    if let a = data.llmAge { Text("· \(a) ago").font(.caption).foregroundStyle(.secondary) }
                }
                if let r = data.llmReason { Text(r).font(.callout).foregroundStyle(.secondary) }
            } else {
                dim("LLM hasn't produced a guess yet (runs periodically / at prompt-time).")
            }
        }
    }

    private func guesses(_ g: [TicketGuess]) -> some View {
        Group {
            if g.isEmpty { dim("none (abstained)") }
            else {
                ForEach(Array(g.enumerated()), id: \.offset) { _, x in
                    HStack {
                        Text(String(format: "%.3f", x.score)).font(.system(.caption, design: .monospaced)).frame(width: 52, alignment: .leading)
                        Text(x.key).font(.callout)
                        Spacer()
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, _ desc: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold().foregroundStyle(.secondary)
            if !desc.isEmpty { Text(desc).font(.caption2).foregroundStyle(.secondary) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mono(_ s: String) -> some View {
        Text(s.isEmpty ? "—" : s)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func dim(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }
}
