# OpenCode Spike Results

Date: 2026-06-25

Fixture used:

- `OPENCODE_CONFIG_DIR=/tmp/opencode/spike-forge`
- `OPENCODE_CONFIG=/tmp/opencode/spike-forge/opencode.json`
- Agents: `orchestrator` (`openai/gpt-5.4`, primary) and `worker` (`openai/gpt-5.4-mini-fast`, subagent)

## 1. Subagent delegation

Verdict: PASS

Observed invocation paths:

- Manual prompt syntax seen by the primary agent: `@worker`
- Runtime tool used by OpenCode for the actual delegation: `task`

Concrete command:

```bash
OPENCODE_CONFIG_DIR="/tmp/opencode/spike-forge" \
OPENCODE_CONFIG="/tmp/opencode/spike-forge/opencode.json" \
opencode run --agent orchestrator --dangerously-skip-permissions \
  "Delegate to @worker and return the worker output only."
```

Observed result:

- Final response: `WORKER_OK`
- Session export showed a `tool: task` call with `subagent_type: "worker"`
- Worker model recorded in export metadata: `openai/gpt-5.4-mini-fast`

## 2. Plugin tool veto

Verdict: PASS

Observed hook and abort mechanism:

- Hook name: `tool.execute.before`
- Abort mechanism: throw `new Error(...)` from the hook
- Plugin format requirement: ESM export (`export default async function ...`)

Concrete command:

```bash
OPENCODE_CONFIG_DIR="/tmp/opencode/spike-forge" \
OPENCODE_CONFIG="/tmp/opencode/spike-forge/opencode.json" \
opencode run --print-logs --log-level DEBUG --agent orchestrator \
  --dangerously-skip-permissions "Run pwd and tell me the result."
```

Observed result:

- OpenCode printed `pwd failed`
- Error surfaced as `Error: SPIKE_VETO_OK`
- The guarded `pwd` bash tool call did not execute

## 3. Isolated config loading

Verdict: PASS

Concrete commands:

```bash
OPENCODE_CONFIG_DIR="/tmp/opencode/spike-forge" \
OPENCODE_CONFIG="/tmp/opencode/spike-forge/opencode.json" \
opencode agent list
```

```bash
OPENCODE_CONFIG_DIR="/tmp/opencode/spike-forge" \
OPENCODE_CONFIG="/tmp/opencode/spike-forge/opencode.json" \
opencode debug config
```

Observed result:

- `opencode agent list` resolved custom agents `orchestrator` and `worker`
- `opencode debug config` showed plugin origin `file:///tmp/opencode/spike-forge/plugins/veto.js`
- Debug logs explicitly showed both:
  - `loading config from OPENCODE_CONFIG_DIR`
  - `loaded custom config` from `/tmp/opencode/spike-forge/opencode.json`
- No writes to the user's global OpenCode agent/plugin/config files were required

## 4. Cost parity

Verdict: LIMITED

Data sources validated:

```bash
opencode stats --models --days 1
```

```bash
opencode export ses_1005c3a3cffegHe8BjD5iHSttY
```

Observed result:

- `opencode stats` provides native per-model usage and cost totals
- `opencode export` provides per-session model, token, cache, and delegated subtask metadata
- This is sufficient for OpenCode-native reporting
- This is NOT RTK-compatible request telemetry and should not be documented as RTK proxy parity

## Gate decision

- Subagent delegation: PASS
- Plugin tool veto: PASS
- Isolated config loading: PASS
- Cost parity: LIMITED

Gate result: PROCEED
