// Observes OpenCode's generic `event` hook to capture provider/runtime infra
// errors (`session.error`) that break a `task` subagent dispatch, and
// re-emits them as a single-line, greppable marker so the orchestrator can
// surface them even though `task` failures are otherwise swallowed.
//
// Style/structure mirrors forge-guard.js: a single default-exported plugin
// factory returning a Hooks object, small pure helpers, no external deps.

const TASK_TOOL_NAME = "task"
const MAX_TRACKED_TASKS = 200

// Bounds the child-session -> task-call correlation map so a long-running
// session can't grow this unbounded when many task dispatches occur.
function rememberTask(tracked, sessionId, info) {
  if (tracked.size >= MAX_TRACKED_TASKS) {
    const oldestKey = tracked.keys().next().value
    if (oldestKey !== undefined) {
      tracked.delete(oldestKey)
    }
  }
  tracked.set(sessionId, info)
}

function trackTaskDispatch(tracked, event) {
  const part = event?.properties?.part
  if (!part || part.type !== "tool" || part.tool !== TASK_TOOL_NAME) {
    return
  }

  const childSessionId = part.metadata?.sessionId || part.metadata?.sessionID
  if (!childSessionId || typeof childSessionId !== "string") {
    return
  }

  rememberTask(tracked, childSessionId, {
    callID: part.callID,
    messageID: part.messageID,
  })
}

function describeError(error) {
  if (!error || typeof error !== "object") {
    return { name: "UnknownError", message: "" }
  }

  const name = error.name || "UnknownError"
  const data = error.data || {}
  const detail = { name, message: data.message || "" }

  // API-error-shaped data is captured whenever present, regardless of the
  // exact `name` string: OpenCode's discriminated union naming for this
  // member was not verified live (see spike findings), so matching on the
  // presence of these fields is more robust than an exact name match.
  if (data.statusCode !== undefined) {
    detail.statusCode = data.statusCode
  }
  if (data.isRetryable !== undefined) {
    detail.isRetryable = data.isRetryable
  }

  if (name === "MessageAbortedError") {
    detail.streamAborted = true
  }

  return detail
}

function handleSessionError(tracked, event) {
  const sessionID = event?.properties?.sessionID
  const error = event?.properties?.error
  if (!error) {
    return
  }

  const taskInfo = sessionID ? tracked.get(sessionID) : undefined
  if (!taskInfo) {
    // Not a tracked `task` dispatch (e.g. an error on the orchestrator's own
    // root session): out of scope for this marker, which the orchestrator
    // greps specifically to surface `task` infra failures.
    return
  }
  tracked.delete(sessionID)

  const detail = describeError(error)
  detail.taskCallID = taskInfo.callID

  const payload = { sessionID, ...detail }
  console.error(`FORGE_TASK_INFRA_ERROR: ${JSON.stringify(payload)}`)
}

export default async function forgeTaskObserver() {
  const trackedTaskSessions = new Map()

  return {
    event: async ({ event }) => {
      if (!event || typeof event.type !== "string") {
        return
      }

      if (event.type === "message.part.updated") {
        trackTaskDispatch(trackedTaskSessions, event)
        return
      }

      if (event.type === "session.error") {
        handleSessionError(trackedTaskSessions, event)
      }
    },
  }
}
