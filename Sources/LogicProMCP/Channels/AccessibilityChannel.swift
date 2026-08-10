import ApplicationServices
import CoreGraphics
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return getTransportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome")
        case "transport.set_tempo":
            return setTempo(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return selectTrack(params: params)
        case "track.set_mute":
            return setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return renameTrack(params: params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Mixer reads
        case "mixer.get_state":
            return getMixerState()
        case "mixer.get_channel_strip":
            return getChannelStrip(params: params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return setMixerValue(params: params, target: .volume)
        case "mixer.set_pan":
            return setMixerValue(params: params, target: .pan)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - Navigation
        case "nav.get_markers":
            return .error("Marker reading not yet implemented via AX")
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return getProjectInfo()
        case "project.tag_imported_audio":
            return await tagImportedAudio(params: params)
        case "project.remove_ace_audio_delta_duplicate":
            return await removeACEAudioDeltaDuplicate(params: params)
        case "project.tag_ace_audio_delta":
            return await tagACEAudioDelta(params: params)
        case "project.read_ace_audio_delta_geometry":
            return await readACEAudioDeltaGeometry(params: params)
        case "project.read_ace_audio_placement_geometry":
            return await readACEAudioPlacementGeometry(params: params)
        case "selection.get_state":
            return getSelectionState()
        case "context.get_state":
            return getContextState()
        case "editor.get_state":
            return getEditorState()
        case "editor.get_notes":
            return getEditorNotes()

        // MARK: - Regions
        case "region.get_regions":
            return getRegions(params: params)
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard AXIsProcessTrusted() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard AXLogicProElements.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Transport

    private func getTransportState() -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport)
        return encodeResult(state)
    }

    private func toggleTransportButton(named name: String) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    private func setTempo(params: [String: String]) -> ChannelResult {
        guard let tempoStr = params["tempo"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        // First prefer a dedicated tempo text field when Logic exposes one.
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXTextFieldRole, maxDepth: 4)
        for field in texts {
            let desc = AXHelpers.getDescription(field)?.lowercased() ?? ""
            if desc.contains("tempo") || desc.contains("bpm") {
                AXHelpers.setAttribute(field, kAXValueAttribute, tempoStr as CFTypeRef)
                AXHelpers.performAction(field, kAXConfirmAction)
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }

        // On the current Logic Pro UI, tempo is exposed as an AXSlider labeled "Tempo".
        let sliders = AXHelpers.findAllDescendants(of: transport, role: kAXSliderRole, maxDepth: 4)
        for slider in sliders {
            let desc = AXHelpers.getDescription(slider)?.lowercased() ?? ""
            let title = AXHelpers.getTitle(slider)?.lowercased() ?? ""
            if desc.contains("tempo") || desc.contains("bpm") || title.contains("tempo") || title.contains("bpm") {
                guard AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: Double(tempoStr) ?? 120.0)) else {
                    return .error("Failed to set tempo slider")
                }
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }

        return .error("Cannot locate tempo field or slider")
    }

    private func setCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private func getTracks() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
        }
        let projectIdentity = currentProjectIdentity()
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(
                from: header,
                index: index,
                projectIdentity: projectIdentity
            )
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private func getSelectedTrack() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        let projectIdentity = currentProjectIdentity()
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header) == true {
                let track = AXValueExtractors.extractTrackState(
                    from: header,
                    index: index,
                    projectIdentity: projectIdentity
                )
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    private func selectTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction) else {
            return .error("Failed to select track \(index)")
        }
        return .success("{\"selected\":\(index)}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let enabledString = params["enabled"]?.lowercased() else {
            return .error("Missing 'enabled' parameter")
        }
        let enabled: Bool
        switch enabledString {
        case "true", "1": enabled = true
        case "false", "0": enabled = false
        default: return .error("Invalid 'enabled' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }

        guard let current = AXValueExtractors.extractButtonState(button) else {
            return .error("Cannot verify current \(buttonName) state on track \(index); no mutation started")
        }
        if current != enabled {
            guard AXHelpers.performAction(button, kAXPressAction) else {
                return .error("Failed to click \(buttonName) on track \(index)")
            }
        }
        guard let observed = AXValueExtractors.extractButtonState(button), observed == enabled else {
            return .error("Unable to verify \(buttonName)=\(enabled) on track \(index); result is unknown")
        }
        return .success("{\"track\":\(index),\"\(buttonName.lowercased())\":\(enabled),\"verification\":\"direct_readback\"}")
    }

    private func renameTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
            return .error("Cannot find name field for track \(index)")
        }
        // Double-click to enter edit mode, then set value
        AXHelpers.performAction(field, kAXPressAction)
        AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef)
        AXHelpers.performAction(field, kAXConfirmAction)
        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    /// Attach the explicit operation tags after the import dispatch. The row
    /// indices here are used only as a bounded precondition for the newly
    /// created selected track; they are never returned as stable identity.
    private func tagImportedAudio(params: [String: String]) async -> ChannelResult {
        guard let beforeTrackCount = params["before_track_count"].flatMap(Int.init),
              let beforeRegionCount = params["before_region_count"].flatMap(Int.init),
              beforeTrackCount >= 0,
              beforeRegionCount >= 0,
              let trackTag = params["track_tag"],
              OperationTagIdentity.operationTag(in: trackTag) == trackTag,
              let regionTag = params["region_tag"],
              OperationTagIdentity.operationTag(in: regionTag) == regionTag,
              let assetSHA256 = params["asset_sha256"],
              ACEFileDigest.isSHA256(assetSHA256),
              let nativeSourceBasename = params["native_source_basename"],
              !nativeSourceBasename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return taggingFailure(
                "project.tag_imported_audio requires validated counts, operation tags, source digest, and native source basename",
                outcome: "not_started"
            )
        }
        let keeperDigestReceiptID = params["keeper_digest_receipt_id"]
        let deadline = Date().addingTimeInterval(ServerConfig.aceAudioTaggingTimeout)
        var lastIssue = "new imported track is not yet visible"

        while Date() < deadline {
            let headers = AXLogicProElements.allTrackHeaders()
            let rows = AXLogicProElements.allTrackContentRows()
            let selectedTracks = headers.enumerated().filter {
                AXValueExtractors.extractSelectedState($0.element) == true
            }

            guard selectedTracks.count <= 1 else {
                return taggingFailure("imported track selection is ambiguous; no tag write started", outcome: "not_started")
            }
            guard let selectedTrack = selectedTracks.first else {
                lastIssue = "imported track is not selected; no tag write started"
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            let trackIndex = selectedTrack.offset
            guard trackIndex >= beforeTrackCount else {
                return taggingFailure("selected track is an existing visible-order row; no tag write started", outcome: "not_started")
            }
            guard trackIndex < rows.count else {
                lastIssue = "selected imported track has no visible content row yet"
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            let regionItems = AXHelpers.getChildren(rows[trackIndex]).filter {
                AXHelpers.getRole($0) == "AXLayoutItem"
            }
            let visibleRegionCount = rows.reduce(into: 0) { count, row in
                count += AXHelpers.getChildren(row).filter {
                    AXHelpers.getRole($0) == "AXLayoutItem"
                }.count
            }
            guard visibleRegionCount <= beforeRegionCount + 1 else {
                return taggingFailure("import produced more than one visible region; no tag write started", outcome: "not_started")
            }
            guard visibleRegionCount == beforeRegionCount + 1,
                  regionItems.count == 1 else {
                lastIssue = "new imported region is not yet visible as one layer"
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            let projectIdentity = currentProjectIdentity()
            let currentTrack = AXValueExtractors.extractTrackState(
                from: selectedTrack.element,
                index: trackIndex,
                projectIdentity: projectIdentity
            )
            let currentRegion = AXValueExtractors.extractRegions(
                from: rows[trackIndex],
                trackIndex: trackIndex,
                trackName: currentTrack.name,
                projectIdentity: projectIdentity
            ).first(where: { $0.name == nativeSourceBasename })
            guard currentRegion != nil else {
                lastIssue = "new imported region does not expose the exact native source basename; no region rename started"
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            guard let trackField = AXLogicProElements.findTrackNameField(
                trackIndex: trackIndex,
                currentName: currentTrack.name
            ) else {
                lastIssue = "new imported track name field is unavailable; no region rename started"
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            guard setAndConfirmName(
                trackField,
                name: trackTag,
                expectedCurrentName: currentTrack.name,
                trackIndex: trackIndex
            ) else {
                return taggingFailure(
                    "operation track tag could not be written and verified; no region rename was issued; import remains dispatched",
                    outcome: "unknown"
                )
            }

            let verifiedHeaders = AXLogicProElements.allTrackHeaders()
            let verifiedRows = AXLogicProElements.allTrackContentRows()
            guard trackIndex < verifiedHeaders.count,
                  trackIndex < verifiedRows.count else {
                return taggingFailure("tagged layer disappeared during readback; import remains dispatched", outcome: "unknown")
            }
            let verifiedProjectIdentity = currentProjectIdentity()
            let verifiedTrack = AXValueExtractors.extractTrackState(
                from: verifiedHeaders[trackIndex],
                index: trackIndex,
                projectIdentity: verifiedProjectIdentity
            )
            let verifiedRegions = AXValueExtractors.extractRegions(
                from: verifiedRows[trackIndex],
                trackIndex: trackIndex,
                trackName: verifiedTrack.name,
                projectIdentity: verifiedProjectIdentity,
                trackStableID: verifiedTrack.stableID
            )
            guard verifiedTrack.name == trackTag,
                  verifiedTrack.stableID != nil,
                  verifiedRegions.count == 1,
                  verifiedRegions[0].name == nativeSourceBasename,
                  verifiedRegions[0].trackStableID == verifiedTrack.stableID else {
                return taggingFailure(
                    "operation track tag did not produce unique parent-track readback for the exact native source basename; no region rename was issued; import remains dispatched",
                    outcome: "unknown"
                )
            }

            return encodeResult([
                "stage": ACEAudioPlacementContract.importStageTagging,
                "status": "completed",
                "outcome": "tagged",
                "verification": "direct_readback",
                "identity_scope": "temporary_selection_precondition_only",
                "track_tag": trackTag,
                "region_tag": regionTag,
                "asset_sha256": assetSHA256,
                "native_source_basename": nativeSourceBasename,
                "keeper_digest_receipt_id": keeperDigestReceiptID ?? "",
                "region_name_mutation": "not_issued",
            ])
        }

        return taggingFailure(
            "\(lastIssue); bounded tag-readback wait expired and import remains dispatched",
            status: "timed_out",
            outcome: "unknown"
        )
    }

    private func taggingFailure(
        _ detail: String,
        status: String = "failed",
        outcome: String
    ) -> ChannelResult {
        .error(
            "stage=\(ACEAudioPlacementContract.importStageTagging) status=\(status) outcome=\(outcome) detail=\(detail.replacingOccurrences(of: "\n", with: " "))"
        )
    }

    private func setAndConfirmName(
        _ field: AXUIElement,
        name: String,
        expectedCurrentName: String,
        trackIndex: Int
    ) -> Bool {
        // Logic's AX text field exposes only AXPress and is not writable via
        // AXValue. Its help says to double-click; use one physical double-click
        // and one bounded keyboard replacement, then verify the parent track.
        guard ProcessUtils.activateLogicPro(),
              let fieldFrame = AXHelpers.frame(of: field),
              fieldFrame.width > 0,
              fieldFrame.height > 0,
              let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        let fieldRect = CGRect(
            x: fieldFrame.x,
            y: fieldFrame.y,
            width: fieldFrame.width,
            height: fieldFrame.height
        )
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return false
        }
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return false
        }
        let visibleFrames = displayIDs.compactMap { displayID -> CGRect? in
            let intersection = CGDisplayBounds(displayID).intersection(fieldRect)
            return intersection.width > 0 && intersection.height > 0 ? intersection : nil
        }
        guard let visibleFrame = visibleFrames.max(by: {
            ($0.width * $0.height) < ($1.width * $1.height)
        }) else {
            return false
        }
        let point = CGPoint(
            x: visibleFrame.minX + min(20.0, visibleFrame.width / 2.0),
            y: visibleFrame.midY
        )
        guard postTrackNameMouseClick(source, at: point, clickState: 1) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard postTrackNameMouseClick(source, at: point, clickState: 2) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.15)
        guard let app = AXLogicProElements.appRoot(),
              let focusedField: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute),
              AXHelpers.getRole(focusedField) == kAXTextFieldRole else {
            return false
        }
        let focusedNames = [
            AXValueExtractors.extractTextValue(focusedField),
            AXHelpers.getDescription(focusedField),
            AXHelpers.getTitle(focusedField),
        ].compactMap { $0 }
        guard focusedNames.contains(expectedCurrentName) else {
            return false
        }
        postTrackNameKey(source, keyCode: 0, flags: .maskCommand)
        postTrackNameText(source, text: name)
        postTrackNameKey(source, keyCode: 36)
        for attempt in 0..<12 {
            let headers = AXLogicProElements.allTrackHeaders()
            if trackIndex < headers.count {
                let projectIdentity = currentProjectIdentity()
                let observedTrack = AXValueExtractors.extractTrackState(
                    from: headers[trackIndex],
                    index: trackIndex,
                    projectIdentity: projectIdentity
                )
                if observedTrack.name == name {
                    return true
                }
            }
            if attempt < 11 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return false
    }

    private func postTrackNameMouseClick(
        _ source: CGEventSource,
        at point: CGPoint,
        clickState: Int64
    ) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return false
        }
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postTrackNameKey(
        _ source: CGEventSource,
        keyCode: CGKeyCode,
        flags: CGEventFlags = []
    ) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postTrackNameText(_ source: CGEventSource, text: String) {
        var unicode = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        unicode.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Mixer

    private enum MixerTarget {
        case volume
        case pan
    }

    // MARK: - Regions

    private func getRegions(params: [String: String]) -> ChannelResult {
        let contentRows = AXLogicProElements.allTrackContentRows()
        let projectIdentity = currentProjectIdentity()
        let tracks = AXLogicProElements.allTrackHeaders().enumerated().map {
            AXValueExtractors.extractTrackState(
                from: $0.element,
                index: $0.offset,
                projectIdentity: projectIdentity
            )
        }

        if contentRows.isEmpty || tracks.isEmpty {
            return .error("No visible track contents found — is the Tracks area open?")
        }

        let onlyTrackIndex = params["index"].flatMap(Int.init)
        var regions: [RegionState] = []

        for (index, row) in contentRows.enumerated() {
            if let onlyTrackIndex, index != onlyTrackIndex {
                continue
            }
            guard index < tracks.count else { continue }
            let track = tracks[index]
            regions.append(contentsOf: AXValueExtractors.extractRegions(
                from: row,
                trackIndex: index,
                trackName: track.name,
                projectIdentity: projectIdentity,
                trackStableID: track.stableID
            ))
        }

        return encodeResult(regions)
    }

    private func getMixerState() -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
            let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
            let pan = sliders.count > 1
                ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
                : 0.0

            channelStrips.append(ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            ))
        }
        return encodeResult(channelStrips)
    }

    private func getChannelStrip(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
        let pan = sliders.count > 1
            ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
            : 0.0

        let state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        return encodeResult(state)
    }

    private func setMixerValue(params: [String: String], target: MixerTarget) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'index' or 'value' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value))
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
    }

    // MARK: - Project

    private func getProjectInfo() -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let rawTitle = AXHelpers.getTitle(window) ?? "Unknown"
        var info = ProjectInfo()
        info.name = Self.normalizedProjectTitle(rawTitle)
        if let observed = observedAXDocument(for: window) {
            info.filePath = observed.path
            info.projectIdentity = observed.projectIdentity
        } else {
            info.projectIdentity = .visibleOnly(name: info.name)
        }
        info.trackCount = AXLogicProElements.allTrackHeaders().count
        if let transport = AXLogicProElements.getTransportBar(),
           let tempo = AXValueExtractors.extractTempoValue(from: transport) {
            info.tempo = tempo
        } else {
            // Avoid reporting the model default as if it were a confirmed project tempo.
            info.tempo = 0.0
        }
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    private func getSelectionState() -> ChannelResult {
        let projectIdentity = currentProjectIdentity()
        let tracks = AXLogicProElements.allTrackHeaders().enumerated().map {
            AXValueExtractors.extractTrackState(
                from: $0.element,
                index: $0.offset,
                projectIdentity: projectIdentity
            )
        }
        let contentRows = AXLogicProElements.allTrackContentRows()

        var selection = SelectionState()
        if let selectedTrack = tracks.first(where: { $0.isSelected }) {
            selection.selectedTrackIndex = selectedTrack.id
            selection.selectedTrackName = selectedTrack.name
        }

        var selectedRegions: [RegionState] = []
        for (index, row) in contentRows.enumerated() {
            guard index < tracks.count else { continue }
            let track = tracks[index]
            let regions = AXValueExtractors.extractRegions(
                from: row,
                trackIndex: index,
                trackName: track.name,
                projectIdentity: projectIdentity,
                trackStableID: track.stableID
            )
            selectedRegions.append(contentsOf: regions.filter(\ .isSelected))
        }

        selection.selectedRegionIDs = selectedRegions.map(\ .id)
        selection.selectedRegionNames = selectedRegions.map(\ .name)
        selection.selectedRegionCount = selectedRegions.count
        if !selectedRegions.isEmpty {
            selection.selectedRegionIdentityStability = .synthetic
            selection.identityScope = "visible_only"
            selection.identityNote = "AX selection IDs are synthetic and derived from visible track order; they cannot authorize destructive mutation."
        }
        selection.projectIdentity = projectIdentity
        selection.lastUpdated = Date()
        return encodeResult(selection)
    }

    private func getContextState() -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let rawTitle = AXHelpers.getTitle(window) ?? "Unknown"
        let projectIdentity = currentProjectIdentity()
        let tracks = AXLogicProElements.allTrackHeaders().enumerated().map {
            AXValueExtractors.extractTrackState(
                from: $0.element,
                index: $0.offset,
                projectIdentity: projectIdentity
            )
        }
        let regions = AXLogicProElements.allTrackContentRows().enumerated().flatMap { index, row in
            guard index < tracks.count else { return [RegionState]() }
            let track = tracks[index]
            return AXValueExtractors.extractRegions(
                from: row,
                trackIndex: index,
                trackName: track.name,
                projectIdentity: projectIdentity,
                trackStableID: track.stableID
            )
        }

        let context = ContextState(
            projectName: Self.normalizedProjectTitle(rawTitle),
            windowTitle: rawTitle,
            activeView: Self.activeViewName(rawTitle),
            visibleTrackCount: tracks.count,
            visibleRegionCount: regions.count,
            lastUpdated: Date(),
            projectIdentity: projectIdentity
        )
        return encodeResult(context)
    }

    private func currentProjectIdentity() -> ProjectIdentity {
        guard let window = AXLogicProElements.mainWindow() else { return .unknown }
        if let observed = observedAXDocument(for: window) {
            return observed.projectIdentity
        }
        let title = AXHelpers.getTitle(window) ?? "Unknown"
        return .visibleOnly(name: Self.normalizedProjectTitle(title))
    }

    private func observedAXDocument(for fallbackWindow: AXUIElement) -> ResolvedAXDocument? {
        guard let window = AXLogicProElements.frontProjectWindow() else { return nil }
        let document = AXHelpers.getDocumentURLString(window)
        let title = AXHelpers.getTitle(window) ?? AXHelpers.getTitle(fallbackWindow)
        return AXDocumentProjectResolver.resolve(document: document, windowTitle: title)
    }

    private func getEditorState() -> ChannelResult {
        guard let window = AXLogicProElements.eventListWindow() else {
            let state = EditorState(
                activeView: "event_list",
                eventListVisible: false,
                detailAvailability: "event_list_hidden",
                writeCapabilities: ["delete_selection", "quantize_selection"],
                lastUpdated: Date()
            )
            return encodeResult(state)
        }

        let rows = AXLogicProElements.eventListRows()
        let state = AXValueExtractors.extractEditorState(from: window, rows: rows)
        return encodeResult(state)
    }

    private func getEditorNotes() -> ChannelResult {
        let rows = AXLogicProElements.eventListRows()
        let noteRows = AXValueExtractors.extractEventRows(from: rows).filter {
            $0.eventType.caseInsensitiveCompare("Note") == .orderedSame
        }
        return encodeResult(noteRows)
    }

    static func normalizedProjectTitle(_ rawTitle: String) -> String {
        let separators = [" - Tracks", " - Track", " - Piano Roll", " - Mixer", " - Event List"]
        var baseTitle = rawTitle
        for suffix in separators where baseTitle.hasSuffix(suffix) {
            baseTitle = String(baseTitle.dropLast(suffix.count))
            break
        }

        let parts = baseTitle.components(separatedBy: " - ")
        if parts.count >= 2, parts[0].hasSuffix(".logicx") {
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func activeViewName(_ rawTitle: String) -> String {
        if rawTitle.hasSuffix(" - Tracks") || rawTitle.hasSuffix(" - Track") {
            return "tracks"
        }
        if rawTitle.hasSuffix(" - Piano Roll") {
            return "piano_roll"
        }
        if rawTitle.hasSuffix(" - Mixer") {
            return "mixer"
        }
        if rawTitle.hasSuffix(" - Event List") {
            return "event_list"
        }
        return "unknown"
    }

    // MARK: - JSON encoding

    private func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
