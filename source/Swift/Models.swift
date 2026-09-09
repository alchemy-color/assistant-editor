import SwiftUI

// MARK: - Global Text Scaling (CMD+/CMD-)

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var appTextScale: Double {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

struct ScaledFont: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let style: Font.TextStyle
    let design: Font.Design
    let monospacedDigit: Bool
    var weightOverride: Font.Weight? = nil

    func body(content: Content) -> some View {
        var font = Font.system(size: baseSize(for: style) * CGFloat(max(scale, 0.5)),
                               weight: weightOverride ?? weight(for: style),
                               design: design)
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }

    private func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title:      return 22
        case .title2:     return 20
        case .title3:     return 15
        case .headline:   return 13
        case .subheadline: return 13
        case .body:       return 13
        case .callout:    return 11
        case .footnote:   return 11
        case .caption:    return 11
        case .caption2:   return 10
        @unknown default: return 13
        }
    }

    private func weight(for style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline, .title, .title2, .title3, .largeTitle: return .semibold
        default: return .regular
        }
    }
}

struct ScaledFontSize: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let size: CGFloat
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * CGFloat(max(scale, 0.5)), design: design))
    }
}

extension View {
    func scaledFont(_ style: Font.TextStyle, design: Font.Design = .default, monospacedDigit: Bool = false, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(style: style, design: design, monospacedDigit: monospacedDigit, weightOverride: weight))
    }
    func scaledFontSize(_ size: CGFloat, design: Font.Design = .default) -> some View {
        modifier(ScaledFontSize(size: size, design: design))
    }
}

// MARK: - Marker (from YAML)

struct SummaryMarker: Codable, Identifiable, Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: SummaryMarker, rhs: SummaryMarker) -> Bool {
        lhs.id == rhs.id
    }
    var id: String { "\(start_s)-\(name)" }
    var start_s: Double
    var end_s: Double
    var theme: String
    var color: String
    var name: String
    var notes: String

    var frameId: Int { Int(round(start_s * 25)) }
    var durationFrames: Int { max(1, Int(round((end_s - start_s) * 25))) }
    var timecode: String { secondsToTc(start_s) }
    func frameId(fps: Double) -> Int { Int(round(start_s * (fps > 0 ? fps : 25.0))) }
    func durationFrames(fps: Double) -> Int { max(1, Int(round((end_s - start_s) * (fps > 0 ? fps : 25.0)))) }
}

// MARK: - Summary Document (one YAML file)

struct SummaryDocument: Codable, Identifiable, Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: SummaryDocument, rhs: SummaryDocument) -> Bool {
        lhs.id == rhs.id
    }
    var id: String { "\(sourceFolder ?? "")/\(title)" }
    let title: String
    let location: String
    let date: String
    let markers: [SummaryMarker]
    var speakers: [String]?
    var sourceFolder: String?
    var sourceFile: String?
}

// MARK: - Clip / Group (for Resolve writing)

struct MarkerGroup: Codable {
    var start_s: Double
    var duration_s: Double
    var text: String
    var summary: String
    var keywords: String
    var color: String
}

// MARK: - Timeline Creation (Create Tab)

struct TimelineEntry: Codable {
    var start_s: Double
    var end_s: Double
    var name: String
    var notes: String
    var color: String
    var interview: String
    var folder: String
    var location: String
    var sourceFile: String?
    var groupId: Int
    var subtitleText: String?
    var speaker: String?
}

struct BeatSpanMarker: Codable {
    var name: String
    var note: String
    var start_s: Double
    var end_s: Double
    var color: String
}

enum MarkerMode: String, CaseIterable, Codable {
    case beats = "Beat structure"
    case clips = "Clip descriptions"
}

struct TimelineRequest: Codable {
    var name: String
    var markers: [TimelineEntry]
    var groupGapFrames: Int
    var addSubtitles: Bool
    var srtFolder: String?
    var beatMarkers: [BeatSpanMarker]?
    var addClipMarkers: Bool?
}

