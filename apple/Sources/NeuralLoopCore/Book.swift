// The parts of book.json (today's book-data payload) that the core logic needs. The app decodes the full model.

public struct Card: Codable, Equatable, Sendable {
    public var front: String
    public var back: String
    public init(front: String, back: String) { (self.front, self.back) = (front, back) }
}

public struct Chapter: Codable, Equatable, Sendable {
    public var n: Int
    public var title: String
    public var cards: [Card]
    public init(n: Int, title: String = "", cards: [Card] = []) { (self.n, self.title, self.cards) = (n, title, cards) }

    enum CodingKeys: String, CodingKey { case n, title, cards }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decode(Int.self, forKey: .n)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cards = try c.decodeIfPresent([Card].self, forKey: .cards) ?? []
    }
}
