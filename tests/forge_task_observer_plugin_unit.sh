#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
PLUGIN_PATH="$FORGE_ROOT/open-code/plugins/forge-task-observer.js"
FAIL=0
PASS=0

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

# Runs a Node ESM script (read from stdin) against the plugin. The script
# receives TEST_PLUGIN_PATH and is expected to import the plugin, exercise it
# purely through its public `event` hook, and throw (non-zero exit) on any
# assertion failure. Output (stdout+stderr, including any assertion stack
# trace) is captured so callers can surface it on failure.
run_node() {
  TEST_PLUGIN_PATH="$PLUGIN_PATH" node --input-type=module
}

test_describe_error_basic_name_and_message() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-1", messageID: "msg-1", metadata: { sessionId: "child-1" } } },
} })

await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "child-1", error: { name: "APIError", data: { message: "boom" } } },
} })

assert.equal(emitted.length, 1, "expected exactly one marker emitted")
assert.match(emitted[0], /^FORGE_TASK_INFRA_ERROR: /)
const payload = JSON.parse(emitted[0].slice("FORGE_TASK_INFRA_ERROR: ".length))
assert.deepEqual(payload, {
  sessionID: "child-1",
  name: "APIError",
  message: "boom",
  taskCallID: "call-1",
})
NODE
)"; then
    pass "correlated session.error emits marker with name/message/taskCallID"
  else
    fail "correlated session.error did not emit the expected marker: $output"
  fi
}

test_describe_error_captures_api_fields_regardless_of_name() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-2", messageID: "msg-2", metadata: { sessionId: "child-2" } } },
} })

await hooks.event({ event: {
  type: "session.error",
  properties: {
    sessionID: "child-2",
    error: { name: "SomeUnverifiedName", data: { message: "rate limited", statusCode: 429, isRetryable: true } },
  },
} })

assert.equal(emitted.length, 1)
const payload = JSON.parse(emitted[0].slice("FORGE_TASK_INFRA_ERROR: ".length))
assert.equal(payload.statusCode, 429)
assert.equal(payload.isRetryable, true)
assert.equal(payload.streamAborted, undefined, "streamAborted should not be set for a non-MessageAbortedError")
NODE
)"; then
    pass "statusCode/isRetryable are captured by presence in data, not by exact name match"
  else
    fail "statusCode/isRetryable were not captured for an unverified error name: $output"
  fi
}

test_describe_error_message_aborted_sets_stream_aborted() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-3", messageID: "msg-3", metadata: { sessionId: "child-3" } } },
} })

await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "child-3", error: { name: "MessageAbortedError", data: {} } },
} })

assert.equal(emitted.length, 1)
const payload = JSON.parse(emitted[0].slice("FORGE_TASK_INFRA_ERROR: ".length))
assert.equal(payload.streamAborted, true)
assert.equal(payload.statusCode, undefined)
NODE
)"; then
    pass "MessageAbortedError sets streamAborted: true"
  else
    fail "MessageAbortedError did not set streamAborted: $output"
  fi
}

test_describe_error_defensive_fallback_for_non_object_error() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-4", messageID: "msg-4", metadata: { sessionId: "child-4" } } },
} })

// A truthy but non-object error (e.g. a bare string) must not throw and
// must fall back to the UnknownError/empty-message shape.
await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "child-4", error: "boom" },
} })

assert.equal(emitted.length, 1)
const payload = JSON.parse(emitted[0].slice("FORGE_TASK_INFRA_ERROR: ".length))
assert.equal(payload.name, "UnknownError")
assert.equal(payload.message, "")
NODE
)"; then
    pass "non-object error falls back to UnknownError/empty message without throwing"
  else
    fail "non-object error was not handled defensively: $output"
  fi
}

test_track_task_dispatch_ignores_non_task_tool() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "bash", callID: "call-5", messageID: "msg-5", metadata: { sessionId: "child-5" } } },
} })

await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "child-5", error: { name: "APIError", data: {} } },
} })

assert.equal(emitted.length, 0, "a non-task tool dispatch must not be correlated")
NODE
)"; then
    pass "non-task tool dispatches are not tracked"
  else
    fail "a non-task tool dispatch was unexpectedly correlated: $output"
  fi
}

test_track_task_dispatch_supports_sessionID_capitalized_variant() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

