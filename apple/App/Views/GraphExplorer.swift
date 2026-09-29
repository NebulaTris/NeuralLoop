// An interactive knowledge graph in the style of Understand-Anything's explorer: one chapter's concepts, or (growing)
// the whole book map. Tap an idea to learn about it, follow its connections, take the guided tour, rebuild the map from
// memory, or ask how two ideas are connected.

import NeuralLoopCore
import SwiftUI

enum GraphPalette {
    static let colors: [Color] = [
        Theme.accent, Theme.mint, Theme.sky, Theme.rose,
        Theme.color(light: 0x9A6FD6, dark: 0xB797EE), Theme.color(light: 0xD9A21B, dark: 0xF0C04A),
    ]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// How the explorer colours ideas and (for the book map) grows.
struct GraphStyle {
    enum ColorBy { case layer, chapter }
    var colorBy: ColorBy = .layer
    var chapterOrder: [Int] = []
    var chapterTitles: [Int: String] = [:]
    /// Book map only: saved positions (ideas never move once placed), and the chapters sprouting for the first time.
    var saved: [String: Point] = [:]
    var fresh: Set<Int> = []
}

private enum Detail: String, CaseIterable { case overview = "Overview", learn = "Learn", deep = "Deep dive" }

struct GraphExplorer: View {
    let graph: KnowledgeGraph
    var style = GraphStyle()
    /// New ideas' positions, so the book map keeps its shape next time.
    var onPlaced: (([String: Point]) -> Void)? = nil
    var onOpenChapter: ((Int) -> Void)? = nil
    /// Bump to replay the book map growing, chapter by chapter.
    var replay = 0

    @State private var positions: [String: Point] = [:]
    @State private var anchors: [String: Point] = [:]
    @State private var sprouted: Set<Int> = []
    @State private var selected: String?
    @State private var detail: Detail = .learn
    @State private var query = ""
    @State private var hiddenGroups: Set<String> = []
    @State private var hiddenKinds: Set<String> = []
    @State private var tour = -1
    @State private var memory = false
    @State private var revealed: Set<String> = []
    @State private var path: [String]?
    @State private var pathFrom = ""
    @State private var pathTo = ""
    @State private var pathNote = ""
    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var zoomStart: CGFloat = 1
    @State private var canvasSize = CGSize(width: 640, height: 520)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var groups: [String] {
        switch style.colorBy {
        case .layer: var seen: [String] = []; for n in graph.nodes where !seen.contains(n.group) { seen.append(n.group) }; return seen
        case .chapter: return style.chapterOrder.map(String.init)
        }
    }

    private func groupKey(_ node: KnowledgeGraph.Node) -> String {
        style.colorBy == .layer ? node.group : String(node.chapter ?? 0)
    }

    private func groupLabel(_ key: String) -> String {
        guard style.colorBy == .chapter, let n = Int(key) else { return key }
        return style.chapterTitles[n] ?? "Chapter \(n)"
    }

    private func color(_ node: KnowledgeGraph.Node) -> Color { GraphPalette.color(groups.firstIndex(of: groupKey(node)) ?? 0) }

    private var visible: [KnowledgeGraph.Node] {
        graph.nodes.filter { !hiddenGroups.contains(groupKey($0)) && !hiddenKinds.contains($0.type ?? "concept") }
    }

    private var lit: Set<String>? {
        if let path { return Set(path) }
        if tour >= 0, tour < graph.tour.count { return Set(graph.tour[tour].nodeIds) }
        if let selected, !memory {
            var around: Set<String> = [selected]
            for edge in graph.edges where edge.source == selected || edge.target == selected { around.insert(edge.source); around.insert(edge.target) }
            return around
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        return Set(graph.nodes.filter { "\($0.name) \($0.summary ?? "")".lowercased().contains(q) }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            controls
            HStack(alignment: .top, spacing: 14) {
                framedCanvas
                panel.frame(width: 270)
            }
            #else
            // An upright iPad is too narrow for the map and its side panel together: the panel moves under the map.
            ViewThatFits(in: .horizontal) {
                controls
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) { filters }
                    HStack(spacing: 10) { Spacer(); actions }.font(Theme.body(13))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    framedCanvas.frame(minWidth: 480)
                    panel.frame(width: 270)
                }
                VStack(alignment: .leading, spacing: 14) {
                    framedCanvas
                    panel
                }
            }
            #endif
        }
        .onAppear(perform: layOut)
        .onChange(of: graph.nodes.map(\.id)) { layOut() }
        .onChange(of: replay) {
            sprouted = []
            grow(style.chapterOrder)
        }
    }

    // MARK: layout

