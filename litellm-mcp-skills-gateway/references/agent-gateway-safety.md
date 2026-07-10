# Agent Gateway Safety

Use this when combining MCP, Skills Gateway, agents, and LiteLLM operational controls.

## MCP Configuration Gap

When a concrete MCP server config is not available, use official LiteLLM MCP docs for exact schema, then apply the operational controls for keys, budgets, logs, and backups.

## Control Layers

- Virtual key allowlists limit which model aliases an agent can call.
- Budgets and `budget_duration` limit blast radius.
- MCP permissions limit which servers and tools are visible.
- Tool permission guardrails limit generated tool calls.
- MCP guardrails inspect MCP input/execution.
- Observability ties actions back to key, team, agent, request, and tool.
- Backups and export manifests provide rollback evidence for admin changes.

## Safe Official Skills Usage

Official `litellm-skills` can manage live proxy resources. Use them safely:

1. Install or invoke them first against a test proxy.
2. Use least-privilege admin credentials where possible.
3. Require a dry-run or explicit change list for destructive operations.
4. Log users, teams, keys, models, MCP servers, agents, and usage changes.
5. Keep rollback steps next to the operation, especially for key deletion and model removal.

## Review Checklist

- The agent can see only the MCP tools needed for the task.
- Write/delete/external-send tools have parameter constraints.
- Tool-call logs do not contain raw secrets or unnecessary prompt content.
- Admin actions are separated from normal inference keys.
- Budget and usage reporting can identify runaway agent behavior quickly.
