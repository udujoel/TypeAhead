import SwiftData
import Foundation

@Model
final class HistoryRecord {
    var acceptedText: String
    var appName: String
    var timestamp: Date

    init(acceptedText: String, appName: String, timestamp: Date = .now) {
        self.acceptedText = acceptedText
        self.appName = appName
        self.timestamp = timestamp
    }
}
