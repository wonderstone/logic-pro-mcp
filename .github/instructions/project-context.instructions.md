---
description: "Project adapter for logic-pro-mcp. Use when working on Logic Pro MCP tools, dispatchers, resources, channel routing, state cache, permissions, build/test flow, or MCP interface changes in the music-studio workspace."
---

# logic-pro-mcp Project Context

## Project Map

- `Sources/LogicProMCP/Dispatchers/`: MCP tool entrypoints and interface surface.
- `Sources/LogicProMCP/Resources/`: read-only MCP resources.
- `Sources/LogicProMCP/Channels/`: routing and transport across CoreMIDI, AX, CGEvent, AppleScript, and OSC.
- `Sources/LogicProMCP/State/`: state cache and adaptive polling.
- `Tests/LogicProMCPTests/`: Swift tests.
- `Scripts/`: installer and setup helpers.

## Critical Topic Triggers

- `tool interface`, `dispatcher`, `museflow integration`, `MCP contract`: read `~/Desktop/shared-protocols/MCP_TOOL_INTERFACE.md` before changing names, params, or response shape.
- `bounce`, `render`, `logic pro automation`: read `README.md` and the relevant dispatcher/channel files.
- `state`, `cache`, `poller`, `resource`: read `Sources/LogicProMCP/State/` and `Sources/LogicProMCP/Resources/`.
- `permissions`, `health`, `check-permissions`: inspect `main.swift`, `Utilities/`, and `logic://system/health` implementation.

## Build And Test Commands

- Build debug: `swift build`
- Build release: `swift build -c release`
- Run tests: `swift test`
- Permission check: `.build/debug/LogicProMCP --check-permissions`
- Framework validation: `python3 Scripts/validate_agent_framework.py`
- Closeout audit self-test: `python3 Scripts/closeout_truth_audit.py --self-test`
- Discussion packet smoke: `python3 Scripts/init_discussion_packet.py --task-id smoke --question "smoke" --stdout`

## Protected Paths

- `manifest.json`: public MCP manifest surface.
- `Package.swift`: dependency and build contract.
- `Sources/LogicProMCP/Dispatchers/`: interface changes here may require shared-protocol updates.

## Developer Toolchain

- Diagnostics: `swift test`, build errors, and targeted file review.
- Repro: smallest dispatcher command or resource path that reproduces behavior.
- Build: `swift build` or `swift build -c release`.
- Verify: `swift test` plus any focused manual Logic Pro permission or smoke path when needed.

## Execution Surfaces

- Long tasks should start from `templates/execution_contract.template.md`.
- Mid-task checkpoints should use `templates/execution_progress_receipt.template.md`.
- Interrupted or multi-executor work should hand off with `templates/handoff_packet.template.md`.
- Multi-CLI design or review loops should start from `templates/discussion_packet.template.md` and `docs/runbooks/multi-cli-discussion-loop.md`.
- Closeout claims should be anchored by `templates/closeout_receipt.template.md` and checked with `Scripts/closeout_truth_audit.py`.
- Available local CLI executors are `Codex`, `Claude Code`, `Copilot`, and `Gemini`.
- Use `ROADMAP.md` and `session_state.md` to keep repo-local progress reconstructable.