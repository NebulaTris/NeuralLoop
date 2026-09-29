// book.json: the payload the pipeline writes for every book (and, for books made before the app, book-data.js).
// Every part may be missing or null while a book is still being prepared, so everything decodes with a default.

import Foundation

public enum ItemStatus: String, Codable, Sendable {
    case todo, working, done, skipped, failed
    case waiting = "waiting_quota"
}

public struct Card: Codable, Equatable, Sendable {
    public var front: String
    public var back: String
    public init(front: String, back: String) { (self.front, self.back) = (front, back) }
}

public struct QuizQuestion: Codable, Equatable, Sendable {
    public var q: String
    public var options: [String]
    public var a: Int
    public var hint: String
    public var why: [String]
}

public struct GuideEntry: Codable, Equatable, Sendable {
    public var section: String
    public var level: String        // "deep" | "normal" | "skim"
    public var why: String
}

public struct RecallPrompt: Codable, Equatable, Sendable {
    public var prompt: String
    public var keyPoints: [String]
}

public struct MindNode: Codable, Equatable, Sendable {
    public var name: String
    public var children: [MindNode]
    enum CodingKeys: String, CodingKey { case name, children }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        children = try c.decodeIfPresent([MindNode].self, forKey: .children) ?? []
    }
}

public struct Concept: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var summary: String
    public var detail: String
    public var complexity: String
    public var layer: String
}

public struct ConceptEdge: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var type: String
    public var description: String?
}

public struct Layer: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
}

public struct TourStep: Codable, Equatable, Sendable {
    public var title: String
    public var description: String?
    public var nodeIds: [String]
    public init(title: String, description: String?, nodeIds: [String]) { (self.title, self.description, self.nodeIds) = (title, description, nodeIds) }
}

public struct ConceptGraph: Codable, Equatable, Sendable {
    public var concepts: [Concept]
    public var layers: [Layer]
    public var edges: [ConceptEdge]
    public var tour: [TourStep]
}

public struct Slide: Codable, Equatable, Sendable {
    public var title: String
    public var points: [String]
    public var narration: String
    public var pose: String
    public var audio: String?
    public var duration: Double?
}

public struct Explainer: Codable, Equatable, Sendable {
    public var slides: [Slide]
}

/// Where the chapter's reading comes from: the book's own PDF pages, or text (Markdown with figures).
public enum Reading: Equatable, Sendable, Decodable {
    case text(String)
    case pdf(file: String)

    public var text: String? { if case .text(let t) = self { t } else { nil } }

    enum CodingKeys: String, CodingKey { case kind, text, file }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(String.self, forKey: .kind) == "pdf" {
            self = .pdf(file: try c.decode(String.self, forKey: .file))
        } else {
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }
}

public struct Chapter: Decodable, Equatable, Sendable {
    public var n: Int
    public var title: String
    public var read: Reading
    public var status: [String: ItemStatus]
    public var notes: [String: String]
    public var guide: [GuideEntry]
    public var recall: [RecallPrompt]
    public var quiz: [QuizQuestion]
    public var cards: [Card]
    public var mindmap: MindNode?
    public var graph: ConceptGraph?
    public var audio: String?
    public var transcript: String?
    public var video: String?
    public var explainer: Explainer?

    public init(n: Int, title: String = "", cards: [Card] = []) {
        (self.n, self.title, self.cards) = (n, title, cards)
        (read, status, notes, guide, recall, quiz) = (.text(""), [:], [:], [], [], [])
    }

