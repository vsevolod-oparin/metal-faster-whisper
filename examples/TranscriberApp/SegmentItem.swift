import Foundation

struct SegmentItem: Identifiable {
    let id: Int
    let start: Float
    let end: Float
    let text: String
    let words: [WordItem]?
}

struct WordItem: Identifiable {
    let id = UUID()
    let start: Float
    let end: Float
    let word: String
    let probability: Float
}
