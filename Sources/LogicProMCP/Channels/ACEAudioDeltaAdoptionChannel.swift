import ApplicationServices
import CoreGraphics
import Foundation

extension AXHelpers {
    static func frame(of element: AXUIElement) -> ACEAXRect? {
        guard let positionValue = axValue(element, attribute: kAXPositionAttribute),
              let sizeValue = axValue(element, attribute: kAXSizeAttribute) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return ACEAXRect(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
    }

    private static func axValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(raw, to: AXValue.self)
    }
}

extension AXLogicProElements {
    static func namedRegionElement(
        trackName: String,
        regionName: String
    ) -> (trackIndex: Int, regionIndex: Int, element: AXUIElement)? {
        let projectIdentity = ProjectIdentity.unknown
        let headers = allTrackHeaders()
        let rows = allTrackContentRows()
        let matchingTracks = headers.enumerated().filter {
            AXValueExtractors.extractTrackState(
                from: $0.element,
                index: $0.offset,
                projectIdentity: projectIdentity
            ).name == trackName
        }
        guard matchingTracks.count == 1 else { return nil }
        let trackIndex = matchingTracks[0].offset
        guard trackIndex < rows.count else { return nil }
        let regions = AXValueExtractors.extractRegions(
            from: rows[trackIndex],
            trackIndex: trackIndex,
            trackName: trackName,
            projectIdentity: projectIdentity
        )
        let matchingRegions = regions.enumerated().filter { $0.element.name == regionName }
        guard matchingRegions.count == 1 else { return nil }
        let regionIndex = matchingRegions[0].offset
        let items = AXHelpers.getChildren(rows[trackIndex]).filter {
            AXHelpers.getRole($0) == "AXLayoutItem"
        }
        guard regionIndex < items.count else { return nil }
        return (trackIndex, regionIndex, items[regionIndex])
    }

    static func regionItems() -> [AXUIElement] {
        allTrackContentRows().flatMap { row in
            AXHelpers.getChildren(row).filter { AXHelpers.getRole($0) == "AXLayoutItem" }
        }
    }

    static func tracksTimeRuler() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        return AXHelpers.findAllDescendants(of: window, role: "AXLayoutArea", maxDepth: 12)
            .first { AXHelpers.getDescription($0) == "Tracks time ruler" }
    }

    static func playheadThumb() -> AXUIElement? {
        guard let ruler = tracksTimeRuler() else { return nil }
        return AXHelpers.findAllDescendants(of: ruler, role: "AXValueIndicator", maxDepth: 4)
            .first { AXHelpers.getDescription($0) == "Playhead thumb" }
    }

    static func playheadSliders() -> (bar: AXUIElement, beat: AXUIElement)? {
        guard let window = mainWindow() else { return nil }
        let sliders = AXHelpers.findAllDescendants(of: window, role: kAXSliderRole, maxDepth: 8)
        let bars = sliders.filter { AXHelpers.getDescription($0)?.localizedCaseInsensitiveCompare("bar") == .orderedSame }
        let beats = sliders.filter { AXHelpers.getDescription($0)?.localizedCaseInsensitiveCompare("beat") == .orderedSame }
        guard bars.count == 1, beats.count == 1 else { return nil }
        return (bars[0], beats[0])
    }
}