// MARK: - Subtitle Sentence (from SRT)

struct SubtitleEntry: Identifiable, Codable {
    var id: String { "\(sourceFile)/\(start_s)" }
    let sourceFile: String
    let interview: String
    let folder: String
    let location: String
    let start_s: Double
    let end_s: Double
    let speaker: String
    let text: String

    var timecode: String { secondsToTc(start_s) }
    var duration: TimeInterval { end_s - start_s }
}

struct SubSearchHit: Identifiable {
    var id: String { entry.id }
    let entry: SubtitleEntry
    var similarity: Double = 0
}

// MARK: - Constants

// Default oMLX model is resolved from OMLXClient.defaultModel at runtime.
// OLLAMA_MODEL kept as a deprecated shim so any third-party scripts referencing
// the symbol do not fail to compile; new code should read selectedModel /
@available(*, deprecated, message: "Use OMLXClient.defaultModel / selectedModel instead")
let OLLAMA_MODEL = OMLXClient.defaultModel

// MARK: - Helpers

func secondsToTc(_ s: Double) -> String {
    let h = Int(s) / 3600
    let m = (Int(s) % 3600) / 60
    let sec = s.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%02d:%06.3f", h, m, sec).replacingOccurrences(of: ".", with: ",")
}

func secondsToEdfTc(_ s: Double, fps: Double) -> String {
    // Frame-accurate: compute total frames first so fractional rollover can't leak
    let safeFps = fps > 0 ? fps : 25.0
    let totalFrames = max(0, Int(round(s * safeFps)))
    let frame = totalFrames % Int(safeFps.rounded())
    let totalSeconds = totalFrames / Int(safeFps.rounded())
    let h = totalSeconds / 3600
    let m = (totalSeconds % 3600) / 60
    let sec = totalSeconds % 60
    return String(format: "%02d:%02d:%02d:%02d", h, m, sec, frame)
}


func sanitizeName(_ s: String) -> String {
    s.replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: " ", with: "_")
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return f.string(from: Date())
}

func colorForName(_ name: String) -> Color {
    switch name.lowercased() {
    case "tan":    return Color(red: 0.76, green: 0.60, blue: 0.42)
    case "orange": return .orange
    case "cyan":   return .cyan
    case "mint":   return Color(red: 0.60, green: 0.98, blue: 0.60)
    case "green":  return .green
    case "rose":   return .pink
    case "lemon":  return Color(red: 1.0, green: 1.0, blue: 0.4)
    case "yellow": return .yellow
    case "sky":    return Color(red: 0.4, green: 0.7, blue: 1.0)
    default:       return .secondary
    }
}

func similarityLabel(_ similarity: Double) -> String {
    similarity > 0 ? String(format: "%.0f%%", similarity * 100) : ""
}

// MARK: - Shared Progress State

class AppProgress: ObservableObject {
    @Published var isActive = false
    @Published var message = ""
    @Published var progress: Double?  // nil = indeterminate, 0...1 = determinate

    func start(_ msg: String) {
        message = msg
        progress = 0
        isActive = true
    }

    func update(_ msg: String, progress p: Double? = nil) {
        message = msg
        if let p { progress = p }
    }

    func finish(_ msg: String = "") {
        DispatchQueue.main.async {
            if !msg.isEmpty { self.message = msg }
            self.isActive = false
            self.progress = nil
        }
    }
}

// MARK: - Sync by Transcript

struct SyncClipResult: Identifiable, Codable {
    var id: String { clipName }
    let clipName: String
    let clipPath: String
    var error: String?
    let syncTimeS: Double
    let confidence: Double
    let matchedPhrases: [String]
    let totalPhrasesChecked: Int
    let clipDurationS: Double
    let fieldRecorderDurationS: Double
    var sequentialOk: Bool?
}

