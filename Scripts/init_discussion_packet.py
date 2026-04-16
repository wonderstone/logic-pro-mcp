from __future__ import annotations

import argparse
from pathlib import Path
import sys


CLI_NAMES = ["Codex", "Claude Code", "Copilot", "Gemini"]


def build_packet(task_id: str, question: str, scope: str, truth_sources: list[str]) -> str:
    repo_name = Path.cwd().name
    truth_block = "\n".join(f"- {item}" for item in truth_sources) or "-"
    cli_sections = "\n\n".join(
        f"## {name}\n\n- Summary:\n- Findings:\n- Risks:\n- Recommendation:"
        for name in CLI_NAMES
    )
    return f"""# Discussion Packet\n\n- Task ID: {task_id}\n- Decision Question: {question}\n- Repo Scope: {scope or repo_name}\n- Truth Sources:\n{truth_block}\n- Expected Outcome:\n- Read-Only Rule: Each CLI must answer in read-only mode and state uncertainty explicitly.\n- Participating CLIs: {' / '.join(CLI_NAMES)}\n\n## Shared Prompt\n\nUse the same question and the same truth sources for every CLI.\n\n{cli_sections}\n\n## Main-Thread Synthesis\n\n- Converging Points:\n- Diverging Points:\n- Final Decision:\n- Next Action:\n"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Initialize a multi-CLI discussion packet.")
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--question", required=True)
    parser.add_argument("--scope", default="")
    parser.add_argument("--truth-source", action="append", default=[])
    parser.add_argument("--output")
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args()

    packet = build_packet(args.task_id, args.question, args.scope, args.truth_source)
    if args.stdout or not args.output:
        sys.stdout.write(packet)
        return 0

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(packet, encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())