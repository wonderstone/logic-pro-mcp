# Doc-First Execution Guidelines

Use a document-first flow for any non-trivial change to logic-pro-mcp.

## Required Before Implementation

- Define the target behavior and affected MCP surface.
- List the exact dispatchers, resources, channels, and state files in scope.
- State whether the change is interface-safe or requires shared-protocol sync.
- Define build, test, and manual Logic Pro verification.

## Stop Conditions

- Do not edit dispatchers on guesswork.
- Do not change tool names, params, or response shape without updating the shared protocol file in the same session.
- Do not claim success without build or targeted verification evidence.