extension AccessibilityChannel {
    func removeACEAudioDeltaDuplicate(params: [String: String]) async -> ChannelResult {
        guard let spec = adoptionSpec(from: params),
              let expectedTrackCount = Int(params["current_track_count"] ?? ""),
              let expectedRegionCount = Int(params["current_region_count"] ?? ""),
              expectedTrackCount == spec.currentTrackCount,
              expectedRegionCount == spec.currentRegionCount else {
            return .error("exact-delta duplicate cleanup requires a complete adoption spec; no mutation started")
        }
        guard let snapshot = adoptionSnapshot(),
              let observed = observedProject(from: snapshot),
              observed.path == ACEFileDigest.normalizedPath(spec.targetProjectPath),
              observed.digest == spec.startingProjectSHA256 else {
            return .error("live project path/digest is not the exact P5G starting disposable; no mutation started")
        }
        let issues = ACEAudioDeltaAdoptionValidator.validateStartingDelta(snapshot, spec: spec)
        guard issues.isEmpty else {
            return .error("exact-delta duplicate cleanup refused: \(issues.map(\.code).joined(separator: ",")); no mutation started")
        }
        guard let target = AXLogicProElements.namedRegionElement(
            trackName: spec.newTrackName,
            regionName: spec.duplicateRegionName
        ) else {
            return .error("uniquely named duplicate region could not be addressed; no mutation started")
        }
        guard selectOnlyRegion(
            target.element,
            trackIndex: target.trackIndex,
            regionIndex: target.regionIndex,
            expectedName: spec.duplicateRegionName,
            expectedProjectPath: spec.targetProjectPath
        ) else {
            return .error("duplicate region selection was not uniquely verified; no mutation started")
        }
        guard let verifiedTarget = AXLogicProElements.namedRegionElement(
            trackName: spec.newTrackName,
            regionName: spec.duplicateRegionName
        ),
        AXValueExtractors.extractSelectedState(verifiedTarget.element) == true,
        postDeleteAction(
            selectedRegion: verifiedTarget.element,
            expectedRegionName: spec.duplicateRegionName,
            expectedProjectPath: spec.targetProjectPath
        ) else {
            return .error("bounded delete actuation failed after exact duplicate selection; mutation outcome is unverified")
        }

        var after: ACEPlacementSnapshot?
        for attempt in 0..<12 {
            after = adoptionSnapshot()
            if let after,
               ACEAudioDeltaAdoptionValidator.validateAfterCleanup(after, spec: spec).isEmpty {
                return encodeAdoptionStep(
                    action: "remove_unique_duplicate",
                    status: "verified_duplicate_removed",
                    spec: spec,
                    before: snapshot,
                    after: after,
                    removedRegion: spec.duplicateRegionName
                )
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let reason = after.map { ACEAudioDeltaAdoptionValidator.validateAfterCleanup($0, spec: spec).map(\.code).joined(separator: ",") }
            ?? "logic_after_cleanup_readback_unavailable"
        return .error("duplicate cleanup was dispatched but postcondition was not verified: \(reason)")
    }

    func tagACEAudioDelta(params: [String: String]) async -> ChannelResult {
        guard let spec = adoptionSpec(from: params),
              let snapshot = adoptionSnapshot(),
              let observed = observedProject(from: snapshot),
              observed.path == ACEFileDigest.normalizedPath(spec.targetProjectPath) else {
            return .error("exact-delta tagging requires the bound disposable project and a fresh AX readback; no tag write started")
        }
        let cleanupIssues = ACEAudioDeltaAdoptionValidator.validateAfterCleanup(snapshot, spec: spec)
        guard cleanupIssues.isEmpty else {
            return .error("tagging refused because exact duplicate cleanup is not proven: \(cleanupIssues.map(\.code).joined(separator: ",")); no tag write started")
        }

        let candidateTracks = snapshot.tracks.filter {
            $0.name == spec.newTrackName || OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag
        }
        guard candidateTracks.count == 1 else {
            return .error("remaining exact new track could not be uniquely addressed; no tag write started")
        }
        let candidateTrack = candidateTracks[0]
        let candidateRegions = snapshot.regions.filter {
            $0.trackName == candidateTrack.name
                && ($0.name == spec.sourceBaseName || OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag)
        }
        guard candidateRegions.count == 1 else {
            return .error("remaining exact-source region could not be uniquely addressed; no tag write started")
        }
        let targetRegionName = "\(spec.sourceBaseName) | \(spec.regionTag) \(spec.source.sha256)"
        let trackIsTagged = OperationTagIdentity.operationTag(in: candidateTrack.name) == spec.trackTag

        if !trackIsTagged {
            guard let trackField = AXLogicProElements.findTrackNameField(
                trackIndex: candidateTrack.id,
                currentName: candidateTrack.name
            ), setAndConfirmAdoptionName(
                trackField,
                name: spec.trackTag,
                expectedCurrentName: candidateTrack.name,
                expectedProjectPath: spec.targetProjectPath
            ) else {
                return .error("operation track tag could not be written and verified; adoption remains incomplete")
            }
            guard waitForTaggedTrack(spec.trackTag, expectedProjectPath: spec.targetProjectPath) else {
                return .error("operation track tag was dispatched but fresh AX track readback was not verified; adoption remains incomplete")
            }
        }

        let regionSnapshot = adoptionSnapshot() ?? snapshot
        let currentTrack = regionSnapshot.tracks.first {
            OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag || $0.name == spec.newTrackName
        }
        guard let currentTrack else {
            return .error("tagged new track disappeared during bounded readback; adoption remains incomplete")
        }
        let currentRegion = regionSnapshot.regions.first {
            $0.trackName == currentTrack.name
                && ($0.name == spec.sourceBaseName || OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag)
        }
        guard let currentRegion else {
            return .error("remaining exact-source region disappeared during bounded readback; adoption remains incomplete")
        }
        if OperationTagIdentity.operationTag(in: currentRegion.name) != spec.regionTag {
            guard let regionField = AXLogicProElements.findRegionNameField(
                trackIndex: currentRegion.trackIndex,
                regionIndex: currentRegion.id.split(separator: "-").last.flatMap { Int($0) } ?? 0,
                currentName: currentRegion.name
            ), setAndConfirmAdoptionName(
                regionField,
                name: targetRegionName,
                expectedCurrentName: currentRegion.name,
                expectedProjectPath: spec.targetProjectPath
            ) else {
                return .error("operation region tag could not be written and verified; adoption remains incomplete")
            }
            guard waitForTaggedRegion(
                spec.regionTag,
                sourceBaseName: spec.sourceBaseName,
                sourceDigest: spec.source.sha256,
                expectedProjectPath: spec.targetProjectPath
            ) else {
                return .error("operation region tag was dispatched but fresh AX region readback was not verified; adoption remains incomplete")
            }
        }

        var after: ACEPlacementSnapshot?
        for attempt in 0..<12 {
            after = adoptionSnapshot()
            if let after,
               ACEAudioDeltaAdoptionValidator.validateTagged(after, spec: spec).isEmpty {
                return encodeAdoptionStep(
                    action: "tag_remaining_exact_source",
                    status: "verified_unique_tags",
                    spec: spec,
                    before: snapshot,
                    after: after,
                    removedRegion: nil
                )
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let reason = after.map { ACEAudioDeltaAdoptionValidator.validateTagged($0, spec: spec).map(\.code).joined(separator: ",") }
            ?? "logic_after_tag_readback_unavailable"
        return .error("tag write was dispatched but unique stable readback was not verified: \(reason)")
    }

    func readACEAudioDeltaGeometry(params: [String: String]) async -> ChannelResult {
        guard let spec = adoptionSpec(from: params) else {
            return .error("timeline geometry requires a complete adoption spec; no actuation started")
        }
        guard let snapshot = adoptionSnapshot(),
              let observed = observedProject(from: snapshot),
              observed.path == ACEFileDigest.normalizedPath(spec.targetProjectPath) else {
            return encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: spec.placement.bar,
                requestedBeat: spec.placement.beat,
                requestedTick: spec.placement.tick,
                reasonCode: "logic_adoption_geometry_project_unavailable"
            ))
        }
        let taggedIssues = ACEAudioDeltaAdoptionValidator.validateTagged(snapshot, spec: spec)
        guard taggedIssues.isEmpty else {
            return encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: spec.placement.bar,
                requestedBeat: spec.placement.beat,
                requestedTick: spec.placement.tick,
                reasonCode: "logic_adoption_geometry_tags_unverified"
            ))
        }
        guard let targetTrack = snapshot.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag }),
              let targetRegion = snapshot.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag }),
              let regionElement = AXLogicProElements.namedRegionElement(trackName: targetTrack.name, regionName: targetRegion.name),
              let ruler = AXLogicProElements.tracksTimeRuler(),
              let rulerFrame = AXHelpers.frame(of: ruler),
              let thumb = AXLogicProElements.playheadThumb() else {
            return encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: spec.placement.bar,
                requestedBeat: spec.placement.beat,
                requestedTick: spec.placement.tick,
                reasonCode: "logic_adoption_geometry_elements_unavailable"
            ))
        }
        guard let sliders = AXLogicProElements.playheadSliders() else {
            return encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: spec.placement.bar,
                requestedBeat: spec.placement.beat,
                requestedTick: spec.placement.tick,
                reasonCode: "logic_adoption_geometry_playhead_controls_unavailable"
            ))
        }
        guard spec.placement.tick == 0 else {
            return encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: spec.placement.bar,
                requestedBeat: spec.placement.beat,
                requestedTick: spec.placement.tick,
                reasonCode: "logic_adoption_geometry_tick_not_supported"
            ))
        }
        guard setPlayhead(sliders, bar: spec.placement.bar, beat: spec.placement.beat),
              let barOneFrame = AXHelpers.frame(of: thumb),
              let barOneValues = playheadValues(sliders),
              setPlayhead(sliders, bar: spec.placement.bar + 1, beat: spec.placement.beat),
              let barTwoFrame = AXHelpers.frame(of: thumb),
              setPlayhead(sliders, bar: spec.placement.bar, beat: spec.placement.beat),
              let finalValues = playheadValues(sliders),
              let regionFrame = AXHelpers.frame(of: regionElement.element) else {
            return encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: spec.placement.bar,
                requestedBeat: spec.placement.beat,
                requestedTick: spec.placement.tick,
                reasonCode: "logic_adoption_geometry_actuation_or_frame_readback_failed"
            ))
        }

        let pixelsPerBeat = abs(barTwoFrame.midX - barOneFrame.midX) / Double(spec.placement.beatsPerBar)
        let estimatedDuration = pixelsPerBeat > 0 ? regionFrame.width / pixelsPerBeat : 0
        let alignment = regionFrame.minX - barOneFrame.minX
        let verified = barOneValues.bar == Double(spec.placement.bar)
            && barOneValues.beat == spec.placement.beat
            && finalValues.bar == Double(spec.placement.bar)
            && finalValues.beat == spec.placement.beat
            && abs(alignment) <= ACEAudioDeltaAdoptionContract.defaultGeometryTolerancePixels
            && pixelsPerBeat > 0
            && abs(estimatedDuration - spec.placement.durationBeats) <= ACEAudioDeltaAdoptionContract.defaultDurationToleranceBeats
        let geometry = ACEAudioDeltaGeometry(
            status: verified ? "verified" : "not_verified",
            verified: verified,
            reasonCode: verified ? "logic_ax_timeline_playhead_geometry" : "logic_adoption_geometry_mismatch",
            requestedBar: spec.placement.bar,
            requestedBeat: spec.placement.beat,
            requestedTick: spec.placement.tick,
            observedBar: finalValues.bar,
            observedBeat: finalValues.beat,
            timeRuler: rulerFrame,
            barOnePlayhead: barOneFrame,
            barTwoPlayhead: barTwoFrame,
            targetRegion: regionFrame,
            pixelsPerBeat: pixelsPerBeat,
            estimatedDurationBeats: estimatedDuration,
            startAlignmentPixels: alignment,
            geometryTolerancePixels: ACEAudioDeltaAdoptionContract.defaultGeometryTolerancePixels,
            durationToleranceBeats: ACEAudioDeltaAdoptionContract.defaultDurationToleranceBeats,
            basis: "bar+1 minus bar+0 AX playhead midpoint divided by beats_per_bar; target region AX frame width divided by that measured pixels-per-beat; tick=0 is the requested beat boundary because Logic exposes bar/beat sliders but no tick control",
            observedAt: Date()
        )
        return encodeGeometry(geometry)
    }

    /// Read independent timeline geometry for the clean-import placement path.
    /// The region name is treated as native Logic source evidence only; no
    /// region-name mutation is possible on this route.
    func readACEAudioPlacementGeometry(params: [String: String]) async -> ChannelResult {
        let requestedBar = Int(params["bar"] ?? "") ?? 0
        let requestedBeat = Double(params["beat"] ?? "") ?? 0
        let requestedTick = Int(params["tick"] ?? "") ?? -1
        let durationBeats = Double(params["duration_beats"] ?? "") ?? 0
        let beatsPerBar = Int(params["beats_per_bar"] ?? "") ?? 0
        let automaticTimeStretch: Bool = switch params["automatic_time_stretch"]?.lowercased() {
        case "false", "0": false
        default: true
        }
        let trackTag = params["track_tag"] ?? ""
        let nativeSourceBasename = params["native_source_basename"] ?? ""
        let targetProjectPath = ACEFileDigest.normalizedPath(params["target_project_path"] ?? "")

        func unavailable(_ reasonCode: String) -> ChannelResult {
            encodeGeometry(ACEAudioDeltaGeometry.unavailable(
                requestedBar: requestedBar,
                requestedBeat: requestedBeat,
                requestedTick: requestedTick,
                reasonCode: reasonCode
            ))
        }

        guard requestedBar >= 1,
              requestedBeat >= 1,
              requestedBeat <= Double(max(1, beatsPerBar)),
              requestedTick == 0,
              durationBeats > 0,
              beatsPerBar > 0,
              OperationTagIdentity.operationTag(in: trackTag) == trackTag,
              !nativeSourceBasename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ACEFileDigest.normalizedPath(targetProjectPath) == targetProjectPath else {
            return unavailable("logic_placement_geometry_parameters_invalid")
        }
        guard let snapshot = adoptionSnapshot(),
              let observed = observedProject(from: snapshot),
              observed.path == targetProjectPath else {
            return unavailable("logic_placement_geometry_project_unavailable")
        }

        let taggedTracks = snapshot.tracks.filter {
            OperationTagIdentity.operationTag(in: $0.name) == trackTag
        }
        guard taggedTracks.count == 1,
              let targetTrack = taggedTracks.first,
              targetTrack.identityStability == .stable,
              targetTrack.identityScope == "project_bound",
              let stableTrackID = targetTrack.stableID,
              OperationTagIdentity.trackID(
                projectIdentity: targetTrack.projectIdentity,
                operationTag: trackTag
              ) == stableTrackID else {
            return unavailable("logic_placement_geometry_track_identity_ambiguous")
        }

        let candidateRegions = snapshot.regions.filter {
            $0.trackName == targetTrack.name
                && $0.name == nativeSourceBasename
                && $0.trackStableID == stableTrackID
        }
        guard candidateRegions.count == 1,
              let targetRegion = candidateRegions.first,
              let regionElement = AXLogicProElements.namedRegionElement(
                trackName: targetTrack.name,
                regionName: targetRegion.name
              ),
              let ruler = AXLogicProElements.tracksTimeRuler(),
              let rulerFrame = AXHelpers.frame(of: ruler),
              let thumb = AXLogicProElements.playheadThumb(),
              let sliders = AXLogicProElements.playheadSliders() else {
            return unavailable("logic_placement_geometry_elements_unavailable")
        }

        guard setPlayhead(sliders, bar: requestedBar, beat: requestedBeat),
              let barOneFrame = AXHelpers.frame(of: thumb),
              let barOneValues = playheadValues(sliders),
              setPlayhead(sliders, bar: requestedBar + 1, beat: requestedBeat),
              let barTwoFrame = AXHelpers.frame(of: thumb),
              setPlayhead(sliders, bar: requestedBar, beat: requestedBeat),
              let finalValues = playheadValues(sliders),
              let regionFrame = AXHelpers.frame(of: regionElement.element) else {
            return unavailable("logic_placement_geometry_actuation_or_frame_readback_failed")
        }

        let pixelsPerBeat = abs(barTwoFrame.midX - barOneFrame.midX) / Double(beatsPerBar)
        let estimatedDuration = pixelsPerBeat > 0 ? regionFrame.width / pixelsPerBeat : 0
        let alignment = regionFrame.minX - barOneFrame.minX
        let durationMatches = abs(estimatedDuration - durationBeats) <= ACEAudioDeltaAdoptionContract.defaultDurationToleranceBeats
        let nativeDurationAccepted = !automaticTimeStretch && estimatedDuration.isFinite && estimatedDuration > 0
        let verified = barOneValues.bar == Double(requestedBar)
            && barOneValues.beat == requestedBeat
            && finalValues.bar == Double(requestedBar)
            && finalValues.beat == requestedBeat
            && abs(alignment) <= ACEAudioDeltaAdoptionContract.defaultGeometryTolerancePixels
            && pixelsPerBeat > 0
            && (durationMatches || nativeDurationAccepted)
        return encodeGeometry(ACEAudioDeltaGeometry(
            status: verified ? "verified" : "not_verified",
            verified: verified,
            reasonCode: verified
                ? (nativeDurationAccepted && !durationMatches
                    ? "logic_ax_timeline_geometry_native_duration_no_stretch"
                    : "logic_ax_timeline_playhead_geometry")
                : "logic_placement_geometry_mismatch",
            requestedBar: requestedBar,
            requestedBeat: requestedBeat,
            requestedTick: requestedTick,
            observedBar: finalValues.bar,
            observedBeat: finalValues.beat,
            timeRuler: rulerFrame,
            barOnePlayhead: barOneFrame,
            barTwoPlayhead: barTwoFrame,
            targetRegion: regionFrame,
            pixelsPerBeat: pixelsPerBeat,
            estimatedDurationBeats: estimatedDuration,
            startAlignmentPixels: alignment,
            geometryTolerancePixels: ACEAudioDeltaAdoptionContract.defaultGeometryTolerancePixels,
            durationToleranceBeats: ACEAudioDeltaAdoptionContract.defaultDurationToleranceBeats,
            basis: "bar+1 minus bar+0 AX playhead midpoint divided by beats_per_bar; native region AX frame width divided by measured pixels-per-beat; when automatic_time_stretch=false, native duration is accepted without resizing; tick=0 is the exact requested beat boundary",
            observedAt: Date()
        ))
    }

    private func adoptionSpec(from params: [String: String]) -> ACEAudioDeltaAdoptionSpec? {
        guard let json = params["spec_json"],
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ACEAudioDeltaAdoptionSpec.self, from: data)
    }

    private func adoptionSnapshot() -> ACEPlacementSnapshot? {
        guard let window = AXLogicProElements.mainWindow(),
              let observed = observedProject(from: window) else { return nil }
        let tracks = AXLogicProElements.allTrackHeaders().enumerated().map {
            AXValueExtractors.extractTrackState(
                from: $0.element,
                index: $0.offset,
                projectIdentity: observed.projectIdentity
            )
        }
        let rows = AXLogicProElements.allTrackContentRows()
        guard !tracks.isEmpty, rows.count >= tracks.count else { return nil }
        let regions = rows.enumerated().flatMap { index, row -> [RegionState] in
            guard index < tracks.count else { return [] }
            return AXValueExtractors.extractRegions(
                from: row,
                trackIndex: index,
                trackName: tracks[index].name,
                projectIdentity: observed.projectIdentity,
                trackStableID: tracks[index].stableID
            )
        }
        return ACEPlacementSnapshot(
            observedAt: Date(),
            projectPath: observed.path,
            projectSHA256: observed.digest,
            generation: 1,
            tracks: tracks,
            regions: regions
        )
    }

    private func observedProject(from window: AXUIElement) -> ResolvedAXDocument? {
        let document = AXHelpers.getDocumentURLString(window)
        let title = AXHelpers.getTitle(window)
        return AXDocumentProjectResolver.resolve(document: document, windowTitle: title)
    }

    private func observedProject(from snapshot: ACEPlacementSnapshot) -> ResolvedAXDocument? {
        guard ACEFileDigest.isSHA256(snapshot.projectSHA256) else { return nil }
        return ResolvedAXDocument(path: snapshot.projectPath, digest: snapshot.projectSHA256)
    }

    private func selectOnlyRegion(
        _ target: AXUIElement,
        trackIndex: Int,
        regionIndex: Int,
        expectedName: String,
        expectedProjectPath: String
    ) -> Bool {
        let allItems = AXLogicProElements.regionItems()
        guard allItems.count >= 2 else {
            return false
        }
        guard trackIndex >= 0,
              let trackHeader = AXLogicProElements.findTrackHeader(at: trackIndex) else {
            return false
        }
        let rows = AXLogicProElements.allTrackContentRows()
        let targetFlatIndex = rows.prefix(trackIndex).reduce(0) { partial, row in
            partial + AXHelpers.getChildren(row).filter { AXHelpers.getRole($0) == "AXLayoutItem" }.count
        } + regionIndex
        guard targetFlatIndex >= 0, targetFlatIndex < allItems.count else { return false }

        enum SelectionPass {
            case allFalseThenTargetTrue
            case allTrueThenTargetFalse
            case targetTrueThenOthersFalse
            case targetFalseThenOthersTrue
            case targetTrueOnly
            case targetFalseOnly
        }
        let passes: [SelectionPass] = [
            .allFalseThenTargetTrue,
            .allTrueThenTargetFalse,
            .targetTrueThenOthersFalse,
            .targetFalseThenOthersTrue,
            .targetTrueOnly,
            .targetFalseOnly,
        ]

        for pass in passes {
            guard documentIsOpen(expectedProjectPath),
                  ProcessUtils.activateLogicPro(),
                  documentIsOpen(expectedProjectPath),
                  AXHelpers.performAction(trackHeader, kAXPressAction),
                  documentIsOpen(expectedProjectPath) else { continue }
            Thread.sleep(forTimeInterval: 0.08)
            switch pass {
            case .allFalseThenTargetTrue:
                for item in allItems { _ = AXHelpers.setAttribute(item, kAXSelectedAttribute, kCFBooleanFalse) }
                _ = AXHelpers.setAttribute(allItems[targetFlatIndex], kAXSelectedAttribute, kCFBooleanTrue)
            case .allTrueThenTargetFalse:
                for item in allItems { _ = AXHelpers.setAttribute(item, kAXSelectedAttribute, kCFBooleanTrue) }
                _ = AXHelpers.setAttribute(allItems[targetFlatIndex], kAXSelectedAttribute, kCFBooleanFalse)
            case .targetTrueThenOthersFalse:
                _ = AXHelpers.setAttribute(allItems[targetFlatIndex], kAXSelectedAttribute, kCFBooleanTrue)
                for (index, item) in allItems.enumerated() where index != targetFlatIndex {
                    _ = AXHelpers.setAttribute(item, kAXSelectedAttribute, kCFBooleanFalse)
                }
            case .targetFalseThenOthersTrue:
                _ = AXHelpers.setAttribute(allItems[targetFlatIndex], kAXSelectedAttribute, kCFBooleanFalse)
                for (index, item) in allItems.enumerated() where index != targetFlatIndex {
                    _ = AXHelpers.setAttribute(item, kAXSelectedAttribute, kCFBooleanTrue)
                }
            case .targetTrueOnly:
                _ = AXHelpers.setAttribute(allItems[targetFlatIndex], kAXSelectedAttribute, kCFBooleanTrue)
            case .targetFalseOnly:
                _ = AXHelpers.setAttribute(allItems[targetFlatIndex], kAXSelectedAttribute, kCFBooleanFalse)
            }
            guard documentIsOpen(expectedProjectPath) else { return false }
            Thread.sleep(forTimeInterval: 0.15)

            let headers = AXLogicProElements.allTrackHeaders()
            var selected: [(String, Int, Int)] = []
            for (index, row) in AXLogicProElements.allTrackContentRows().enumerated() {
                let trackName = index < headers.count
                    ? AXValueExtractors.extractTrackState(from: headers[index], index: index).name
                    : ""
                for (offset, state) in AXValueExtractors.extractRegions(from: row, trackIndex: index, trackName: trackName).enumerated()
                    where state.isSelected {
                    selected.append((state.name, index, offset))
                }
            }
            let verified = selected.count == 1
                && selected[0].0 == expectedName
                && selected[0].1 == trackIndex
                && selected[0].2 == regionIndex
            Log.info(
                "P5G exact selection pass=" + String(describing: pass)
                    + " verified=" + String(verified)
                    + " selected_count=" + String(selected.count)
                    + " rows=" + selected.map { "\($0.1):\($0.2):\($0.0)" }.joined(separator: ","),
                subsystem: "aceAdoption"
            )
            if verified && documentIsOpen(expectedProjectPath) { return true }
        }
        return false
    }

    private func postDeleteAction(
        selectedRegion: AXUIElement,
        expectedRegionName: String,
        expectedProjectPath: String
    ) -> Bool {
        guard documentIsOpen(expectedProjectPath),
              AXValueExtractors.extractSelectedState(selectedRegion) == true,
              ProcessUtils.activateLogicPro(),
              documentIsOpen(expectedProjectPath),
              let editMenu = AXLogicProElements.menuItem(path: ["Edit"]),
              AXHelpers.getTitle(editMenu) == "Edit",
              AXHelpers.performAction(editMenu, kAXPressAction),
              documentIsOpen(expectedProjectPath) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard let deleteItem = AXLogicProElements.menuItem(path: ["Edit", "Delete"]) else {
            return false
        }
        let issues = ACEExactAXActionContract.validateDeletePrecondition(
            observedProjectPath: observedDocumentPath(),
            expectedProjectPath: expectedProjectPath,
            selectedRegionName: AXValueExtractors.extractTextValue(selectedRegion)
                ?? AXHelpers.getDescription(selectedRegion),
            expectedRegionName: expectedRegionName,
            selectedRegionCount: selectedRegionCount(),
            menuTitle: AXHelpers.getTitle(deleteItem),
            menuRole: AXHelpers.getRole(deleteItem),
            menuActions: AXHelpers.actionNames(deleteItem)
        )
        guard issues.isEmpty,
              AXHelpers.getBooleanAttribute(deleteItem, kAXEnabledAttribute) != false,
              AXHelpers.performAction(deleteItem, kAXPressAction) else {
            return false
        }
        // A successful exact delete must leave the same disposable document
        // open. If the document vanished, report an unknown mutation and stop
        // before any tag/save/bounce action can run.
        return documentIsOpen(expectedProjectPath)
    }

    private func setAndConfirmAdoptionName(
        _ field: AXUIElement,
        name: String,
        expectedCurrentName: String,
        expectedProjectPath: String
    ) -> Bool {
        guard documentIsOpen(expectedProjectPath),
              AXHelpers.getRole(field) == kAXTextFieldRole || AXHelpers.getRole(field) == kAXStaticTextRole else {
            return false
        }
        let observedNames = [
            AXValueExtractors.extractTextValue(field),
            AXHelpers.getDescription(field),
            AXHelpers.getTitle(field),
        ].compactMap { $0 }
        guard observedNames.contains(expectedCurrentName) else { return false }
        guard ProcessUtils.activateLogicPro(),
              documentIsOpen(expectedProjectPath),
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
              displayCount > 0 else { return false }
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else { return false }
        let visibleFrames = displayIDs.compactMap { displayID -> CGRect? in
            let intersection = CGDisplayBounds(displayID).intersection(fieldRect)
            return intersection.width > 0 && intersection.height > 0 ? intersection : nil
        }
        guard let visibleFrame = visibleFrames.max(by: {
            ($0.width * $0.height) < ($1.width * $1.height)
        }) else { return false }
        let point = CGPoint(
            x: visibleFrame.minX + min(20.0, visibleFrame.width / 2.0),
            y: visibleFrame.midY
        )
        guard postAdoptionMouseClick(source, at: point, clickState: 1),
              documentIsOpen(expectedProjectPath) else { return false }
        Thread.sleep(forTimeInterval: 0.1)
        guard postAdoptionMouseClick(source, at: point, clickState: 2),
              documentIsOpen(expectedProjectPath) else { return false }
        guard let app = AXLogicProElements.appRoot(),
              let focusedField: AXUIElement = AXHelpers.getAttribute(
                  app,
                  kAXFocusedUIElementAttribute
              ),
              AXHelpers.getRole(focusedField) == kAXTextFieldRole,
              AXValueExtractors.extractTextValue(focusedField) == expectedCurrentName else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.15)
        postAdoptionKey(source, keyCode: 0, flags: .maskCommand)
        postAdoptionText(source, text: name)
        postAdoptionKey(source, keyCode: 36)
        guard documentIsOpen(expectedProjectPath) else { return false }
        for attempt in 0..<12 {
            let activeField: AXUIElement = AXHelpers.getAttribute(
                app,
                kAXFocusedUIElementAttribute
            ) ?? field
            if AXValueExtractors.extractTextValue(activeField) == name
                || AXHelpers.getDescription(activeField) == name
                || AXValueExtractors.extractTextValue(field) == name
                || AXHelpers.getDescription(field) == name {
                return true
            }
            if attempt < 11 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return false
    }

    private func postAdoptionMouseClick(
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
        ) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postAdoptionKey(
        _ source: CGEventSource,
        keyCode: CGKeyCode,
        flags: CGEventFlags = []
    ) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postAdoptionText(_ source: CGEventSource, text: String) {
        var unicode = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        unicode.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func documentIsOpen(_ expectedProjectPath: String) -> Bool {
        observedDocumentPath() == ACEFileDigest.normalizedPath(expectedProjectPath)
    }

    private func observedDocumentPath() -> String? {
        guard let window = AXLogicProElements.frontProjectWindow() else { return nil }
        return observedProject(from: window)?.path
    }

    private func selectedRegionCount() -> Int {
        AXLogicProElements.allTrackContentRows().enumerated().reduce(0) { count, entry in
            let (trackIndex, row) = entry
            let trackName = AXLogicProElements.findTrackHeader(at: trackIndex).map {
                AXValueExtractors.extractTrackState(from: $0, index: trackIndex).name
            } ?? ""
            return count + AXValueExtractors.extractRegions(
                from: row,
                trackIndex: trackIndex,
                trackName: trackName
            ).filter(\.isSelected).count
        }
    }

    private func waitForTaggedTrack(_ tag: String, expectedProjectPath: String) -> Bool {
        for attempt in 0..<12 {
            if documentIsOpen(expectedProjectPath),
               let snapshot = adoptionSnapshot(),
               snapshot.tracks.filter({ OperationTagIdentity.operationTag(in: $0.name) == tag }).count == 1 {
                return true
            }
            if attempt < 11 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return false
    }

    private func waitForTaggedRegion(
        _ tag: String,
        sourceBaseName: String,
        sourceDigest: String,
        expectedProjectPath: String
    ) -> Bool {
        for attempt in 0..<12 {
            if documentIsOpen(expectedProjectPath),
               let snapshot = adoptionSnapshot(),
               snapshot.regions.filter({
                   OperationTagIdentity.operationTag(in: $0.name) == tag
                       && $0.name.contains(sourceBaseName)
                       && $0.name.contains(sourceDigest)
               }).count == 1 {
                return true
            }
            if attempt < 11 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return false
    }

    private func setPlayhead(
        _ sliders: (bar: AXUIElement, beat: AXUIElement),
        bar: Int,
        beat: Double
    ) -> Bool {
        guard AXHelpers.setAttribute(sliders.bar, kAXValueAttribute, NSNumber(value: Double(bar))),
              AXHelpers.setAttribute(sliders.beat, kAXValueAttribute, NSNumber(value: beat)) else {
            return false
        }
        return playheadValues(sliders).map { $0.bar == Double(bar) && $0.beat == beat } ?? false
    }

    private func playheadValues(
        _ sliders: (bar: AXUIElement, beat: AXUIElement)
    ) -> (bar: Double, beat: Double)? {
        guard let bar = AXValueExtractors.extractSliderValue(sliders.bar),
              let beat = AXValueExtractors.extractSliderValue(sliders.beat) else { return nil }
        return (bar, beat)
    }

    private func encodeAdoptionStep(
        action: String,
        status: String,
        spec: ACEAudioDeltaAdoptionSpec,
        before: ACEPlacementSnapshot,
        after: ACEPlacementSnapshot,
        removedRegion: String?
    ) -> ChannelResult {
        let payload: [String: AnyCodableValue] = [
            "action": .string(action),
            "status": .string(status),
            "plan_id": .string(spec.planID),
            "operation_id": .string(spec.operationID),
            "before_track_count": .int(before.tracks.count),
            "before_region_count": .int(before.regions.count),
            "after_track_count": .int(after.tracks.count),
            "after_region_count": .int(after.regions.count),
            "removed_region": removedRegion.map(AnyCodableValue.string) ?? .null,
        ]
        return .success(AnyCodableValue.object(payload).json)
    }

    private func encodeGeometry(_ geometry: ACEAudioDeltaGeometry) -> ChannelResult {
        .success(encodeCompactJSON(geometry))
    }
}

private enum AnyCodableValue {
    case string(String)
    case int(Int)
    case null
    case object([String: AnyCodableValue])

    var json: String {
        switch self {
        case .string(let value):
            return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        case .int(let value): return String(value)
        case .null: return "null"
        case .object(let values):
            return "{\(values.keys.sorted().map { "\"\($0)\":\(values[$0]?.json ?? "null")" }.joined(separator: ","))}"
        }
    }
}
