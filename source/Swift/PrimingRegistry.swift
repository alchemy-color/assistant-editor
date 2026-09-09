import Foundation
import SwiftUI

// MARK: - Priming Registry
// One independent, user-editable prompt per LLM step.
// What you see in each window is exactly what the model receives.

struct PrimingStage: Identifiable {
    let key: String
    let title: String
    let icon: String
    let firesWhen: String
    let defaultText: String

    var id: String { key }

    func load() -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultText
    }

    func isCustomized() -> Bool {
        load() != defaultText
    }

    func reset() {
        UserDefaults.standard.set(defaultText, forKey: key)
    }
}

// MARK: - Priming Presets

/// A named bundle of priming texts scoped to one documentary project,
/// stored as `_priming_presets.yaml` next to `_project.yaml`.
struct PrimingPreset {
    let name: String
    let basedOn: String
    let stages: [String: String]

    /// Parses the emitted subset of YAML:
    /// presets:\n  - name: "X"\n    basedOn: "..."\n    stages:\n      key: |\n        <8-space block>
    static func parse(_ yaml: String) -> [PrimingPreset] {
        var presets: [PrimingPreset] = []
        var currentName = ""
        var currentBasedOn = ""
        var stages: [String: String] = [:]
        var stageKey = ""
        var blockLines: [String] = []

        func flushStage() {
            guard !stageKey.isEmpty else { return }
            while blockLines.last?.isEmpty == true { blockLines.removeLast() }
            if !blockLines.isEmpty { stages[stageKey] = blockLines.joined(separator: "\n") }
            stageKey = ""
            blockLines = []
        }
        func flushPreset() {
            flushStage()
            guard !currentName.isEmpty else { return }
            presets.append(PrimingPreset(name: currentName, basedOn: currentBasedOn, stages: stages))
            currentName = ""
            currentBasedOn = ""
            stages = [:]
        }

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Stage block collection
            if !stageKey.isEmpty {
                if trimmed.isEmpty || line.hasPrefix("        ") {
                    blockLines.append(line.hasPrefix("        ") ? String(line.dropFirst(8)) : "")
                    continue
                }
                flushStage()
            }

            if trimmed.hasPrefix("- name:") {
                flushPreset()
                currentName = quotedValue(trimmed)
            } else if line.hasPrefix("    basedOn:") {
                currentBasedOn = quotedValue(trimmed)
            } else if trimmed == "stages:" || line.hasPrefix("    stages:") {
                continue
            } else if line.hasPrefix("      "), trimmed.hasSuffix(": |") {
                stageKey = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespaces)
                blockLines = []
            }
        }
        flushPreset()
        return presets
    }

    private static func quotedValue(_ s: String) -> String {
        var v = s
        if let i = v.firstIndex(of: ":") { v = String(v[v.index(after: i)...]).trimmingCharacters(in: .whitespaces) }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return v
    }

    /// YAML-escapes a value written inside double quotes.
    private static func yamlQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Serializes a full set of presets back into the same subset of YAML the
    /// parser reads: an 8-space-indented block scalar per stage. Stage order is
    /// stable (sorted by key) so round-trips are diff-clean.
    static func emit(_ presets: [PrimingPreset]) -> String {
        var lines = ["presets:"]
        for preset in presets {
            lines.append("  - name: \"\(yamlQuote(preset.name))\"")
            if !preset.basedOn.isEmpty {
                lines.append("    basedOn: \"\(yamlQuote(preset.basedOn))\"")
            }
            lines.append("    stages:")
            for key in preset.stages.keys.sorted() where !(preset.stages[key]?.isEmpty ?? true) {
                lines.append("      \(key): |")
                for line in (preset.stages[key] ?? "").components(separatedBy: "\n") {
                    lines.append("        " + line)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum PrimingPresetStore {

    /// Legacy (pre-v1.21) name, still read as a fallback.
    static let legacyFileName = "_priming_presets.yaml"
    static let folderKey = "primingPresetFolder"

    /// Canonical preset filename for a folder, named after the folder:
    /// `Convivium_priming_preset.yaml` inside the Convivium folder.
    static func presetFileName(for folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        return "\(name)_priming_preset.yaml"
    }

    /// Acknowledges the per-project file, a manual rename, or the legacy name.
    /// Preference order inside `folder`:
    /// 1. exact canonical `<folderName>_priming_preset.yaml`
    /// 2. a single `*_priming_preset.yaml`
    /// 3. legacy `_priming_presets.yaml`
    static func findPresetFile(in folder: String) -> String? {
        let fm = FileManager.default
        let dir = folder as NSString
        guard let items = try? fm.contentsOfDirectory(atPath: folder) else { return nil }

        let canonical = presetFileName(for: folder)
        let canonicalPath = dir.appendingPathComponent(canonical)
        if items.contains(canonical), fm.fileExists(atPath: canonicalPath) {
            return canonicalPath
        }

        let candidates = items.filter { $0.hasSuffix("_priming_preset.yaml") && !$0.hasPrefix(".") }
        if candidates.count == 1 {
            return dir.appendingPathComponent(candidates[0])
        }

        let legacy = dir.appendingPathComponent(legacyFileName)
        if fm.fileExists(atPath: legacy) { return legacy }
        return nil
    }

    /// The path presets should be written to for a folder: the existing found
    /// file (acknowledging a rename or the legacy name), else the canonical one.
    static func presetWriteTarget(for folder: String) -> String {
        findPresetFile(in: folder) ?? (folder as NSString).appendingPathComponent(presetFileName(for: folder))
    }

    /// Roots to scan: the dedicated preset folder when set,
    /// otherwise the Source Material roots.
    static func scanRoots() -> [String] {
        if let dedicated = UserDefaults.standard.string(forKey: folderKey),
           !dedicated.isEmpty {
            return [dedicated]
        }
        guard let data = UserDefaults.standard.string(forKey: "sourceMaterialFolders")?.data(using: .utf8),
              let roots = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return roots
    }

    /// Scans roots for preset files.
    /// Returns tuples of (displayName, name, parsed preset).
    static func scan() -> [(label: String, name: String, preset: PrimingPreset)] {
        var out: [(String, String, PrimingPreset)] = []
        for root in scanRoots() {
            let url = URL(fileURLWithPath: presetWriteTarget(for: root))
            guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for p in PrimingPreset.parse(yaml) where !p.stages.isEmpty {
                out.append(((root as NSString).lastPathComponent, p.name, p))
            }
        }
        return out
    }

    /// Writes every provided stage into its UserDefaults slot.
    static func apply(_ preset: PrimingPreset) {
        for stage in PrimingRegistry.stages {
            if let text = preset.stages[stage.key], !text.isEmpty {
                UserDefaults.standard.set(text, forKey: stage.key)
            }
        }
        UserDefaults.standard.set(preset.name, forKey: "activePrimingPreset")
    }

    /// Removes all stage overrides — factory default texts take over again.
    static func revertToFactory() {
        for stage in PrimingRegistry.stages {
            UserDefaults.standard.removeObject(forKey: stage.key)
        }
        UserDefaults.standard.set("", forKey: "activePrimingPreset")
    }

    /// The single folder presets are written to: the dedicated preset folder
    /// when set, else the first Source Material root. Returns nil if no folder
    /// is configured (caller should prompt for one).
    static func writeFolder() -> String? {
        if let dedicated = UserDefaults.standard.string(forKey: folderKey), !dedicated.isEmpty {
            return dedicated
        }
        guard let data = UserDefaults.standard.string(forKey: "sourceMaterialFolders")?.data(using: .utf8),
              let roots = try? JSONDecoder().decode([String].self, from: data),
              let first = roots.first else { return nil }
        return first
    }

    /// Reads the presets currently stored in a given root folder (or []).
    private static func presets(in root: String) -> [PrimingPreset] {
        let url = URL(fileURLWithPath: presetWriteTarget(for: root))
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return PrimingPreset.parse(yaml)
    }

    /// Writes a set of presets to `root/<folderName>_priming_preset.yaml` (or
    /// the acknowledged existing file) atomically.
    private static func write(_ presets: [PrimingPreset], to root: String) throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: presetWriteTarget(for: root))
        let text = PrimingPreset.emit(presets)
        let tmp = url.appendingPathComponent("_tmp")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
    }

    /// Captures the current stage texts (as edited in the Priming window and
    /// held in UserDefaults) into a new named preset, saved to disk.
    /// Returns the active write folder (nil → caller must choose one).
    @discardableResult
    static func save(name: String, basedOn: String = "") -> String? {
        guard let root = writeFolder() else { return nil }
        var stages: [String: String] = [:]
        for stage in PrimingRegistry.stages {
            stages[stage.key] = stage.load()
        }
        var presets = presets(in: root)
        presets.removeAll { $0.name == name }   // overwrite same name
        presets.append(PrimingPreset(name: name, basedOn: basedOn, stages: stages))
        try? write(presets, to: root)
        return root
    }

    /// Removes a named preset from disk. Returns the root that held it, or nil.
    @discardableResult
    static func delete(name: String) -> String? {
        guard let root = writeFolder() else { return nil }
        var presets = presets(in: root)
        let before = presets.count
        presets.removeAll { $0.name == name }
        guard presets.count != before else { return nil }
        try? write(presets, to: root)
        return root
    }
}

enum PrimingRegistry {

    static let stages: [PrimingStage] = [
        projectAnalysis,
        chaptersSynopsis,
        searchInterpretation,
        transcriptChat,
        promptSort,
        scriptParsing,
        clipSelection,
        flowReview,
        youTubeSummary
    ]

    static func stage(for key: String) -> PrimingStage? {
        stages.first { $0.key == key }
    }

    // MARK: 1. Project Analysis

    static let projectAnalysis = PrimingStage(
        key: "priming_projectAnalysis",
        title: "Project Analysis",
        icon: "square.stack.3d.up",
        firesWhen: "Analyze / Regenerate Themes in Project Setup. Scans folders and extracts themes, keywords, weights, and speaker stats into _project.yaml."
    ,
        defaultText: """
        You are an assistant editor for documentary and unscripted film post-production analyzing a body of interview material.

        Your job: identify the topic areas that organize this footage so the editor can prioritize it.

        THEMES
        Extract 5-8 themes from the material.

        - Name themes as topic areas the editor would use to sort scenes: "Governance & Policy", "Culinary Identity", "Family Legacy", "Landscape & Terroir"
        - Keywords must be concrete terms that actually appear in the material — not abstract labels
        - Cover the full breadth of the material; avoid overlapping themes
        - Ground themes in what the speakers actually discuss, not what you expect the project to be about

        WEIGHING
        Assign each theme an initial weight (0-1). Weights tell the chapter generator how to allocate screen time: a theme at 0.30 should produce roughly 30% of total chapter duration. Set the initial balance from how much material supports each theme; the editor fine-tunes it afterwards.

        Ground everything in what was actually said in the transcripts. Use speakers' own terminology for keyword candidates.
        """)

    // MARK: 2. Chapters & Synopsis

    static let chaptersSynopsis = PrimingStage(
        key: "priming_chaptersSynopsis",
        title: "Chapters & Synopsis",
        icon: "flag.2.crossed",
        firesWhen: "Processing interviews in Timeline Assist — generates _chapters.yaml markers and _synopsis.txt via process_srt.py."
    ,
        defaultText: """
        You are an assistant editor for documentary and unscripted film post-production. Your output serves the edit — not the audience, not a reviewer. Every line helps the editor see what is in the interview and decide what to do with it.

        CHAPTERS
        Chapters are timed segments of the interview mapped to themes. Two controls shape them:

        - DENSITY controls how many chapters are created. Low density produces few, long chapters — best for overview edits. High density produces many short chapters — best for detailed scene-by-scene breakdowns.

        - VERBOSITY controls how detailed chapter notes are. Low verbosity produces brief labels. High verbosity produces full scene descriptions: who speaks, about what, with what emotional weight, what the audience sees and hears.

        When writing chapter notes, describe the scene, not the topic. "Two brothers arguing about harvest timing while walking through the vineyard" is useful. "Discussion about viticulture practices" is not.

        SYNOPSIS
        The synopsis is a detailed companion document. Someone who has not seen the footage should be able to read it and understand what was discussed, what was said about it, and why it matters to the edit.

        - LOW verbosity: a concise overview — the essential points
        - HIGH verbosity: comprehensive coverage with specific anecdotes, direct quotes, names, places, factual details from the transcript

        Follow the material's own structure and topic flow. Every subject section needs narrative prose grounded in the transcript — not just bullet points.

        RULES
        Ground everything in what was actually said. If a speaker names a person, a place, a technique — use that name. If they tell an anecdote — keep its details intact. Preserve the speaker's voice: technical terms, local names, unusual phrasing — keep them as spoken. Never invent a fact, attribute a statement, or generalize where the speaker was specific.
        """)

    // MARK: 3. Search Interpretation

    static let searchInterpretation = PrimingStage(
        key: "priming_searchInterpretation",
        title: "Search Interpretation",
        icon: "magnifyingglass",
        firesWhen: "Every Send in the Timeline Assist prompt bar — converts your natural-language query into FTS5 search keywords."
    ,
        defaultText: """
        Extract 2-5 comma-separated search keywords from the editor's request. Reply with keywords only, no explanation. If the input is already keywords, return them unchanged.

        This app searches interview subtitles and transcripts to assemble edit timelines in DaVinci Resolve:
        - SUBTITLES are short cues (2-10 seconds) — precise moments to cut into a timeline
        - TRANSCRIPTS are full paragraphs — thematic content and context

        Favor:
        - Specific multi-word phrases that appear in continuous speech (e.g. "harvest timing" not just "harvest")
        - Proper nouns and compound terms with original spelling ("Serra da Estrela", "Bairrada")
        - Domain-specific terminology from the project's theme vocabulary
        - Action-oriented phrases capturing what speakers actually say about a topic

        Avoid:
        - Single generic nouns that match too broadly ("wine", "people", "food")
        - Abstract concepts that don't appear verbatim ("sustainability", "tradition")
        - Splitting compound terms ("climate change" stays one phrase)
        """)

    // MARK: 4. Transcript Chat

    static let transcriptChat = PrimingStage(
        key: "priming_transcriptChat",
        title: "Transcript Chat",
        icon: "bubble.left.and.text.bubble.right",
        firesWhen: "Every message in the Transcript Intelligence tab — RAG chat over loaded interviews, chapters, and markers."
    ,
        defaultText: """
        You are an assistant editor helping build narrative from source material — interview transcripts, subtitle cues, chapter markers, and synopses.

        Help the editor find connections, patterns, and insights across sources. Reference specific speakers, timestamps, and documents. Suggest threads worth pulling. Be concise and substantive — do not fill space.

        Ground every claim in the provided context. Quote speakers when it strengthens the answer. If the context doesn't contain the answer, say so plainly instead of guessing.

        Never editorialize. You are not a critic or reviewer. You are an editor's tool — precise, grounded, invisible.
        """)

    // MARK: 5. Prompt Sort

    static let promptSort = PrimingStage(
        key: "priming_promptSort",
        title: "Prompt Sort",
        icon: "arrow.up.arrow.down",
        firesWhen: "Sort option 'Prompt' in Timeline Assist — reorders search results into narrative order using your query."
    ,
        defaultText: """
        Reorder the subtitle entries so they tell the most coherent narrative for the user's request.

        Consider logical progression: setup before payoff, cause before effect, general before specific. Keep entries by the same speaker together when the flow benefits.

        Return only the entry numbers in the new order as a comma-separated list. No explanation.
        """)

    // MARK: 6. AI Edit Script Parsing

    static let scriptParsing = PrimingStage(
        key: "priming_scriptParsing",
        title: "AI Edit · Parse Script",
        icon: "wand.and.stars",
        firesWhen: "Auto-fill from text button in AI Edit — breaks your treatment into beats with search queries."
    ,
        defaultText: """
        You are a documentary assistant editor. Given a script or treatment document, break it into sequential beats for a timeline.

        CORE RULES — beats describe editorial intent, never visuals:
        - Each beat = a narrative function (introduction, tension, practice, reflection, turn, conclusion…) \
        plus the TOPIC the material must speak about
        - FORBIDDEN in titles, descriptions, and queries: camera angles, shots, locations, b-roll, \
        drone/aerial, "talking head", "interview setup", "to camera", "footage of", "scene opens on"
        - If the script references chapter/marker names (e.g. "Viticulture: Vineyard"), keep them         out of searchQueries — write spoken phrases about what people SAY on that topic instead
        - If the script references chapter/marker names (e.g. "Viticulture: Vineyard"), keep them \
        out of searchQueries — write spoken phrases about what people SAY on that topic instead
        - searchQueries must be plain phrases a SPEAKER WOULD ACTUALLY SAY in an interview — \
        spoken language, not production language
        - Never invent facts. The material supplies content; you supply structure.
        - Vary narrative function across beats. Never emit mirror-image filler beats ("First winemaker…", \
        "Second winemaker…") that restate one idea with a different number.

        EXAMPLES

        Input: "Opening: sweeping shots of the Douro valley at dawn. Then the three families introduce themselves and their estates."

        GOOD beats (visuals ignored; speech topics extracted):
        1. title: "Roots in the valley" — each family tells how they came to work this land.
           queries: ["how it all started", "my grandfather planted", "we never left"]
        2. title: "What the estate means" — what the winery personally means to each speaker.
           queries: ["this place is", "our whole life", "more than a business"]

        BAD output (never produce):
        - title "Drone opening over vineyard" ← invented visual
        - query "winemaker talking to camera" ← production language; nobody says this
        - title "First winemaker introduction" ← mirror-image filler; nothing searchable

        For each beat return: title (5-8 words), description (topic-grounded), \
        searchQueries (2-4 spoken-language phrases), targetDuration (seconds; 5-15 typical, \
        longer for key story moments), mood (e.g. "intimate", "tense", "reflective", "joyful").

        Return JSON matching the required schema: top-level title, estimatedDuration, beats[]. \
        6-15 beats is typical. No text outside the JSON object.
        """)

    // MARK: 6b. AI Edit Clip Selection

    static let clipSelection = PrimingStage(
        key: "priming_clipSelection",
        title: "AI Edit · Clip Selection",
        icon: "hand.pick",
        firesWhen: "Find Clips — chooses which real transcript passages serve each beat. Candidates come from the material; you pick what fits."
    ,
        defaultText: """
        You are a documentary assistant editor selecting footage for one beat of an edit.

        You receive: the beat's editorial intent, synopsis excerpts of the interviews, \
        and numbered candidate passages taken verbatim from interview transcripts.

        Select the passages (by index) that best serve the beat's intent:
        - Prefer concrete, specific statements over vague references
        - Prefer passages where a speaker directly addresses the beat's topic
        - A strong anecdote beats a generic mention
        - GOOD pick: a specific story with names, places or numbers ("we lost half the harvest in 2021")
        - BAD pick: a vague aside that merely shares a keyword ("wine is very old")
        - Do NOT select a passage just because it shares a word — it must serve the meaning

        Return ONLY JSON (no markdown fences):
        {"selections": [{"index": <candidate number>, "reason": "<one line: why this passage serves the beat>"}]}

        Select at most 5. Fewer is fine — return {"selections": []} if nothing truly serves the beat.
        """)

    // MARK: 7. AI Edit Flow Review

    static let flowReview = PrimingStage(
        key: "priming_flowReview",
        title: "AI Edit · Flow Review",
        icon: "text.badge.checkmark",
        firesWhen: "Review Flow button in AI Edit — reviews the selected clip sequence against the script. Language judgment only; all timing math stays deterministic."
    ,
        defaultText: """
        You are a documentary editor reviewing a rough assembly. You receive the script/treatment and the currently selected interview clips in timeline order, grouped by beat.

        Review ONLY the narrative flow of this sequence:
        - Do consecutive clips flow logically? Flag jarring topic jumps between speakers/beats.
        - Is any content redundant or repetitive across clips?
        - Are there obvious narrative gaps relative to the script's intent for that beat?
        - Does each beat's clips actually support what the beat claims to be about?

        Do NOT comment on technical issues, timecodes, audio, or durations.
        Be specific and concise — one line per issue.

        Return ONLY a JSON array (no markdown fences, no commentary):
        [
          {"beatIndex": 0-based beat number or null for a global note,
           "severity": "warning" or "info",
           "message": "one-line issue description"},
          ...
        ]
        Return [] if the flow is clean.
        """)

    // MARK: 8. YouTube Summary

    static let youTubeSummary = PrimingStage(
        key: "priming_youtubeSummary",
        title: "YouTube Summary",
        icon: "play.rectangle",
        firesWhen: "Generate Summary in the YouTube deliverables sheet. {LENGTH} is replaced with the Short/Medium/Long instruction at runtime."
    ,
        defaultText: """
        You are writing a YouTube video description. {LENGTH} Write a professional, factual summary of the video based on the title, chapter markers, notes, and the provided transcript. Do not include chapter lists or timestamps in the summary. Reply with the summary text only, with no preamble.
        """)
}
