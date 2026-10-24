// Forge branch guard — OpenCode 2 plugin API.
//
// Ported from the OpenCode 1 plugin factory (`export default async function
// forgeGuard()` returning a `tool.execute.before` hook) to the OpenCode 2
// native plugin contract:
//
//   * the module exports a DEFAULT definition with a stable `id` and a
//     `setup(context)` function (OpenCode 2 rejects anything else with
//     "Plugin must export a default definition with an id and an effect or
//     setup function."),
//   * the veto is registered through `ctx.tool.hook("execute.before", ...)`,
//   * only the OpenCode 2 `shell` tool is inspected (OpenCode 1 called it
//     `bash`), and its command lives in `input.command`,
//   * every Git call runs with an explicit `cwd` taken from
//     `ctx.location.directory` instead of relying on the process cwd.
//
// `@opencode/plugin` and `effect` are provided by the OpenCode host runtime:
// plugins must NOT ship their own copies of them in `node_modules`.

import { spawnSync } from "node:child_process"
import { Plugin } from "@opencode/plugin"

const PROTECTED_BRANCHES = new Set(["master", "main", "dev"])
const warnedMergedRepos = new Set()

function runGit(args, cwd) {
  return spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })
}

function currentBranch(cwd) {
  const result = runGit(["symbolic-ref", "--short", "HEAD"], cwd)
  if (result.status !== 0) {
    return ""
  }
  return (result.stdout || "").trim()
}

function defaultBranch(cwd) {
  let result = runGit(["symbolic-ref", "refs/remotes/origin/HEAD"], cwd)
  if (result.status === 0) {
    return (result.stdout || "").trim().replace("refs/remotes/origin/", "")
  }

  result = runGit(["config", "init.defaultBranch"], cwd)
  if (result.status === 0) {
    return (result.stdout || "").trim() || "master"
  }

  return "master"
}

function repoRoot(cwd) {
  const result = runGit(["rev-parse", "--show-toplevel"], cwd)
  if (result.status !== 0) {
    return ""
  }
  return (result.stdout || "").trim()
}

function isMerged(cwd, defaultBranchName) {
  if (!defaultBranchName) {
    return false
  }

  const verify = runGit(["rev-parse", "--verify", `origin/${defaultBranchName}`], cwd)
  if (verify.status !== 0) {
    return false
  }

  const merged = runGit(["merge-base", "--is-ancestor", "HEAD", `origin/${defaultBranchName}`], cwd)
  return merged.status === 0
}

function extractCommand(input) {
  if (!input || typeof input !== "object") {
    return ""
  }
  const value = input.command
  return typeof value === "string" ? value : ""
}

function isGitCommit(command) {
  // Split on shell statement boundaries (|, ||, &&, ;) to isolate individual
  // commands. This prevents false positives such as "git log | grep commit".
  const statements = command.split(/\s*(?:\|\|?|&&|;)\s*/)
  for (const stmt of statements) {
    const tokens = stmt.trim().split(/\s+/).filter(t => t.length > 0)
    if (tokens.length === 0) continue

    // The git executable must be the first token in the statement.
    // This rules out "echo git commit", "sudo git commit", etc.
    if (tokens[0] !== "git") continue

    let idx = 1
    // Skip git global flags. Flags that take a separate value token (-C, -c)
    // consume an extra token so that the value is not mistaken for a subcommand.
    while (idx < tokens.length && tokens[idx].startsWith("-")) {
      const flag = tokens[idx]
      idx++
      // -C <path> and -c <key>=<value> each consume one additional token
      if ((flag === "-C" || flag === "-c") && idx < tokens.length) {
        idx++
      }
    }

    // The next token must be the subcommand; it is a commit only when it equals
    // "commit" exactly — positional arguments such as "git show abc123 commit"
    // do not reach here as "show" would be consumed first.
    if (idx < tokens.length && tokens[idx] === "commit") {
      return true
    }
  }
  return false
}

export default Plugin.define({
  id: "forge-guard",
  async setup(ctx) {
    // The session directory is the only Git context the guard uses: the
    // process cwd of the OpenCode server is not the session cwd.
    const cwd = ctx.location.directory

    await ctx.tool.hook("execute.before", async (input) => {
      if (process.env.FORGE_BRANCH_GUARD_DISABLE) {
        return
      }

      // OpenCode 2 renamed the shell tool: `bash` (v1) -> `shell` (v2).
      if (input.tool !== "shell") {
        return
      }

      const command = extractCommand(input.input)
      if (!command) {
        return
      }

      if (isGitCommit(command)) {
        const branch = currentBranch(cwd)
        if (PROTECTED_BRANCHES.has(branch)) {
          throw new Error(
            `[branch-guard] BLOCKED: commit attempt on protected branch '${branch}'. Create a feature branch first (branch guard).`
          )
        }
      }

      const branch = currentBranch(cwd)
      const branchDefault = defaultBranch(cwd)
      if (!branch || branch === branchDefault) {
        return
      }

      const root = repoRoot(cwd)
      const warningKey = `${root}:${branch}:${branchDefault}`

      if (isMerged(cwd, branchDefault) && !warnedMergedRepos.has(warningKey)) {
        warnedMergedRepos.add(warningKey)
        console.error(
          `[branch-guard] La rama '${branch}' ya esta mergeada en origin/${branchDefault}. Considera cambiar de rama antes de seguir trabajando.`
        )
      }
    })
  },
})