    private func layOut() {
        let order = style.chapterOrder
        var anchorFor: [String: Point] = [:]
        for node in graph.nodes {
            let k = style.colorBy == .chapter ? (order.firstIndex(of: node.chapter ?? 0) ?? 0) : 0
            anchorFor[node.id] = GraphLayout.sproutPoint(k, center: Point(0, 0))
        }
        let radius = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, Double(nodeRadius($0))) })
        let fixed = style.saved.filter { id, _ in graph.nodes.contains { $0.id == id } }
        let placed = GraphLayout.layout(ids: graph.nodes.map(\.id), edges: graph.edges, anchors: anchorFor, fixed: fixed, radius: radius)
        anchors = anchorFor
        positions = placed
        let new = placed.filter { style.saved[$0.key] == nil }
        if !new.isEmpty { onPlaced?(new) }
        let settled = Set(graph.nodes.compactMap(\.chapter)).subtracting(style.fresh)
        sprouted = settled
        fit()
        if !style.fresh.isEmpty { grow(style.chapterOrder.filter(style.fresh.contains)) }
    }

    /// New chapters sprout in one after another from their spot on the spiral.
    private func grow(_ chapters: [Int]) {
        guard !reduceMotion else { sprouted.formUnion(chapters); return }
        for (i, n) in chapters.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(i) * 0.7) {
                withAnimation(.spring(duration: 0.9, bounce: 0.35)) { _ = sprouted.insert(n) }
            }
        }
    }

    private func fit() {
        let points = positions.values
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let width = max(maxX - minX + 160, 300)
        let height = max(maxY - minY + 120, 300)
        scale = CGFloat(min(1.3, max(0.25, min(Double(canvasSize.width) / width, Double(canvasSize.height) / height))))
        pan = CGSize(width: -CGFloat((minX + maxX) / 2) * scale, height: -CGFloat((minY + maxY) / 2) * scale)
        panStart = pan
    }

    private func nodeRadius(_ node: KnowledgeGraph.Node) -> CGFloat {
        switch node.complexity { case "complex": 20; case "moderate": 16; default: 12 }
    }

    private func screen(_ id: String, in size: CGSize) -> CGPoint? {
        guard var p = positions[id] else { return nil }
        if let node = graph.nodes.first(where: { $0.id == id }), let n = node.chapter, !sprouted.contains(n), let a = anchors[id] { p = a }
        return CGPoint(x: size.width / 2 + pan.width + CGFloat(p.x) * scale, y: size.height / 2 + pan.height + CGFloat(p.y) * scale)
    }

    // MARK: canvas

    private var framedCanvas: some View {
        canvas
            .frame(minHeight: 520)
            .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    private var canvas: some View {
        GeometryReader { geo in
            let shown = Set(visible.map(\.id))
            let highlight = lit
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { selected = nil; path = nil }
                Canvas { context, size in
                    for edge in graph.edges where shown.contains(edge.source) && shown.contains(edge.target) {
                        guard let a = screen(edge.source, in: size), let b = screen(edge.target, in: size) else { continue }
                        let on = highlight == nil || (highlight!.contains(edge.source) && highlight!.contains(edge.target))
                        drawEdge(edge, from: a, to: b, on: on, in: &context)
                    }
                }
                .allowsHitTesting(false)
                ForEach(visible) { node in
                    if let at = screen(node.id, in: geo.size) {
                        let growing = node.chapter.map { !sprouted.contains($0) } ?? false
                        NodeMark(node: node, color: color(node), radius: nodeRadius(node) * min(max(scale, 0.7), 1.3),
                                 label: memory && !revealed.contains(node.id) ? "?" : node.name,
                                 dimmed: highlight.map { !$0.contains(node.id) } ?? false,
                                 selected: selected == node.id)
                            .scaleEffect(growing ? 0.1 : 1)
                            .opacity(growing ? 0 : 1)
                            .position(at)
                            .onTapGesture { tap(node) }
                            .accessibilityAddTraits(.isButton)
                    }
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ZoomButtons(zoomIn: { scale = min(3, scale * 1.25) }, zoomOut: { scale = max(0.25, scale / 1.25) }, fit: fit)
                    }
                }
                .padding(10)
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { canvasSize = geo.size; fit() }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { pan = CGSize(width: panStart.width + $0.translation.width, height: panStart.height + $0.translation.height) }
                    .onEnded { _ in panStart = pan }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { scale = min(3, max(0.25, zoomStart * $0.magnification)) }
                    .onEnded { _ in zoomStart = scale }
            )
        }
    }

    private func drawEdge(_ edge: KnowledgeGraph.Edge, from a: CGPoint, to b: CGPoint, on: Bool, in context: inout GraphicsContext) {
        var line = Path()
        line.move(to: a)
        line.addLine(to: b)
        let type = edge.type ?? "related"
        let dash: [CGFloat] = type == "similar_to" ? [6, 5] : type == "contradicts" ? [2, 4] : []
        let color: Color = type == "contradicts" ? Theme.rose : Theme.ink3
        context.stroke(line, with: .color(color.opacity(on ? 0.7 : 0.15)), style: StrokeStyle(lineWidth: on ? 1.6 : 1, lineCap: .round, dash: dash))
        guard ["builds_on", "depends_on", "exemplifies", "categorized_under"].contains(type) else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let tip = CGPoint(x: b.x - cos(angle) * 16, y: b.y - sin(angle) * 16)
        var arrow = Path()
        arrow.move(to: CGPoint(x: tip.x - cos(angle - 0.45) * 8, y: tip.y - sin(angle - 0.45) * 8))
        arrow.addLine(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - cos(angle + 0.45) * 8, y: tip.y - sin(angle + 0.45) * 8))
        context.stroke(arrow, with: .color(color.opacity(on ? 0.8 : 0.15)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    private func tap(_ node: KnowledgeGraph.Node) {
        if memory {
            selected = node.id
            return
        }
        selected = selected == node.id ? nil : node.id
        path = nil
        tour = -1
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 10) {
            filters
            Spacer()
            actions
        }
        .font(Theme.body(13))
    }

    @ViewBuilder private var filters: some View {
        Picker("Detail", selection: $detail) { ForEach(Detail.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
        TextField("Find an idea", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
        Menu {
            Section(style.colorBy == .chapter ? "Chapters" : "Themes") {
                ForEach(groups, id: \.self) { key in
                    Toggle(groupLabel(key), isOn: Binding(get: { !hiddenGroups.contains(key) },
                                                          set: { if $0 { hiddenGroups.remove(key) } else { hiddenGroups.insert(key) } }))
                }
            }
            Section("Kinds") {
                ForEach([("concept", "● Concepts"), ("claim", "◆ Claims"), ("topic", "▢ Topics")], id: \.0) { kind, label in
                    Toggle(label, isOn: Binding(get: { !hiddenKinds.contains(kind) },
                                                set: { if $0 { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) } }))
                }
            }
        } label: { Label("Show", systemImage: "line.3.horizontal.decrease.circle") }
            .fixedSize()
    }

    @ViewBuilder private var actions: some View {
        if !graph.tour.isEmpty {
            Button { (tour, selected, path, memory) = (0, nil, nil, false) } label: { Label("Guided tour", systemImage: "figure.walk") }
                .fixedSize()
        }
        Button {
            memory.toggle()
            (selected, tour, path) = (nil, -1, nil)
            revealed = []
        } label: { Label(memory ? "Show names" : "From memory", systemImage: "brain.head.profile") }
            .fixedSize()
            .help("Hide the names and rebuild the map from memory")
    }

    // MARK: side panel

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tour >= 0, tour < graph.tour.count {
                tourPanel
            } else if memory {
                memoryPanel
            } else if let id = selected, let node = graph.nodes.first(where: { $0.id == id }) {
                ideaPanel(node)
            } else {
                legendPanel
            }
            Divider()
            pathFinder
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
    }

    private var legendPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap an idea to learn about it").font(Theme.display(15))
            Text("Arrows show what builds on what. Dashed lines join the same idea across chapters; pink dotted lines are disagreements.")
                .font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(groups.prefix(8).enumerated()), id: \.offset) { i, key in
                HStack(spacing: 6) {
                    Circle().fill(GraphPalette.color(i)).frame(width: 9, height: 9)
                    Text(groupLabel(key)).font(Theme.body(12)).lineLimit(1)
                }
            }
        }
    }

    private func ideaPanel(_ node: KnowledgeGraph.Node) -> some View {
        let links = graph.edges.filter { $0.source == node.id || $0.target == node.id }
        return VStack(alignment: .leading, spacing: 8) {
            Text(groupLabel(groupKey(node))).font(Theme.body(11)).foregroundStyle(color(node)).textCase(.uppercase)
            Text(node.name).font(Theme.display(18))
            if let summary = node.summary { Text(summary).font(Theme.body(13)).fixedSize(horizontal: false, vertical: true) }
            if detail != .overview, let more = node.detail, !more.isEmpty {
                Text(more).font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if !links.isEmpty {
                Text("Connections").font(Theme.body(12)).bold().padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, link in connection(link, from: node) }
                    }
                }
                .frame(maxHeight: 180)
            }
            HStack {
                if let n = node.chapter, let open = onOpenChapter { Button("Open chapter \(n)") { open(n) } }
                Button("Clear") { selected = nil }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func connection(_ link: KnowledgeGraph.Edge, from node: KnowledgeGraph.Node) -> some View {
        let outgoing = link.source == node.id
        if let other = graph.nodes.first(where: { $0.id == (outgoing ? link.target : link.source) }) {
            Button { selected = other.id } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(outgoing ? "→" : "←") \(other.name)").font(Theme.body(12)).foregroundStyle(Theme.ink)
                    Text(connectionNote(link, other: other, from: node)).font(Theme.body(10)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func connectionNote(_ link: KnowledgeGraph.Edge, other: KnowledgeGraph.Node, from node: KnowledgeGraph.Node) -> String {
        var note = (link.type ?? "related").replacingOccurrences(of: "_", with: " ")
        if detail == .deep, let description = link.description, !description.isEmpty { note += ": \(description)" }
        if let n = other.chapter, n != node.chapter { note += " · chapter \(n)" }
        return note
    }

    private var tourPanel: some View {
        let step = graph.tour[tour]
        let last = tour == graph.tour.count - 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Tour \(tour + 1) of \(graph.tour.count)").font(Theme.body(11)).foregroundStyle(Theme.accent).textCase(.uppercase)
            Text(step.title).font(Theme.display(17))
            if let description = step.description { Text(description).font(Theme.body(13)).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Back") { tour -= 1 }.disabled(tour == 0)
                Button(last ? "Finish" : "Next") { tour = last ? -1 : tour + 1 }.buttonStyle(.borderedProminent)
                Button("Exit") { tour = -1 }
            }
            .controlSize(.small)
            PipView(pose: last ? .proud : .read, size: 80).frame(maxWidth: .infinity)
        }
    }

    private var memoryPanel: some View {
        let left = graph.nodes.count - revealed.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("Rebuild from memory").font(Theme.display(17))
            Text("The names are hidden. Tap an idea, say what it is, then reveal it.").font(Theme.body(12)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let id = selected, let node = graph.nodes.first(where: { $0.id == id }) {
                if revealed.contains(id) {
                    Text(node.name).font(Theme.display(15))
                    if let summary = node.summary { Text(summary).font(Theme.body(12)).fixedSize(horizontal: false, vertical: true) }
                } else {
                    Button("Reveal") {
                        revealed.insert(id)
                        if revealed.count == graph.nodes.count { memory = false; selected = nil }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text(left == 0 ? "Map rebuilt from memory!" : "\(left) left").font(Theme.body(11)).foregroundStyle(Theme.ink3)
        }
    }

    private var pathFinder: some View {
        let sorted = graph.nodes.sorted { $0.name < $1.name }
        return DisclosureGroup("How are two ideas connected?") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("From", selection: $pathFrom) { Text("Pick an idea").tag(""); ForEach(sorted) { Text($0.name).tag($0.id) } }
                Picker("To", selection: $pathTo) { Text("Pick an idea").tag(""); ForEach(sorted) { Text($0.name).tag($0.id) } }
                Button("Show path") {
                    guard !pathFrom.isEmpty, !pathTo.isEmpty else { return }
                    if let found = GraphLayout.shortestPath(from: pathFrom, to: pathTo, edges: graph.edges) {
                        (path, selected, tour) = (found, nil, -1)
                        pathNote = found.compactMap { id in graph.nodes.first { $0.id == id }?.name }.joined(separator: " → ")
                    } else {
                        path = nil
                        pathNote = "These two ideas aren't connected yet."
                    }
                }
                .controlSize(.small)
                if !pathNote.isEmpty { Text(pathNote).font(Theme.body(11)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.top, 6)
        }
        .font(Theme.body(12))
    }
}

/// One idea: a circle (concept), diamond (claim), or rounded square (topic), with its name underneath.
private struct NodeMark: View {
    let node: KnowledgeGraph.Node
    let color: Color
    let radius: CGFloat
    let label: String
    let dimmed: Bool
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            shape
                .frame(width: radius * 2, height: radius * 2)
                .overlay(shapeOutline)
            Text(label.count > 24 ? "\(label.prefix(22))…" : label)
                .font(Theme.body(10)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.paper.opacity(0.85), in: Capsule())
                .fixedSize()
        }
        .opacity(dimmed ? 0.25 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var shape: some View {
        switch node.type {
        case "claim": Rectangle().fill(color).rotationEffect(.degrees(45)).scaleEffect(0.78)
        case "topic": RoundedRectangle(cornerRadius: 6).fill(color)
        default: Circle().fill(color)
        }
    }

    @ViewBuilder private var shapeOutline: some View {
        if selected {
            Circle().stroke(Theme.ink, lineWidth: 2.5).padding(-5)
        }
    }
}

private struct ZoomButtons: View {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let fit: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: zoomIn) { Image(systemName: "plus") }.help("Zoom in")
            Button(action: zoomOut) { Image(systemName: "minus") }.help("Zoom out")
            Button(action: fit) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit the whole map")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
