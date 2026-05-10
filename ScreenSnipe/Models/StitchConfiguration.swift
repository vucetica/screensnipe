import Foundation

struct StitchConfiguration: Sendable {
    var items: [LibraryEntry]
    var pauseDurationSeconds: Double
    var imageDurationSeconds: Double
}
