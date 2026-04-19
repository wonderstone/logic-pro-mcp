import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot() -> AXUIElement? {
        guard let pid = ProcessUtils.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid)
    }

    /// Get the main window element.
    static func mainWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMainWindowAttribute)
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro's transport is typically an AXToolbar or AXGroup near the top
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole) {
            return toolbar
        }
        // Fallback: search for a group containing transport-like buttons
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport")
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String) -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: name) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            if AXHelpers.getDescription(button) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the container that holds track header items.
    private static func trackHeaderContainer() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 8)
        if let headerGroup = groups.first(where: {
            (AXHelpers.getDescription($0) ?? "").localizedCaseInsensitiveContains("Tracks header")
        }) {
            return headerGroup
        }

        if let area = AXHelpers.findDescendant(of: window, role: kAXListRole, identifier: "Track Headers") {
            return area
        }
        if let area = AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Tracks") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXOutlineRole, maxDepth: 5)
    }

    /// Find the track header area containing individual track rows.
    static func getTrackHeaders() -> AXUIElement? {
        trackHeaderContainer()
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int) -> AXUIElement? {
        let headers = allTrackHeaders()
        guard index >= 0 && index < headers.count else { return nil }
        return headers[index]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders() -> [AXUIElement] {
        guard let container = trackHeaderContainer() else { return [] }

        let directChildren = AXHelpers.getChildren(container)
        let layoutItems = directChildren.filter { AXHelpers.getRole($0) == "AXLayoutItem" }
        if !layoutItems.isEmpty {
            return layoutItems
        }

        let rowLikeChildren = directChildren.filter {
            guard let role = AXHelpers.getRole($0) else { return false }
            return role == kAXRowRole || role == kAXGroupRole
        }
        if !rowLikeChildren.isEmpty {
            return rowLikeChildren
        }

        let descendantLayoutItems = AXHelpers.findAllDescendants(of: container, role: "AXLayoutItem", maxDepth: 4)
        if !descendantLayoutItems.isEmpty {
            return descendantLayoutItems
        }

        return AXHelpers.findAllDescendants(of: container, role: kAXRowRole, maxDepth: 4)
    }

    /// Find the container that holds visible track content rows and regions.
    static func getTrackContents() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 10)
        return groups.first(where: {
            (AXHelpers.getDescription($0) ?? "").localizedCaseInsensitiveContains("Tracks contents")
        })
    }

    /// Enumerate visible content rows for each track in the current Tracks view.
    static func allTrackContentRows() -> [AXUIElement] {
        guard let contents = getTrackContents() else { return [] }
        return AXHelpers.getChildren(contents).filter {
            AXHelpers.getRole($0) == "AXLayoutArea"
        }
    }

    /// Find the visible content row for a given track index.
    static func findTrackContentRow(at index: Int) -> AXUIElement? {
        let rows = allTrackContentRows()
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    // MARK: - Event List

    /// Find the current Event List window if it is open.
    static func eventListWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute) ?? []
        return windows.first(where: {
            (AXHelpers.getTitle($0) ?? "").localizedCaseInsensitiveContains("Event List")
        })
    }

    /// Find the AXTable inside the Event List window.
    static func eventListTable() -> AXUIElement? {
        guard let window = eventListWindow() else { return nil }
        return AXHelpers.findDescendant(of: window, role: kAXTableRole, maxDepth: 10)
    }

    /// Enumerate the visible rows in the Event List table.
    static func eventListRows() -> [AXUIElement] {
        guard let table = eventListTable() else { return [] }
        return AXHelpers.getChildren(table).filter {
            AXHelpers.getRole($0) == kAXRowRole
        }
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // The mixer typically appears as a distinct group/scroll area
        if let mixer = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Mixer") {
            return mixer
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Mixer")
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Fader is an AXSlider within the channel strip
        return AXHelpers.findDescendant(of: strip, role: kAXSliderRole, maxDepth: 4)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Pan is typically the second slider or a knob-type element
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        // Convention: first slider = volume, second = pan (if present)
        return sliders.count > 1 ? sliders[1] : nil
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String]) -> AXUIElement? {
        guard var current = getMenuBar() else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Arrangement") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Arrangement")
    }

    // MARK: - Track Controls

    /// Find the mute button on a track header.
    static func findTrackMuteButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Mute")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "M")
    }

    /// Find the solo button on a track header.
    static func findTrackSoloButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Solo")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "S")
    }

    /// Find the record-arm button on a track header.
    static func findTrackArmButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Record")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "R")
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4)
            ?? AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4)
    }

    // MARK: - Helpers

    private static func findButtonByDescriptionPrefix(
        in element: AXUIElement, prefix: String
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button) else { return false }
            return desc.hasPrefix(prefix)
        }
    }
}
