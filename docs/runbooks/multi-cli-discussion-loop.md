# Multi-CLI Discussion Loop

Use this runbook when the task is design-heavy, directionally ambiguous, or needs independent read-only critique before implementation or closeout.

## Local Executors

This machine currently has four CLI executors available for the loop:

- `Codex`
- `Claude Code`
- `Copilot`
- `Gemini`

If one executor is unavailable, mark it explicitly. Do not fabricate a response.

## Workflow

1. Create a packet from `templates/discussion_packet.template.md`.
2. Freeze the exact decision question, repo scope, and truth sources.
3. Ask all four CLIs the same question in read-only mode.
4. Append each answer into its own section without rewriting the source meaning.
5. Write a main-thread synthesis that names converging points, disagreements, and the chosen direction.
6. If execution continues across sessions, link the packet from the handoff packet.

## Good Uses

- MCP interface changes with cross-project impact.
- State/cache or routing changes with multiple valid designs.
- Framework adoption or closeout-quality review.

## Bad Uses

- One-file fixes with no design ambiguity.
- Cases where the question is too vague to produce useful comparison.