    enum CodingKeys: String, CodingKey {
        case n, title, read, status, notes, guide, recall, quiz, cards, mindmap, graph, audio, transcript, video, explainer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decode(Int.self, forKey: .n)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        read = try c.decodeIfPresent(Reading.self, forKey: .read) ?? .text("")
        status = try c.decodeIfPresent([String: ItemStatus].self, forKey: .status) ?? [:]
        notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        guide = try c.decodeIfPresent([GuideEntry].self, forKey: .guide) ?? []
        recall = try c.decodeIfPresent([RecallPrompt].self, forKey: .recall) ?? []
        quiz = try c.decodeIfPresent([QuizQuestion].self, forKey: .quiz) ?? []
        cards = try c.decodeIfPresent([Card].self, forKey: .cards) ?? []
        mindmap = try c.decodeIfPresent(MindNode.self, forKey: .mindmap)
        graph = try c.decodeIfPresent(ConceptGraph.self, forKey: .graph)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        video = try c.decodeIfPresent(String.self, forKey: .video)
        explainer = try c.decodeIfPresent(Explainer.self, forKey: .explainer)
    }
}

/// The book map in Understand-Anything's knowledge-graph format; only the fields the app draws are decoded.
public struct KnowledgeGraph: Decodable, Equatable, Sendable {
    public struct Node: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String?
        public var detail: String?
        public var type: String?          // "concept" | "claim" | "topic"
        public var complexity: String?    // "simple" | "moderate" | "complex"
        public var chapter: Int?
        public var layer: String?
        public var layerName: String?
        public var group: String { layerName ?? layer ?? "Ideas" }
    }
    public struct Edge: Decodable, Equatable, Sendable {
        public var source: String
        public var target: String
        public var type: String?
        public var description: String?
    }
    public var nodes: [Node]
    public var edges: [Edge]
    public var tour: [TourStep]

    public init(nodes: [Node], edges: [Edge], tour: [TourStep] = []) { (self.nodes, self.edges, self.tour) = (nodes, edges, tour) }

    enum CodingKeys: String, CodingKey { case nodes, edges, tour }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = (try? c.decodeIfPresent([Node].self, forKey: .nodes)) ?? []
        edges = (try? c.decodeIfPresent([Edge].self, forKey: .edges)) ?? []
        tour = (try? c.decodeIfPresent([TourStep].self, forKey: .tour)) ?? []
    }

    /// Only the ideas from these chapters, the links between them, and tour steps that still have ideas.
    public func only(chapters: Set<Int>) -> KnowledgeGraph {
        let kept = nodes.filter { $0.chapter.map(chapters.contains) ?? false }
        let ids = Set(kept.map(\.id))
        return KnowledgeGraph(
            nodes: kept,
            edges: edges.filter { ids.contains($0.source) && ids.contains($0.target) },
            tour: tour.map { TourStep(title: $0.title, description: $0.description, nodeIds: $0.nodeIds.filter(ids.contains)) }
                .filter { !$0.nodeIds.isEmpty }
        )
    }

    /// One chapter's concept graph, with that chapter's own guided tour (its ids carry the "cN:" prefix in the book map).
    public func chapter(_ n: Int, tour chapterTour: [TourStep]) -> KnowledgeGraph {
        var graph = only(chapters: [n])
        graph.tour = chapterTour.map { TourStep(title: $0.title, description: $0.description, nodeIds: $0.nodeIds.map { "c\(n):\($0)" }) }
            .map { step in TourStep(title: step.title, description: step.description, nodeIds: step.nodeIds.filter { id in graph.nodes.contains { $0.id == id } }) }
            .filter { !$0.nodeIds.isEmpty }
        return graph
    }
}

public struct Book: Decodable, Equatable, Sendable {
    public var title: String
    public var source: String
    public var dryRun: Bool
    public var engine: String
    public var model: String
    public var chapters: [Chapter]
    public var graph: KnowledgeGraph

    enum CodingKeys: String, CodingKey { case title, source, dryRun, engine, model, chapters, graph }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Your book"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "notebooklm"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        graph = try c.decodeIfPresent(KnowledgeGraph.self, forKey: .graph)
            ?? KnowledgeGraph.empty
    }
}

extension KnowledgeGraph {
    static let empty = try! JSONDecoder().decode(KnowledgeGraph.self, from: Data("{}".utf8))
}
