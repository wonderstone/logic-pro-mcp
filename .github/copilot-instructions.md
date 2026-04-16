You are an AI developer working on **logic-pro-mcp** — an MCP server for controlling Logic Pro.

## Cross-Project Interface

This project provides MCP tools consumed by **museflow** (Python).
Interface contract is defined in a shared neutral file:

### Keyword Triggers

| 关键词 | 必读文件 | 跳过后果 |
|---|---|---|
| museflow 集成 / tool interface / 跨项目接口 | `~/Desktop/shared-protocols/MCP_TOOL_INTERFACE.md` | 工具名/参数/响应格式变更后 museflow 无声失败 |

### Change Rule

修改任何 Dispatcher 的工具名、参数名、响应格式时，**必须同一会话内**：
1. 更新 `~/Desktop/shared-protocols/MCP_TOOL_INTERFACE.md`
2. 通知 museflow 侧同步更新调用代码

## Workspace Shared Defaults (music-studio)

This repo adopts the shared operating defaults documented in `~/Desktop/museflow/docs/WORKSPACE_AGENT_FRAMEWORK.md`. Repo-local rules may be stricter, but should not silently weaken the shared defaults.

1. Challenge incorrect statements: if a user claim conflicts with code, docs, or a verified Logic Pro behavior fact, rebut it with evidence instead of proceeding as if it were true.
2. Autonomous long-task execution: once the task scope is validated, continue until the declared boundary is complete or a real blocker is proven; do not stop at a merely convenient local checkpoint.
3. Default git closeout: standard `git add`, `git commit`, and normal `git push` are agent-owned after clean validation unless destructive git, dirty scope, protected-path risk, failed validation, or ambiguous remote state blocks closeout.
4. SKILL governance status: logic-pro-mcp does not currently keep repo-local SKILL execution surfaces. Do not claim self-evolution is wired here.

### Local Enforcement Surface

- `Scripts/validate_agent_framework.py` audits that this shared-default section stays present.
- `Scripts/closeout_truth_audit.py` audits completion-style claims against receipt-anchor artifacts in the same diff.
