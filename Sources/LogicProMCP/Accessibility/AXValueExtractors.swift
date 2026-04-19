import ApplicationServices
import Foundation

/// Extract typed values from AX elements.
/// These handle the various ways Logic Pro represents values in its AX tree.
enum AXValueExtractors {
    /// Extract a numeric value from a slider (volume fader, pan knob, etc.)
    /// Returns the AXValue as a Double, or nil if unavailable.
    static func extractSliderValue(_ element: AXUIElement) -> Double? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // AXSlider values can come as NSNumber or CFNumber
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        // Try string-based value and parse
        if let str = value as? String, let parsed = Double(str) {
            return parsed
        }
        return nil
    }

    /// Extract a text value from a static text or text field element.
    /// Used for tempo display, position readout, track names, etc.
    static func extractTextValue(_ element: AXUIElement) -> String? {
        // Try kAXValueAttribute first (text fields, static text)
        if let value = AXHelpers.getValue(element) as? String {
            return value
        }
        // Fallback to kAXTitleAttribute
        return AXHelpers.getTitle(element)
    }

    /// Extract a boolean state from a button or checkbox element.
    /// For toggle buttons (mute, solo, arm, cycle, metronome), the value
    /// indicates pressed/active state.
    static func extractButtonState(_ element: AXUIElement) -> Bool? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // Toggle buttons typically report 0/1 as NSNumber
        if let number = value as? NSNumber {
            return number.boolValue
        }
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract checkbox state (a variant of button state, but checks kAXValueAttribute specifically).
    static func extractCheckboxState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXValueAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        return nil
    }

    /// Extract the selected state of an element.
    static func extractSelectedState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXSelectedAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Extract slider range (min/max) for interpreting fader values.
    struct SliderRange {
        let min: Double
        let max: Double
    }

    static func extractSliderRange(_ element: AXUIElement) -> SliderRange? {
        guard let minVal: AnyObject = AXHelpers.getAttribute(element, kAXMinValueAttribute),
              let maxVal: AnyObject = AXHelpers.getAttribute(element, kAXMaxValueAttribute),
              let min = (minVal as? NSNumber)?.doubleValue,
              let max = (maxVal as? NSNumber)?.doubleValue else {
            return nil
        }
        return SliderRange(min: min, max: max)
    }

    /// Read a track header and extract its basic state.
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractTrackToggleState(from: header, prefix: "Mute") ?? false
        let soloed = extractTrackToggleState(from: header, prefix: "Solo") ?? false
        let armed = extractTrackToggleState(from: header, prefix: "Record") ?? false
        let selected = extractSelectedState(header) ?? false
        let trackType = inferTrackType(from: header)
        let pan = extractTrackPan(from: header) ?? 0.0
        let volume = extractTrackVolume(from: header) ?? 0.0

        return TrackState(
            id: index,
            name: name,
            type: trackType,
            isMuted: muted,
            isSoloed: soloed,
            isArmed: armed,
            isSelected: selected,
            volume: volume,
            pan: pan,
            color: extractTrackColor(from: header)
        )
    }

    /// Read transport bar elements and build a TransportState.
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        // Find and read transport button states
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            let pressed = extractButtonState(button) ?? false
            let descLower = desc.lowercased()

            if descLower.contains("play") {
                state.isPlaying = pressed
            } else if descLower.contains("record") && !descLower.contains("arm") {
                state.isRecording = pressed
            } else if descLower.contains("cycle") || descLower.contains("loop") {
                state.isCycleEnabled = pressed
            } else if descLower.contains("metronome") || descLower.contains("click") {
                state.isMetronomeEnabled = pressed
            }
        }

        // Find text fields for tempo, position
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if descLower.contains("position") || value.contains(".") && value.contains(":") == false {
                // Bar.Beat.Division.Tick format
                if value.filter({ $0 == "." }).count >= 2 {
                    state.position = value
                }
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Private helpers

    static func parseTrackName(from text: String) -> String? {
        let pattern = #"[“\"]([^”\"]+)[”\"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let parsed = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return parsed.isEmpty ? nil : parsed
    }

    private static func extractTrackName(from header: AXUIElement) -> String {
        let headerDesc = AXHelpers.getDescription(header) ?? ""
        if let parsed = parseTrackName(from: headerDesc) {
            return parsed
        }

        let headerValue: String
        if let rawValue = AXHelpers.getValue(header) {
            headerValue = String(describing: rawValue)
        } else {
            headerValue = ""
        }
        if let parsed = parseTrackName(from: headerValue) {
            return parsed
        }

        // Try static text first
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3),
           let name = extractTextValue(text), !name.isEmpty {
            return name
        }
        // Try text field
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3),
           let name = extractTextValue(field), !name.isEmpty {
            return name
        }
        if let title = AXHelpers.getTitle(header), !title.isEmpty {
            return title
        }
        return headerDesc.isEmpty ? "Untitled" : headerDesc
    }

    private static func extractTrackToggleState(from header: AXUIElement, prefix: String) -> Bool? {
        let elements =
            AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 4)
            + AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4)
        for element in elements {
            let desc = AXHelpers.getDescription(element) ?? AXHelpers.getTitle(element) ?? ""
            if desc.hasPrefix(prefix) || desc.lowercased().contains(prefix.lowercased()) {
                return extractButtonState(element)
            }
        }
        return nil
    }

    private static func extractTrackPan(from header: AXUIElement) -> Double? {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 3)
        for slider in sliders {
            let children = AXHelpers.getChildren(slider)
            for child in children {
                let desc = AXHelpers.getDescription(child) ?? ""
                if desc.localizedCaseInsensitiveContains("Pan") {
                    let numeric = desc
                        .replacingOccurrences(of: "Pan", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value = Double(numeric) {
                        return value
                    }
                }
            }
        }
        return nil
    }

    private static func extractTrackVolume(from header: AXUIElement) -> Double? {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 3)
        for slider in sliders {
            let desc = AXHelpers.getDescription(slider) ?? ""
            if desc.localizedCaseInsensitiveContains("Volume") {
                return extractSliderValue(slider)
            }
        }
        return nil
    }

    private static func inferTrackType(from header: AXUIElement) -> TrackType {
        // Attempt to infer type from the header plus any child descriptions/titles.
        let headerDesc = AXHelpers.getDescription(header)?.lowercased() ?? ""
        let headerTitle = AXHelpers.getTitle(header)?.lowercased() ?? ""
        let childText = AXHelpers.getChildren(header)
            .map { child in
                [AXHelpers.getDescription(child), AXHelpers.getTitle(child)]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
            }
            .joined(separator: " ")
        let combined = [headerDesc, headerTitle, childText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if combined.contains("audio") { return .audio }
        if combined.contains("instrument") || combined.contains("software") { return .softwareInstrument }
        if combined.contains("drummer") { return .drummer }
        if combined.contains("external") || combined.contains("midi") { return .externalMIDI }
        if combined.contains("aux") { return .aux }
        if combined.contains("bus") { return .bus }
        if combined.contains("master") || combined.contains("stereo out") { return .master }
        // Current Logic Pro track headers expose input monitoring + pan/volume,
        // but not an explicit track-type label. Treat that as an audio-track heuristic.
        if combined.contains("input monitoring") && combined.contains("volume") {
            return .audio
        }
        return .unknown
    }

    private static func extractTrackColor(from header: AXUIElement) -> String? {
        // Logic Pro may expose color via a custom attribute or the element's description
        let desc = AXHelpers.getDescription(header) ?? ""
        if desc.lowercased().contains("color") {
            return desc
        }
        return nil
    }
}
