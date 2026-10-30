import BmadKit
import Charts
import SwiftUI

// MARK: Cards (detail column)

/// What to look at next: up next, awaiting review, recently completed, recently created.
struct DashboardCardsView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        let m = store.milestones
        ScrollView {
            VStack(spacing: 12) {
                card("Up next", systemImage: "arrow.right.circle", stories: upNext, empty: "Nothing queued.",
                     more: project.queue.isEmpty ? nil : .queue) { story in
                    story.waitsOn.isEmpty ? nil : "waits on \(story.waitsOn.joined(separator: ", "))"
                }
                card("Awaiting review", systemImage: "eye", stories: awaitingReview(m), empty: "Nothing awaiting review.", more: .active) { story in
                    m?.built[story.id].map(Self.ago)
                }
                card("Recently completed", systemImage: "checkmark.seal", stories: recent(m?.done, finished: true), empty: m == nil ? "Reading history…" : "Nothing completed yet.", more: .all) { story in
                    m?.done[story.id].map(Self.ago)
                }
                card("Recently created", systemImage: "sparkles", stories: recent(m?.created, finished: false), empty: m == nil ? "Reading history…" : "No history.", more: .all) { story in
                    m?.created[story.id].map(Self.ago)
                }
            }
            .padding(12)
        }
        .task(id: store.lastLoaded) { store.loadBurnupIfNeeded() }
    }

    /// The queue's head (build order, or a ticket tree's in-progress and ready groups).
    private var upNext: [Story] {
        let headings = project.layout == .ticketTree ? ["In progress", "Ready to start", "Ready to refine"] : [project.queue.first?.heading ?? ""]
        let numbers = project.queue.filter { headings.contains($0.heading) }.flatMap(\.entries).map(\.storyNumber)
        var out = numbers.compactMap { project.story(number: $0) }
        // Anything active that the queue does not list.
        out += project.allStories.filter { $0.status.isActive && $0.status.kind != .review && !out.contains($0) }
        return Array(out.prefix(8))
    }

    private func awaitingReview(_ m: Burnup.Milestones?) -> [Story] {
        project.allStories.filter { $0.status.kind == .review || $0.status.kind == .built }
            .sorted { (m?.built[$0.id] ?? .distantPast) > (m?.built[$1.id] ?? .distantPast) }
            .prefix(8).map { $0 }
    }

    private func recent(_ dates: [String: Date]?, finished: Bool) -> [Story] {
        guard let dates else { return [] }
        return dates.sorted { $0.value > $1.value }.compactMap { project.story(id: $0.key) }
            .filter { !finished || $0.status.isTerminal || $0.status.kind == .built }
            .prefix(8).map { $0 }
    }

    static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func card(_ title: String, systemImage: String, stories: [Story], empty: String, more: SidebarItem?,
                      detail: @escaping (Story) -> String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                if let more {
                    Button("See all") { store.sidebar = more }.buttonStyle(.link).font(.caption)
                }
            }
            if stories.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(stories) { story in
                Button {
                    store.select(storyNumber: story.number)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(story.number).font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 38, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(story.title).lineLimit(2).multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                StatusBadge(status: story.status)
                                if let d = detail(story) { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                if story != stories.last { Divider() }
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}

// MARK: Overview (middle column)

/// Tiles, completeness, epic progress, throughput, recent burn-up and project health.
struct DashboardView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        let stories = project.allStories
        let inScope = stories.filter { $0.status.kind != .superseded }
        let done = inScope.filter { $0.status.kind == .done }.count
        let built = inScope.filter { $0.status.kind == .built }.count
        let percent = inScope.isEmpty ? 0 : Int((Double(done) / Double(inScope.count) * 100).rounded())
        let openDW = project.deferredWork.filter { !$0.status.isTerminal }
        let urgentDW = openDW.filter { $0.priority == .critical || $0.priority == .high }
        let graph = DependencyGraph.build(project, epic: nil, hideFinished: false)
        let chain = graph.longestChain
        let heavy = graph.heaviestChain
        let effort = Effort.summary(stories.filter { !$0.status.isTerminal })
        let heavyEffort = Effort.summary(heavy.compactMap { project.story(id: $0) })

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    Tile(value: "\(percent)%", label: "complete", detail: "\(done) of \(inScope.count) stories done", color: .green, target: .all)
                    if built > 0 { Tile(value: "\(built)", label: "built, awaiting done", detail: nil, color: .indigo, target: .active) }
                    Tile(value: "\(stories.filter { $0.status.isActive }.count)", label: "active", detail: "in progress, review, ready", color: .blue, target: .active)
                    Tile(value: "\(stories.filter { $0.status.kind == .review }.count)", label: "in review", detail: nil, color: .purple, target: .active)
                    if !project.deferredWork.isEmpty {
                        Tile(value: "\(openDW.count)", label: "open deferred", detail: "\(urgentDW.count) critical or high", color: urgentDW.isEmpty ? .secondary : .orange, target: .deferredWork)
                    }
                    if !project.retroActions.isEmpty {
                        Tile(value: "\(project.retroActions.filter { !$0.status.isTerminal }.count)", label: "open retro actions", detail: nil, color: .secondary, target: .retroActions)
                    }
                    if !project.humanRuns.isEmpty {
                        Tile(value: "\(project.humanRuns.filter { !$0.status.isTerminal }.count)", label: "human runs owed", detail: nil, color: .secondary, target: .humanRuns)
                    }
                    Tile(value: "\(chain.count)", label: "longest remaining chain", detail: chain.first.flatMap { project.story(id: $0)?.number }.map { "starts at \($0)" }, color: .secondary, target: .graph)
                    if let points = effort.pointsLabel {
                        Tile(value: points, label: "effort remaining", detail: effort.coverage, color: .secondary, target: .all)
                            .help("The sum of the tickets' numeric estimates over the stories still open")
                    }
                    if !heavy.isEmpty, let points = heavyEffort.pointsLabel {
                        let start = heavy.first.flatMap { project.story(id: $0)?.number }.map { " · starts at \($0)" } ?? ""
                        Tile(value: points, label: "heaviest remaining chain", detail: "\(heavy.count) tickets\(start)", color: .secondary, target: .graph)
                            .help("The remaining chain whose estimates weigh the most")
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
                    Panel("Completeness") { CompletenessChart(stories: stories, percent: percent) }
                    Panel("Throughput per week") { ThroughputChart(perWeek: store.milestones?.finishedPerWeek, ticketTree: project.layout == .ticketTree) }
                    Panel("Last 60 days") { RecentBurnup(project: project) }
                    Panel("Health") { HealthPanel(project: project) }
                }

                Panel("Epics") { EpicProgressChart(project: project) }
            }
            .padding(20)
        }
        .task(id: store.lastLoaded) { store.loadBurnupIfNeeded() }
    }

    private var subtitle: String {
        var parts = [project.layout.rawValue, "\(project.epics.filter { !$0.stories.isEmpty }.count) epics", "\(project.allStories.count) stories"]
        if case .success(let snaps)? = store.burnup, let last = snaps.last {
            parts.append("last status change \(last.date.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct Tile: View {
    @Environment(ProjectStore.self) private var store
    let value: String
    let label: String
    let detail: String?
    let color: Color
    let target: SidebarItem

    var body: some View {
        Button { store.sidebar = target } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color == .secondary ? Color.primary : color)
                Text(label).font(.callout)
                Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}

/// The order and colours statuses are charted in, matching the badges.
private let chartKinds: [Status.Kind] = [.done, .built, .review, .inProgress, .blocked, .ready, .backlog, .optional, .other, .superseded]

private struct CompletenessChart: View {
    let stories: [Story]
    let percent: Int

    var body: some View {
        let counts = chartKinds.map { k in (k, stories.filter { $0.status.kind == k }.count) }.filter { $0.1 > 0 }
        HStack(alignment: .center, spacing: 16) {
            Chart(counts, id: \.0) { kind, count in
                SectorMark(angle: .value("Stories", count), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(colour(kind))
            }
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text("\(percent)%").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("done").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(counts, id: \.0) { kind, count in
                    HStack(spacing: 6) {
                        Circle().fill(colour(kind)).frame(width: 8, height: 8)
                        Text(kind.label).font(.callout)
                        Spacer(minLength: 8)
                        Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func colour(_ kind: Status.Kind) -> Color { kind.color }

private struct EpicProgressChart: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    struct Bar: Identifiable {
        var id: String { "\(epic)#\(kind.rawValue)" }
        let epic: String
        let label: String
        let kind: Status.Kind
        let count: Int
    }

    var body: some View {
        let epics = project.epics.filter { !$0.stories.isEmpty }
        let bars = epics.flatMap { epic in
            chartKinds.map { k in Bar(epic: epic.id, label: label(epic), kind: k, count: epic.stories.filter { $0.status.kind == k }.count) }
                .filter { $0.count > 0 }
        }
        let present = chartKinds.filter { k in bars.contains { $0.kind == k } }
        Chart(bars) { bar in
            BarMark(x: .value("Stories", bar.count), y: .value("Epic", bar.label))
                .foregroundStyle(by: .value("Status", bar.kind.label))
        }
        .chartForegroundStyleScale(domain: present.map(\.label), range: present.map(colour))
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel().font(.caption) }
        }
        .frame(height: CGFloat(max(epics.count, 1)) * 26 + 40)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let y = location.y - geo[frame].origin.y
                        if let name: String = proxy.value(atY: y), let epic = epics.first(where: { label($0) == name }) {
                            store.sidebar = .epic(epic.id)
                        }
                    }
            }
        }
        Text("Click an epic's bar to open it.").font(.caption).foregroundStyle(.secondary)
    }

    private func label(_ epic: Epic) -> String {
        let title = epic.title.count > 34 ? String(epic.title.prefix(33)) + "…" : epic.title
        return epic.number.map { "\($0) · \(title)" } ?? title
    }
}

private struct ThroughputChart: View {
    let perWeek: [Date: Int]?
    let ticketTree: Bool

    var body: some View {
        if let perWeek {
            let weeks = lastWeeks(12)
            let points = weeks.map { ($0, perWeek[$0] ?? 0) }
            let avg = Double(points.map(\.1).reduce(0, +)) / Double(max(points.count, 1))
            Chart {
                ForEach(points, id: \.0) { week, count in
                    BarMark(x: .value("Week", week, unit: .weekOfYear), y: .value("Stories", count))
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Average", avg))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg \(avg, format: .number.precision(.fractionLength(1)))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 160)
            Text(ticketTree ? "Tickets reaching built or done for the first time, last 12 weeks." : "Stories reaching done, last 12 weeks.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private func lastWeeks(_ n: Int) -> [Date] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return (0..<n).reversed().compactMap { cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
    }
}

private struct RecentBurnup: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        switch store.burnup {
        case .success(let snaps)?:
            let since = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
            let cal = Calendar.current
            var byDay: [Date: Burnup.Counts] = [:]
            let _ = snaps.forEach { byDay[cal.startOfDay(for: $0.date)] = $0.counts(epic: nil) }
            let days = byDay.keys.filter { $0 >= since }.sorted()
            let built = project.layout == .ticketTree
            Chart {
                ForEach(days, id: \.self) { day in
                    let c = byDay[day]!
                    LineMark(x: .value("Date", day), y: .value("Stories", c.total), series: .value("Series", "Scope"))
                        .foregroundStyle(by: .value("Series", "Scope"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .interpolationMethod(.stepEnd)
                    LineMark(x: .value("Date", day), y: .value("Stories", c.done), series: .value("Series", "Done"))
                        .foregroundStyle(by: .value("Series", "Done"))
                        .interpolationMethod(.stepEnd)
                    if built {
                        LineMark(x: .value("Date", day), y: .value("Stories", c.done + c.built), series: .value("Series", "Done + built"))
                            .foregroundStyle(by: .value("Series", "Done + built"))
                            .interpolationMethod(.stepEnd)
                    }
                }
            }
            .chartForegroundStyleScale(domain: built ? ["Scope", "Done", "Done + built"] : ["Scope", "Done"],
                                       range: built ? [Color.secondary, Color.green, Color.indigo] : [Color.secondary, Color.green])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 160)
            Button("Open burn-up") { store.sidebar = .burnup }.buttonStyle(.link).font(.caption)
        case .failure(let error)?:
            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
        case nil:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        }
    }
}

private struct HealthPanel: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !project.deferredWork.isEmpty {
                let open = project.deferredWork.filter { !$0.status.isTerminal }
                row("Open deferred work by priority", target: .deferredWork) {
                    HStack(spacing: 10) {
                        ForEach(Priority.allCases, id: \.self) { p in
                            let n = open.filter { $0.priority == p }.count
                            if n > 0 {
                                Text("\(p.label) \(n)").font(.caption.monospacedDigit())
                                    .foregroundStyle(p == .critical ? .red : p == .high ? .orange : .secondary)
                            }
                        }
                    }
                }
                let gates = open.filter { !$0.gates.isEmpty }
                if !gates.isEmpty {
                    row("Stories gated by open entries", target: .deferredWork) {
                        Text(gates.flatMap(\.gates).joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            let checked = project.retroActions.compactMap(\.followThrough)
            if !checked.isEmpty {
                row("Retro follow-through", target: .retroActions) {
                    HStack(spacing: 10) {
                        Label("\(checked.filter { $0.verdict == .landed }.count) landed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Label("\(checked.filter { $0.verdict == .partly }.count) partly", systemImage: "circle.lefthalf.filled").foregroundStyle(.orange)
                        Label("\(checked.filter { $0.verdict == .notLanded }.count) not landed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    .font(.caption)
                }
            }
            let owed = project.humanRuns.filter { !$0.status.isTerminal }
            if !owed.isEmpty {
                row("Human runs owed", target: .humanRuns) {
                    Text(owed.prefix(4).map(\.label).joined(separator: ", ") + (owed.count > 4 ? " +\(owed.count - 4)" : ""))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            let mismatched = project.allStories.filter { s in
                project.layout == .sprintStatus && s.frontMatter["status"].map { $0 != s.status.raw && Status($0).kind != s.status.kind } == true
            }
            if !mismatched.isEmpty {
                row("Story files disagreeing with sprint-status.yaml", target: .all) {
                    Text(mismatched.prefix(8).map(\.number).joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.orange)
                }
            }
            if !project.warnings.isEmpty {
                row("Loader warnings", target: nil) {
                    Text("\(project.warnings.count): \(project.warnings.first ?? "")").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            if project.deferredWork.isEmpty && checked.isEmpty && owed.isEmpty && project.warnings.isEmpty {
                Text("Nothing needs attention.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ title: String, target: SidebarItem?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if let target { Button("Open") { store.sidebar = target }.buttonStyle(.link).font(.caption) }
            }
            content()
        }
    }
}
