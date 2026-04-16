# Receipt-Anchored Closeout

Use this runbook when a change updates truth surfaces such as `ROADMAP.md`, `session_state.md`, `README.md`, or durable framework docs with completion claims.

## Rule

If the diff adds completion-style claims, include a receipt anchor in the same batch.

Valid anchor examples:

- A closeout receipt created from `templates/closeout_receipt.template.md`
- A discussion packet that captures independent review evidence
- A handoff packet that truthfully records partial completion and next action

## Claim Examples

- `✅`
- `已完成`
- `completed`
- `validation passed`

## Audit Script

Run `python3 Scripts/closeout_truth_audit.py` to inspect the current staged diff, or the working tree diff if nothing is staged.

Run `python3 Scripts/closeout_truth_audit.py --self-test` to verify the checker logic itself.