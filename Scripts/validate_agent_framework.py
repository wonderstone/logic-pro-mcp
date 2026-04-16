from __future__ import annotations

from pathlib import Path
import sys


REQUIRED_FILES = [
    ".github/instructions/project-context.instructions.md",
    ".github/agents/architect.agent.md",
    ".github/agents/implementer.agent.md",
    "docs/DOC_FIRST_EXECUTION_GUIDELINES.md",
    "templates/execution_contract.template.md",
    "templates/execution_progress_receipt.template.md",
    "templates/handoff_packet.template.md",
    "templates/discussion_packet.template.md",
    "templates/closeout_receipt.template.md",
    "docs/runbooks/multi-cli-discussion-loop.md",
    "docs/runbooks/receipt-anchored-closeout.md",
    "Scripts/validate_agent_framework.py",
    "Scripts/init_discussion_packet.py",
    "Scripts/closeout_truth_audit.py",
    "ROADMAP.md",
    "session_state.md",
]

PLACEHOLDER_MARKERS = [
    "<TARGET_REPO_PATH>",
    "<PROJECT_NAME>",
    "[placeholders]",
]

CLI_NAMES = ["Codex", "Claude Code", "Copilot", "Gemini"]

REQUIRED_TEXT_MARKERS = {
    ".github/copilot-instructions.md": [
        "## Workspace Shared Defaults (music-studio)",
        "Default git closeout",
        "SKILL governance status",
        "Scripts/validate_agent_framework.py",
        "Scripts/closeout_truth_audit.py",
    ],
}


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    missing = [path for path in REQUIRED_FILES if not (root / path).exists()]
    issues: list[str] = []

    for rel_path in REQUIRED_FILES:
        file_path = root / rel_path
        if not file_path.exists() or not file_path.is_file():
            continue
        text = file_path.read_text(encoding="utf-8")
        if rel_path.endswith((".instructions.md", ".agent.md")) and "description:" not in text:
            issues.append(f"{rel_path}: missing description frontmatter")
        if rel_path != "Scripts/validate_agent_framework.py":
            for marker in PLACEHOLDER_MARKERS:
                if marker in text:
                    issues.append(f"{rel_path}: contains placeholder {marker}")

    discussion_template = (root / "templates/discussion_packet.template.md").read_text(encoding="utf-8")
    for cli_name in CLI_NAMES:
        if cli_name not in discussion_template:
            issues.append(f"templates/discussion_packet.template.md: missing CLI section {cli_name}")

    for rel_path, markers in REQUIRED_TEXT_MARKERS.items():
        file_path = root / rel_path
        if not file_path.exists() or not file_path.is_file():
            continue
        text = file_path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                issues.append(f"{rel_path}: missing marker {marker}")

    if missing or issues:
        if missing:
            print("Missing required files:")
            for item in missing:
                print(f"- {item}")
        if issues:
            print("Framework issues:")
            for item in issues:
                print(f"- {item}")
        return 1

    print("Agent framework validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())