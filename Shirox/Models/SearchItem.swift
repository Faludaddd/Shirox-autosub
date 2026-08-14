import Foundation

struct SearchItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let image: String
    let href: String

    static func == (lhs: SearchItem, rhs: SearchItem) -> Bool {
        lhs.id == rhs.id && lhs.href == rhs.href
    }
}