struct SyncResponse: Codable {
    var error: String?
    let results: [SyncClipResult]?
    var sequentialOk: Bool?
}

struct SyncRequest: Codable {
    let field_recorder: String
    let clips: [String]
}

struct SyncBuildPlacement: Codable {
    let clip: String
    let syncTc: String
    let track: Int
}

struct SyncBuildResult: Codable {
    let status: String
    let timelineName: String?
    let frDurationS: Double?
    let placed: [SyncBuildPlacement]?
    let markersOnly: [SyncBuildFailure]?
    var error: String?
}

struct SyncBuildFailure: Codable {
    let clip: String
    let reason: String
}

// MARK: - YouTube Summary Cache (per doc, per length)

struct SummaryCache: Codable {
    var doc: String
    var texts: [String: String]
    var times: [String: Double]
}

// MARK: - AI Edit Tab

struct ParsedBeat: Codable, Identifiable {
    var id = UUID()
    var title: String
    var description: String
    var searchQueries: [String]
    var targetDuration: Double?
    var mood: String?

    enum CodingKeys: String, CodingKey {
        case title, description, searchQueries, targetDuration, mood
    }

    init(title: String, description: String, searchQueries: [String], targetDuration: Double? = nil, mood: String? = nil) {
        self.title = title
        self.description = description
        self.searchQueries = searchQueries
        self.targetDuration = targetDuration
        self.mood = mood
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        searchQueries = try c.decode([String].self, forKey: .searchQueries)
        targetDuration = try c.decodeIfPresent(Double.self, forKey: .targetDuration)
        mood = try c.decodeIfPresent(String.self, forKey: .mood)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(searchQueries, forKey: .searchQueries)
        try c.encodeIfPresent(targetDuration, forKey: .targetDuration)
        try c.encodeIfPresent(mood, forKey: .mood)
    }
}

struct ScriptParseResult: Codable {
    var beats: [ParsedBeat]
    var estimatedDuration: Double?
    var title: String?
}

struct ScriptBeat: Codable, Identifiable {
    var id = UUID()
    var index: Int
    var title: String
    var description: String
    var searchQueries: [String]
    var targetDuration: Double?
    var mood: String?
    var clips: [BeatClip]
}

struct BeatClip: Identifiable, Codable {
    var id: String
    var sourceFile: String
    var sourceRoot: String? = nil   // owning top-level folder (for Resolve media matching)
    var interview: String
    var speaker: String
    var start_s: Double
    var end_s: Double
    var text: String
    var matchScore: Double
    var matchReason: String
    var included: Bool
    var isContext: Bool
}

import Combine

final class LLMPerf: ObservableObject {
    static let shared = LLMPerf()
    @Published var tokensPerSec: Double?
    @Published var evalCount = 0
    @Published var evalMs: Double = 0

    @discardableResult
    func record(_ json: [String: Any]) -> Bool {
        guard let c = json["eval_count"] as? Int, c > 0,
              let d = json["eval_duration"] as? Double, d > 0 else { return false }
        let tps = Double(c) / (d / 1_000_000_000)
        DispatchQueue.main.async {
            self.tokensPerSec = tps
            self.evalCount = c
            self.evalMs = d / 1_000_000
        }
        return true
    }

    /// Record tok/s from an oMLX (OpenAI-style) call. `timeSeconds` is the
    /// wall-clock generation time for the completion tokens.
    @discardableResult
    func recordOmlx(completionTokens: Int, timeSeconds: Double?) -> Bool {
        guard completionTokens > 0 else { return false }
        let tps = timeSeconds.map { Double(completionTokens) / max($0, 0.0001) }
        DispatchQueue.main.async {
            if let tps {
                self.tokensPerSec = tps
            }
            self.evalCount = completionTokens
            if let timeSeconds {
                self.evalMs = timeSeconds * 1000
            }
        }
        return true
    }
}
