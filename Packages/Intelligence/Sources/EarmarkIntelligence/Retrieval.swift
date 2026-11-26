import AppCore
import Foundation
import NaturalLanguage

/// A passage the chat can be grounded in: a stretch of transcript, a block of notes, or one page of an attached file.
struct TextChunk: Sendable, Equatable {
    var text: String
    var source: ChatSource
    /// Position in reading order (transcript time, or a large offset for notes and pages).
    var order: Double
    var tokens: Int { TokenEstimate.tokens(text) }
}

/// On-device sentence vectors (NaturalLanguage) for paraphrased questions; nil where the language has no embedding.
protocol SentenceEmbedding: Sendable {
    func vector(for text: String) -> [Double]?
}

struct NaturalLanguageEmbedding: SentenceEmbedding, @unchecked Sendable {
    private let embedding: NLEmbedding?
    init(languageCode: String?) {
        let language = languageCode.map { NLLanguage(rawValue: $0) } ?? .english
        embedding = NLEmbedding.sentenceEmbedding(for: language)
    }
    var isAvailable: Bool { embedding != nil }
    func vector(for text: String) -> [Double]? { embedding?.vector(for: text) }
}

enum Retriever {
    /// Light stemming so "decided", "decision" and "decisions" meet: tokens longer than six characters are cut to six.
    static func stem(_ word: String) -> String {
        if word.contains(where: \.isNumber) { return word }
        var w = word
        if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
        return w.count > 6 ? String(w.prefix(6)) : w
    }

    static func terms(_ text: String) -> [String] { Words.content(text).map(stem) }

    /// The best chunks for `question`, BM25 on stems, re-ranked by sentence embeddings when available.
    static func rank(question: String, chunks: [TextChunk], limit: Int, embedding: (any SentenceEmbedding)? = nil) -> [TextChunk] {
        guard !chunks.isEmpty else { return [] }
        let queryTerms = Set(terms(question))
        let docs = chunks.map { terms($0.text) }
        let avg = max(1, Double(docs.map(\.count).reduce(0, +)) / Double(docs.count))
        var df: [String: Int] = [:]
        for doc in docs { for term in Set(doc) { df[term, default: 0] += 1 } }
        let n = Double(chunks.count)
        var scores = Array(repeating: 0.0, count: chunks.count)
        for (i, doc) in docs.enumerated() {
            var tf: [String: Int] = [:]
            for term in doc { tf[term, default: 0] += 1 }
            for term in queryTerms {
                guard let f = tf[term] else { continue }
                let idf = log(1 + (n - Double(df[term] ?? 0) + 0.5) / (Double(df[term] ?? 0) + 0.5))
                let freq = Double(f)
                scores[i] += idf * (freq * 2.5) / (freq + 1.5 * (0.25 + 0.75 * Double(doc.count) / avg))
            }
        }
        if let embedding, let q = embedding.vector(for: question) {
            let maxBM = scores.max() ?? 0
            // Re-rank the lexical candidates; when nothing matched lexically, look at (a capped number of) all chunks.
            let ranked = Array(scores.indices).sorted { scores[$0] > scores[$1] }
            let candidates: [Int] = maxBM > 0 ? Array(ranked.prefix(60)) : Array(ranked.prefix(600))
            for i in candidates {
                guard let v = embedding.vector(for: String(chunks[i].text.prefix(600))) else { continue }
                let cosine = cosineSimilarity(q, v)
                scores[i] = (maxBM > 0 ? scores[i] / maxBM : 0) * 0.7 + max(0, cosine) * 0.3
            }
        }
        let order = Array(scores.indices).filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] }
        return order.prefix(limit).map { chunks[$0] }
    }

    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}
