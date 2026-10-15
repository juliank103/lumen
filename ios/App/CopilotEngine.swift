import Foundation
import JavaScriptCore

struct Assessment: Decodable {
    let status: String
    let totalMilliMiles: Int?
    let dollarsPerTotalMile: Double?
    let mileageShortfallCents: Int?
    let minutesLow: Int?
    let minutesHigh: Int?
    let reasons: [String]
    let notes: [String]
}

struct OfferCard: Decodable, Identifiable {
    let offerId: String
    let platform: String
    let payCents: Int?
    let status: String
    let assessment: Assessment
    var id: String { offerId }
}

struct ShiftCard: Decodable, Identifiable {
    let shiftId: String
    let finalPayCents: Int
    let actualMilliMiles: Int
    let elapsedMinutes: Double
    let finalPayHourlyCents: Double?
    var id: String { shiftId }
}

struct Snapshot: Decodable {
    let mode: String
    let offers: [OfferCard]
    let shifts: [ShiftCard]
}

enum CopilotEngine {
    enum EngineError: LocalizedError {
        case missingResource, invalidFixture, evaluation(String)
        var errorDescription: String? {
            switch self {
            case .missingResource: return "The shared engine or sample replay is missing from the app bundle."
            case .invalidFixture: return "The sample replay is invalid."
            case .evaluation(let message): return message
            }
        }
    }

    static func sampleSnapshot() throws -> Snapshot {
        guard let codeURL = Bundle.main.url(forResource: "copilot", withExtension: "js"),
              let fixtureURL = Bundle.main.url(forResource: "sample-shift", withExtension: "json"),
              let context = JSContext() else { throw EngineError.missingResource }
        let code = try String(contentsOf: codeURL, encoding: .utf8)
        let fixtureData = try Data(contentsOf: fixtureURL)
        guard let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              fixture["kind"] as? String == "synthetic_fixture",
              let events = fixture["events"] as? [[String: Any]],
              let now = fixture["now"] as? String else { throw EngineError.invalidFixture }
        let data = try JSONSerialization.data(withJSONObject: events)
        guard let json = String(data: data, encoding: .utf8) else { throw EngineError.invalidFixture }
        var engineError: String?
        context.exceptionHandler = { _, exception in engineError = exception?.toString() ?? "Engine failed" }
        context.evaluateScript(code)
        if let error = engineError { throw EngineError.evaluation(error) }
        let function = context.objectForKeyedSubscript("Copilot")?.objectForKeyedSubscript("snapshotJSON")
        let output = function?.call(withArguments: [json, "{}", now])
        if let error = engineError { throw EngineError.evaluation(error) }
        guard let text = output?.toString(), let outputData = text.data(using: .utf8) else { throw EngineError.invalidFixture }
        return try JSONDecoder().decode(Snapshot.self, from: outputData)
    }
}
