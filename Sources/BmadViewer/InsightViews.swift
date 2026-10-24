import BmadKit
import Charts
import SwiftUI

// MARK: Dependency graph

/// Middle column: what the graph covers, its longest remaining chain, and a legend.
struct GraphControlsView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        let graph = DependencyGraph.build(project, epic: store.graphEpic, hideFinished: store.hideFinished)
        List {
            Section {
                Picker("Scope", selection: $store.graphEpic) {
                    Text("All epics").tag(String?.none)
                    ForEach(project.epics.filter { !$0.stories.isEmpty }) { epic in
                        Text("\(epic.number.map { "\($0) · " } ?? "")\(epic.title)").tag(Optional(epic.id))
                    }
                }
                Toggle("Hide finished stories", isOn: $store.hideFinished)
                Text("\(graph.nodes.count) stories · \(graph.edges.count) links · \(graph.layers) layers")
                    .font(.caption).foregroundStyle(.secondary)
                if project.layout == .sprintStatus {
                    Label("Links are inferred from build-order's Waits on column and \"Depends on / Queued after\" sentences in epics.md.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Longest remaining chain (\(graph.longestChain.count))") {
                if graph.longestChain.isEmpty {
                    Text("Nothing left waiting on anything.").foregroundStyle(.secondary)
                }
                ForEach(Array(graph.longestChain.enumerated()), id: \.element) { i, id in
                    if let story = project.story(id: id) {
                        Button {
                            store.graphFocus = id
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
                                Text(story.number).font(.callout.monospacedDigit().weight(.semibold))
                                Text(story.title).lineLimit(1)
                                Spacer(minLength: 4)
                                StatusBadge(status: story.status)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Legend") {
                Label("Thick accent line: the longest remaining chain", systemImage: "line.diagonal").font(.caption)
                Label("Dashed box: a prerequisite from another epic", systemImage: "rectangle.dashed").font(.caption)
                Label("Click to highlight a story's links; double-click to open it", systemImage: "cursorarrow.click.2").font(.caption)
            }
        }
        .navigationTitle("Dependencies")
    }
}

/// Detail column: the layered graph, prerequisites on the left.
struct DependencyGraphView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @State private var zoom: CGFloat = 1

    static let nodeSize = CGSize(width: 200, height: 58)
    static let gap = CGSize(width: 70, height: 16)

    var body: some View {
        let graph = DependencyGraph.build(project, epic: store.graphEpic, hideFinished: store.hideFinished)
        let chain = Set(graph.longestChain)
        let chainEdges = Set(zip(graph.longestChain, graph.longestChain.dropFirst()).map { "\($0)>\($1)" })
        let focus = store.graphFocus
        let near = focus.map { f in Set(graph.edges.filter { $0.from == f || $0.to == f }.flatMap { [$0.from, $0.to] }) } ?? []
        let size = CGSize(width: CGFloat(graph.layers) * (Self.nodeSize.width + Self.gap.width) + 40,
                          height: CGFloat(graph.rows) * (Self.nodeSize.height + Self.gap.height) + 40)
        let position = Dictionary(graph.nodes.map { ($0.id, Self.origin($0)) }, uniquingKeysWith: { a, _ in a })

        if graph.nodes.isEmpty {
            ContentUnavailableView("No stories to draw", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text(store.hideFinished ? "Every story here is finished." : "No stories in this scope."))
        } else {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for edge in graph.edges {
                                guard let a = position[edge.from], let b = position[edge.to] else { continue }
                                let start = CGPoint(x: a.x + Self.nodeSize.width, y: a.y + Self.nodeSize.height / 2)
                                let end = CGPoint(x: b.x, y: b.y + Self.nodeSize.height / 2)
                                var path = Path()
                                path.move(to: start)
                                let dx = max(30, (end.x - start.x) / 2)
                                path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                                let onChain = chainEdges.contains("\(edge.from)>\(edge.to)")
                                let lit = focus != nil && (edge.from == focus || edge.to == focus)
                                let faded = focus != nil && !lit
                                context.stroke(path, with: .color(onChain || lit ? Color.accentColor : Color.secondary.opacity(faded ? 0.12 : 0.4)),
                                               lineWidth: onChain || lit ? 2.5 : 1)
                                // Arrowhead at the dependent.
                                var head = Path()
                                head.move(to: end)
                                head.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                                head.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                                head.closeSubpath()
                                context.fill(head, with: .color(onChain || lit ? Color.accentColor : Color.secondary.opacity(faded ? 0.12 : 0.5)))
                            }
                        }
                        .frame(width: size.width, height: size.height)

                        ForEach(graph.nodes) { node in
                            GraphNodeView(node: node, onChain: chain.contains(node.id), focused: node.id == focus,
                                          faded: focus != nil && node.id != focus && !near.contains(node.id))
                                .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
                                .offset(x: position[node.id]!.x, y: position[node.id]!.y)
                                .id(node.id)
                                .onTapGesture(count: 2) { store.select(storyNumber: node.number) }
                                .onTapGesture { store.graphFocus = store.graphFocus == node.id ? nil : node.id }
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.graphFocus = nil }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .onChange(of: store.graphFocus) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { zoom = max(0.3, zoom / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    Text("\(Int(zoom * 100))%").monospacedDigit().frame(minWidth: 44)
                    Button { zoom = min(2.5, zoom * 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    Button { zoom = 1 } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                }
            }
            .navigationTitle("Dependencies")
        }
    }

    static func origin(_ node: DependencyGraph.Node) -> CGPoint {
        CGPoint(x: 20 + CGFloat(node.layer) * (nodeSize.width + gap.width),
                y: 20 + CGFloat(node.row) * (nodeSize.height + gap.height))
    }
}

private struct GraphNodeView: View {
    let node: DependencyGraph.Node
    let onChain: Bool
    let focused: Bool
    let faded: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(node.status.color).frame(width: 7, height: 7)
                Text(node.number).font(.caption.monospacedDigit().weight(.bold))
                Spacer(minLength: 0)
                Text(node.status.raw).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(node.title).font(.caption).lineLimit(2).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay {
            if node.external {
                shape.stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                shape.stroke(onChain || focused ? Color.accentColor : node.status.color.opacity(0.6), lineWidth: onChain || focused ? 2.5 : 1)
            }
        }
        .opacity(faded ? 0.3 : node.external ? 0.7 : 1)
        .help("\(node.number): \(node.title)")
    }
}

// MARK: Burn-up

/// Middle column: which epic the burn-up shows.
struct BurnupControlsView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        List(selection: $store.burnupEpic) {
            row(nil, title: "All epics", done: project.allStories.filter { $0.status.kind == .done }.count,
                total: project.allStories.filter { $0.status.kind != .superseded }.count)
            ForEach(project.epics.filter { !$0.stories.isEmpty }) { epic in
                row(epic.id, title: "\(epic.number.map { "\($0) · " } ?? "")\(epic.title)",
                    done: epic.stories.filter { $0.status.kind == .done }.count,
                    total: epic.stories.filter { $0.status.kind != .superseded }.count)
            }
        }
        .navigationTitle("Burn-up")
    }

    private func row(_ id: String?, title: String, done: Int, total: Int) -> some View {
        HStack {
            Text(title).lineLimit(2)
            Spacer(minLength: 6)
            Text("\(done)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .tag(id)
    }
}

/// Detail column: scope against done (and built) over time, replayed from git.
struct BurnupChartView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @State private var hovered: Date?
    @State private var showTable = false

    struct Point: Identifiable {
        var id: String { "\(series)#\(date.timeIntervalSince1970)" }
        let date: Date
        let series: String
        let value: Int
    }

    var body: some View {
        Group {
            switch store.burnup {
            case nil:
                ProgressView("Replaying git history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error)?:
                ContentUnavailableView("No history", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text(error.localizedDescription))
            case .success(let snapshots)?:
                chart(daily(snapshots))
            }
        }
        .navigationTitle("Burn-up")
        .task(id: store.lastLoaded) { store.loadBurnupIfNeeded() }
    }

    /// The last snapshot of each day: enough resolution, far fewer marks.
    private func daily(_ snapshots: [Burnup.Snapshot]) -> [(Date, Burnup.Counts)] {
        let cal = Calendar.current
        var byDay: [Date: Burnup.Counts] = [:]
        for s in snapshots { byDay[cal.startOfDay(for: s.date)] = s.counts(epic: store.burnupEpic) }
        return byDay.keys.sorted().map { ($0, byDay[$0]!) }.drop { $0.1.total == 0 }.map { $0 }
    }

    @ViewBuilder private func chart(_ days: [(Date, Burnup.Counts)]) -> some View {
        let showBuilt = project.layout == .ticketTree
        let points = days.flatMap { day, c -> [Point] in
            var p = [Point(date: day, series: "Scope", value: c.total), Point(date: day, series: "Done", value: c.done)]
            if showBuilt { p.append(Point(date: day, series: "Done + built", value: c.done + c.built)) }
            return p
        }
        let title = store.burnupEpic.flatMap { id in project.epics.first { $0.id == id }?.title } ?? "All epics"
        if days.isEmpty {
            ContentUnavailableView("No history for \(title)", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Nothing in git history touches this epic's statuses yet."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title3.weight(.semibold))
                        if let last = days.last?.1 {
                            Text("\(last.done) of \(last.total) done\(showBuilt ? ", \(last.built) built" : "") · \(days.count) days of history")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Table", isOn: $showTable).toggleStyle(.button)
                }
                if showTable {
                    Table(days.reversed().map { BurnupRow(date: $0.0, counts: $0.1) }) {
                        TableColumn("Date") { Text($0.date, format: .dateTime.year().month().day()) }
                        TableColumn("Scope") { Text("\($0.counts.total)").monospacedDigit() }
                        TableColumn("Done") { Text("\($0.counts.done)").monospacedDigit() }
                        TableColumn("Built") { row in Text(showBuilt ? "\(row.counts.built)" : "—").monospacedDigit() }
                    }
                } else {
                    Chart {
                        ForEach(points) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Stories", p.value), series: .value("Series", p.series))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(by: .value("Series", p.series))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: p.series == "Scope" ? [5, 4] : []))
                        }
                        if let last = days.last {
                            ForEach(series(last.1, showBuilt: showBuilt), id: \.0) { name, value in
                                PointMark(x: .value("Date", last.0), y: .value("Stories", value))
                                    .foregroundStyle(by: .value("Series", name))
                                    .symbolSize(30)
                                    .annotation(position: .trailing, alignment: .leading) {
                                        Text("\(value)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                            }
                        }
                        if let hovered, let day = days.last(where: { $0.0 <= hovered }) {
                            RuleMark(x: .value("Date", day.0))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                                .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit, y: .disabled)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(day.0, format: .dateTime.year().month().day()).font(.caption.weight(.semibold))
                                        ForEach(series(day.1, showBuilt: showBuilt), id: \.0) { name, value in
                                            Text("\(name): \(value)").font(.caption.monospacedDigit())
                                        }
                                    }
                                    .padding(6)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                }
                        }
                    }
                    .chartForegroundStyleScale(domain: showBuilt ? ["Scope", "Done", "Done + built"] : ["Scope", "Done"],
                                               range: showBuilt ? [Color.secondary, Color.green, Color.indigo] : [Color.secondary, Color.green])
                    .chartLegend(position: .top, alignment: .leading)
                    .chartYAxisLabel("Stories")
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let at):
                                        guard let frame = proxy.plotFrame else { return }
                                        let x = at.x - geo[frame].origin.x
                                        hovered = proxy.value(atX: x, as: Date.self)
                                    case .ended:
                                        hovered = nil
                                    }
                                }
                        }
                    }
                    .padding(.trailing, 28)
                }
            }
            .padding(20)
        }
    }

    private func series(_ c: Burnup.Counts, showBuilt: Bool) -> [(String, Int)] {
        var s = [("Scope", c.total), ("Done", c.done)]
        if showBuilt { s.append(("Done + built", c.done + c.built)) }
        return s
    }
}

private struct BurnupRow: Identifiable {
    var id: Date { date }
    let date: Date
    let counts: Burnup.Counts
}
