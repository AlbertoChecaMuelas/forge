import { spawnSync } from "node:child_process"

const PROTECTED_BRANCHES = new Set(["master", "main", "dev"])
const warnedMergedRepos = new Set()

function runGit(args) {
  return spawnSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })
}

function currentBranch() {
  const result = runGit(["symbolic-ref", "--short", "HEAD"])
  if (result.status !== 0) {
    return ""
  }
  return (result.stdout || "").trim()
}

function defaultBranch() {
  let result = runGit(["symbolic-ref", "refs/remotes/origin/HEAD"])
  if (result.status === 0) {
    return (result.stdout || "").trim().replace("refs/remotes/origin/", "")
  }

  result = runGit(["config", "init.defaultBranch"])
  if (result.status === 0) {
    return (result.stdout || "").trim() || "master"
  }

  return "master"
}

function repoRoot() {
  const result = runGit(["rev-parse", "--show-toplevel"])
  if (result.status !== 0) {
    return ""
  }
  return (result.stdout || "").trim()
}

function isMerged(defaultBranchName) {
  if (!defaultBranchName) {
    return false
  }

  const verify = runGit(["rev-parse", "--verify", `origin/${defaultBranchName}`])
  if (verify.status !== 0) {
    return false
  }

  const merged = runGit(["merge-base", "--is-ancestor", "HEAD", `origin/${defaultBranchName}`])
  return merged.status === 0
}

function extractToolName(input, output) {
  return (
    input?.tool ||
    input?.toolName ||
    input?.name ||
    output?.tool ||
    output?.toolName ||
    ""
  )
}

function extractCommand(input, output) {
  return (
    output?.args?.command ||
    output?.command ||
    input?.args?.command ||
    input?.command ||
    input?.input?.command ||
    ""
  )
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

export default async function forgeGuard() {
  return {
    "tool.execute.before": async (input, output) => {
      if (process.env.FORGE_BRANCH_GUARD_DISABLE) {
        return
      }

      const toolName = String(extractToolName(input, output)).toLowerCase()
      const command = extractCommand(input, output)

      if (toolName !== "bash" || !command) {
        return
      }

      if (isGitCommit(command)) {
        const branch = currentBranch()
        if (PROTECTED_BRANCHES.has(branch)) {
          throw new Error(
            `[branch-guard] BLOCKED: commit attempt on protected branch '${branch}'. Create a feature branch first (branch guard).`
          )
        }
      }

      const branch = currentBranch()
      const branchDefault = defaultBranch()
      if (!branch || branch === branchDefault) {
        return
      }

      const root = repoRoot()
      const warningKey = `${root}:${branch}:${branchDefault}`

      if (isMerged(branchDefault) && !warnedMergedRepos.has(warningKey)) {
        warnedMergedRepos.add(warningKey)
        console.error(
          `[branch-guard] La rama '${branch}' ya esta mergeada en origin/${branchDefault}. Considera cambiar de rama antes de seguir trabajando.`
        )
      }
    },
  }
}
