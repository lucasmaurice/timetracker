import Charts
import SwiftUI

struct DashboardView: View {
    let data: DashboardData
    var onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Text("Active = tracked non-idle time. Attributed = has a ticket. Exact = from a hard signal (branch/URL/key/session), not a guess.")
                    .font(.caption2).foregroundStyle(.secondary)

                section("Expected timesheet (today)",
                        "What would be written to timesheet-log.md right now: the dominant ticket per block. No export needed.") { expectedBlocks }
                section("Today's timeline",
                        "Each focus segment as a colored bar by ticket — your day at a glance.") { timeline }

                HStack(alignment: .top, spacing: 24) {
                    section("Time by ticket", "Share of today's active time per ticket.") { donut(data.todayByTicket) }
                    section("Time by category", "Coding / infra / meeting / etc.") { donut(data.todayByCategory) }
                }

                Divider()
                Text("Is the guesser doing a good job?").font(.headline)
                Text("High exact + high coverage = trustworthy. Lots of 'none' = it can't tell (teach it / add aliases). Lots of low-confidence guesses = tune thresholds.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    section("Attribution source",
                            "exact = hard signal · guess = lexical/embedding/LLM · none = unattributed.") { donut(data.sourceMix) }
                    section("Guess confidence",
                            "Distribution of confidence for LLM-guessed segments (counts per 0.1 bucket).") { confidenceChart }
                }

                Divider()
                section("Last 10 days — hours by ticket",
                        "Where your time went, stacked by ticket per day.") { historicalChart }
                section("Coverage trend (% of time attributed)",
                        "Share of active time with a ticket, per day. Rising = the system is learning your work.") { coverageChart }
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 720)
    }

    // MARK: - Header metric cards

    private var header: some View {
        HStack(spacing: 16) {
            metric("Active today", String(format: "%.1f h", data.activeHoursToday), .blue)
            metric("Attributed", pct(data.coverageToday), data.coverageToday > 0.7 ? .green : .orange)
            metric("Exact (not guessed)", pct(data.exactnessToday), .teal)
            metric("Avg guess conf.", data.avgGuessConfidence > 0 ? String(format: "%.2f", data.avgGuessConfidence) : "—", .purple)
            Spacer()
            Button("Refresh", action: onRefresh)
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Expected blocks (the would-be export rows)

    private var expectedBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(data.blocks, id: \.block) { b in
                HStack(alignment: .top) {
                    Text(b.label).font(.system(.callout, design: .monospaced)).bold().frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.effectiveTicket ?? "—")  ·  4h  ·  active \(Summary.hm(b.activeSeconds))")
                            .font(.body)
                        let parts = b.byTicket.prefix(4).map { "\($0.ticket ?? "untracked") \(Summary.hm($0.seconds))" }
                        Text(parts.joined(separator: "   ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if data.blocks.allSatisfy({ !$0.hasActivity }) {
                Text("No activity recorded yet today.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Charts

    private func donut(_ slices: [Slice]) -> some View {
        Group {
            if slices.isEmpty {
                placeholder
            } else {
                Chart(slices) { s in
                    SectorMark(angle: .value("Hours", s.hours), innerRadius: .ratio(0.55), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(by: .value("Label", s.label))
                }
                .frame(height: 220)
            }
        }
    }

    private var timeline: some View {
        Group {
            if data.timeline.isEmpty {
                placeholder
            } else {
                Chart(data.timeline) { seg in
                    BarMark(
                        xStart: .value("Start", seg.start),
                        xEnd: .value("End", seg.end),
                        y: .value("Row", "Today")
                    )
                    .foregroundStyle(by: .value("Ticket", seg.label))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) }
                .frame(height: 110)
            }
        }
    }

    private var confidenceChart: some View {
        Group {
            if data.confidenceBuckets.isEmpty {
                placeholder
            } else {
                Chart(data.confidenceBuckets) { b in
                    BarMark(x: .value("Confidence", b.label), y: .value("Count", b.seconds))
                        .foregroundStyle(.purple)
                }
                .frame(height: 220)
            }
        }
    }

    private var historicalChart: some View {
        Group {
            if data.historical.isEmpty {
                placeholder
            } else {
                Chart(data.historical) { d in
                    BarMark(x: .value("Day", d.day), y: .value("Hours", d.hours))
                        .foregroundStyle(by: .value("Ticket", d.ticket))
                }
                .frame(height: 260)
            }
        }
    }

    private var coverageChart: some View {
        Group {
            if data.coverageTrend.isEmpty {
                placeholder
            } else {
                Chart(data.coverageTrend) { p in
                    LineMark(x: .value("Day", p.day), y: .value("Coverage", p.coverage))
                    PointMark(x: .value("Day", p.day), y: .value("Coverage", p.coverage))
                }
                .chartYScale(domain: 0...1)
                .frame(height: 160)
            }
        }
    }

    private var placeholder: some View {
        Text("No data").foregroundStyle(.secondary).frame(height: 120, alignment: .center)
    }

    // MARK: - Helpers

    private func section<Content: View>(_ title: String, _ desc: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold().foregroundStyle(.secondary)
            if !desc.isEmpty { Text(desc).font(.caption2).foregroundStyle(.secondary) }
            content()
        }
    }

    private func pct(_ x: Double) -> String { x > 0 ? String(format: "%.0f%%", x * 100) : "—" }
}
