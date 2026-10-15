import Foundation

// Only aggregate diagnostics cross the extension boundary. No screen text or images.
struct ProbeStatus: Codable {
    var schemaVersion = 1
    var sessionID: String
    var status: String
    var updatedAt: Date
    var lastAnalyzedAt: Date?
    var framesAnalyzed: Int
    var recognizedLineCount: Int
    var priceTokenCount: Int
    var distanceTokenCount: Int
    var offersRead = 0
    var returnLookupsFailed = 0
    var returnDestination: String?
    var failureCode: String?

    static func fresh() -> ProbeStatus {
        ProbeStatus(sessionID: UUID().uuidString, status: "starting", updatedAt: Date(),
                    framesAnalyzed: 0, recognizedLineCount: 0, priceTokenCount: 0, distanceTokenCount: 0)
    }
}

enum ProbeStorage {
    static func url() throws -> URL {
        try AppGroup.container().appendingPathComponent("capture-probe-status.json")
    }

    static func write(_ status: ProbeStatus) throws {
        let location = try url()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(status).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read() throws -> ProbeStatus? {
        let location = try url()
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let data = try Data(contentsOf: location)
        guard data.count < 16_384 else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A file from an older build may lack newer fields; treat it as no status yet rather than broken storage.
        return try? decoder.decode(ProbeStatus.self, from: data)
    }
}
