import Foundation
import MCP

/// Registers MCP resources for zero-cost state reads.
/// Resources are URI-addressable data pulled on demand — they don't appear in the tool list.
struct ResourceProvider {
    static let resources: [Resource] = [
        Resource(
            name: "Transport State",
            uri: "logic://transport/state",
            description: "Current transport state: playing, recording, tempo, position, cycle, metronome",
            mimeType: "application/json"
        ),
        Resource(
            name: "Tracks",
            uri: "logic://tracks",
            description: "All tracks: name, type, index, mute/solo/arm states",
            mimeType: "application/json"
        ),
        Resource(
            name: "Mixer",
            uri: "logic://mixer",
            description: "All channel strips: volume, pan, plugins, sends",
            mimeType: "application/json"
        ),
        Resource(
            name: "Project Info",
            uri: "logic://project/info",
            description: "Project name, sample rate, time signature, track count",
            mimeType: "application/json"
        ),
        Resource(
            name: "Selection",
            uri: "logic://selection",
            description: "Current visible track/region selection summary",
            mimeType: "application/json"
        ),
        Resource(
            name: "Context",
            uri: "logic://context",
            description: "Current Logic Pro window/view context and visible scope summary",
            mimeType: "application/json"
        ),
        Resource(
            name: "Editor State",
            uri: "logic://editor",
            description: "Current Event List editor scope summary, including visible note-row count and write-mode caveats",
            mimeType: "application/json"
        ),
        Resource(
            name: "Editor Notes",
            uri: "logic://editor/notes",
            description: "Visible Event List note rows in the current editor scope",
            mimeType: "application/json"
        ),
        Resource(
            name: "MIDI Bridge Capabilities",
            uri: "logic://bridge/capabilities",
            description: "Current MIDI export/import bridge capabilities and caveats",
            mimeType: "application/json"
        ),
        Resource(
            name: "MIDI Bridge Last Export",
            uri: "logic://bridge/last-export",
            description: "Receipt for the last export_selected_midi_bridge command",
            mimeType: "application/json"
        ),
        Resource(
            name: "Regions",
            uri: "logic://regions",
            description: "Visible regions grouped across the current track contents area",
            mimeType: "application/json"
        ),
        Resource(
            name: "MIDI Ports",
            uri: "logic://midi/ports",
            description: "Available MIDI ports (system + virtual)",
            mimeType: "application/json"
        ),
        Resource(
            name: "System Health",
            uri: "logic://system/health",
            description: "Channel status, cache freshness, permission state",
            mimeType: "application/json"
        ),
    ]

    static let templates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: "logic://tracks/{index}",
            name: "Track Detail",
            description: "Single track detail by index (including automation mode)",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://regions/{index}",
            name: "Track Regions",
            description: "Visible regions for one track by index",
            mimeType: "application/json"
        ),
    ]
}
