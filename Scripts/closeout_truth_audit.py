from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys


CLAIM_MARKERS = [
    "✅",
    "已完成",
    "completed",
    "done",
    "validation passed",
    "通过",
]

TRUTH_FILE_HINTS = {
    "ROADMAP.md",
    "session_state.md",
    "README.md",
    "WORKSPACE_AGENT_FRAMEWORK.md",
    "DOC_FIRST_EXECUTION_GUIDELINES.md",
}

ANCHOR_HINTS = ["receipt", "handoff", "discussion", "verification"]


@dataclass
class AuditResult:
    claim_files: set[str]
    anchor_files: set[str]

    @property
    def is_valid(self) -> bool:
        return not self.claim_files or bool(self.anchor_files)


def is_truth_file(path: str) -> bool:
    return Path(path).name in TRUTH_FILE_HINTS


def is_anchor_file(path: str) -> bool:
    lowered = path.lower()
    if "/templates/" in lowered or lowered.startswith("templates/"):
        return False
    return any(hint in lowered for hint in ANCHOR_HINTS)


def parse_diff(diff_text: str) -> AuditResult:
    current_file = ""
    claim_files: set[str] = set()
    anchor_files: set[str] = set()

    for raw_line in diff_text.splitlines():
        if raw_line.startswith("+++ b/"):
            current_file = raw_line[6:]
            if is_anchor_file(current_file):
                anchor_files.add(current_file)
            continue
        if raw_line.startswith("+++ "):
            current_file = ""
            continue
        if not current_file or not raw_line.startswith("+") or raw_line.startswith("+++"):
            continue
        if not is_truth_file(current_file):
            continue
        added_text = raw_line[1:].strip().lower()
        if any(marker.lower() in added_text for marker in CLAIM_MARKERS):
            claim_files.add(current_file)

    return AuditResult(claim_files=claim_files, anchor_files=anchor_files)


def load_git_diff() -> str:
    commands = [
        ["git", "diff", "--cached", "--unified=0", "--no-color"],
        ["git", "diff", "--unified=0", "--no-color"],
    ]
    for command in commands:
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        if completed.returncode == 0 and completed.stdout.strip():
            return completed.stdout
    return ""


def run_self_test() -> int:
    cases = [
        (
            "claim without anchor",
            "diff --git a/ROADMAP.md b/ROADMAP.md\n+++ b/ROADMAP.md\n+| 1 | test | ✅ | note |\n",
            False,
        ),
        (
            "claim with receipt anchor",
            "diff --git a/ROADMAP.md b/ROADMAP.md\n+++ b/ROADMAP.md\n+| 1 | test | ✅ | note |\ndiff --git a/docs/archive/task_receipt.md b/docs/archive/task_receipt.md\n+++ b/docs/archive/task_receipt.md\n+# receipt\n",
            True,
        ),
        (
            "no claim",
            "diff --git a/README.md b/README.md\n+++ b/README.md\n+New paragraph without completion claim\n",
            True,
        ),
    ]
    for name, diff_text, expected in cases:
        result = parse_diff(diff_text)
        if result.is_valid != expected:
            print(f"Self-test failed: {name}")
            return 1
    print("Closeout truth audit self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit diff claims against receipt anchors.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    diff_text = load_git_diff()
    if not diff_text:
        print("No staged or working-tree diff to audit.")
        return 0

    result = parse_diff(diff_text)
    if result.is_valid:
        print("Closeout truth audit passed.")
        return 0

    print("Closeout truth audit failed.")
    print("Completion-style claims were added in:")
    for item in sorted(result.claim_files):
        print(f"- {item}")
    print("No receipt anchor file was found in the same diff.")
    print("Add a receipt, discussion packet, handoff packet, or verification packet before closeout.")
    return 1


if __name__ == "__main__":
    sys.exit(main())