// metadata.sessionID (capital ID), not metadata.sessionId
await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-6", messageID: "msg-6", metadata: { sessionID: "child-6" } } },
} })

await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "child-6", error: { name: "APIError", data: {} } },
} })

assert.equal(emitted.length, 1)
const payload = JSON.parse(emitted[0].slice("FORGE_TASK_INFRA_ERROR: ".length))
assert.equal(payload.taskCallID, "call-6")
NODE
)"; then
    pass "metadata.sessionID (capitalized variant) is also correlated"
  else
    fail "the sessionID capitalized variant was not correlated: $output"
  fi
}

test_session_error_without_error_property_emits_nothing() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-7", messageID: "msg-7", metadata: { sessionId: "child-7" } } },
} })

await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "child-7" },
} })

assert.equal(emitted.length, 0)
NODE
)"; then
    pass "session.error with no error property emits nothing"
  else
    fail "session.error without an error property unexpectedly emitted a marker: $output"
  fi
}

test_session_error_uncorrelated_session_emits_nothing() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

// No task dispatch was ever tracked for this session (e.g. an error on the
// orchestrator's own root session): must be out of scope, silently.
await hooks.event({ event: {
  type: "session.error",
  properties: { sessionID: "root-session", error: { name: "APIError", data: {} } },
} })

assert.equal(emitted.length, 0)
NODE
)"; then
    pass "session.error on an uncorrelated (non-task) session emits nothing"
  else
    fail "an uncorrelated session unexpectedly emitted a marker: $output"
  fi
}

test_correlation_is_consumed_once() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

await hooks.event({ event: {
  type: "message.part.updated",
  properties: { part: { type: "tool", tool: "task", callID: "call-8", messageID: "msg-8", metadata: { sessionId: "child-8" } } },
} })

const errorEvent = { event: {
  type: "session.error",
  properties: { sessionID: "child-8", error: { name: "APIError", data: {} } },
} }

await hooks.event(errorEvent)
await hooks.event(errorEvent)

assert.equal(emitted.length, 1, "a second session.error for the same (already-consumed) session must not re-emit")
NODE
)"; then
    pass "correlation is consumed after the first emitted marker (no duplicate markers)"
  else
    fail "correlation was not consumed after the first marker: $output"
  fi
}

test_lru_eviction_bounds_the_tracked_map() {
  local output
  if output="$(run_node <<'NODE' 2>&1
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"

const { default: pluginFactory } = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const hooks = await pluginFactory()

const emitted = []
console.error = (msg) => { emitted.push(msg) }

function dispatch(sessionId, callID) {
  return hooks.event({ event: {
    type: "message.part.updated",
    properties: { part: { type: "tool", tool: "task", callID, messageID: `msg-${sessionId}`, metadata: { sessionId } },
    },
  } })
}

// MAX_TRACKED_TASKS is 200: fill it, then push one more to force the FIFO
// eviction of the oldest entry (sess-0).
for (let i = 0; i < 200; i++) {
  await dispatch(`sess-${i}`, `call-${i}`)
}
await dispatch("sess-200", "call-200")

async function errorsFor(sessionId) {
  emitted.length = 0
  await hooks.event({ event: {
    type: "session.error",
    properties: { sessionID: sessionId, error: { name: "APIError", data: {} } },
  } })
  return emitted.length
}

assert.equal(await errorsFor("sess-0"), 0, "the oldest tracked session must have been evicted")
assert.equal(await errorsFor("sess-200"), 1, "the most recently tracked session must still be correlated")
NODE
)"; then
    pass "the tracked-task map evicts the oldest entry once MAX_TRACKED_TASKS is exceeded"
  else
    fail "LRU eviction did not bound the tracked-task map as expected: $output"
  fi
}

echo "================================"
echo " forge_task_observer_plugin_unit.sh"
echo "================================"

test_describe_error_basic_name_and_message
test_describe_error_captures_api_fields_regardless_of_name
test_describe_error_message_aborted_sets_stream_aborted
test_describe_error_defensive_fallback_for_non_object_error
test_track_task_dispatch_ignores_non_task_tool
test_track_task_dispatch_supports_sessionID_capitalized_variant
test_session_error_without_error_property_emits_nothing
test_session_error_uncorrelated_session_emits_nothing
test_correlation_is_consumed_once
test_lru_eviction_bounds_the_tracked_map

echo ""
echo "================================"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
