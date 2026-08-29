import Foundation

struct NumberedStemGroup: Identifiable {
    var id: UUID { group.id }
    let index: Int
    let group: StemGroup
}
