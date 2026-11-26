import Foundation

struct QueuedMessage: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var attachments: [ComposerAttachment]?
}

enum PiInputMode: String, Decodable {
    case waiting, steer, compacting
}
