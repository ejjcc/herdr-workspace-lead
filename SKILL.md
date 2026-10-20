---
name: herdr-workspace-lead
metadata:
  version: 1.1.0
description: Coordinate, inspect, dispatch, unblock, and safely clean up multiple coding agents inside Herdr. Every agent in the caller's workspace is callable by default and is addressed by name; agents in other workspaces are callable only when the user names the agent or authorizes that workspace. Use when the user explicitly asks to manage Herdr agents, tabs, workspaces, or worktrees, run a Herdr fleet patrol, or invokes herdr-workspace-lead. Do not use for ordinary single-agent work.
---

# Herdr Workspace Lead

Act as the leader for coding agents running in Herdr. Herdr is the transport and lifecycle layer; each worker remains an independent terminal agent.

Roles:

- **Leader**: the agent running this skill. It resolves scope, dispatches work, verifies results, and cleans up.
- **Worker**: any agent the leader dispatches work to, including agents someone else started.
- **Helper**: a worker this orchestration started. Only helpers follow [Launching helpers](#launching-helpers). Cleanup may close a helper's tab unprompted, never the tab of a worker someone else started.

## Mandatory preflight

1. Run `test "${HERDR_ENV:-}" = 1`. If it fails, stop and explain that the leader must run inside a Herdr-managed pane. Do not control a focused Herdr session from outside it.
2. Use the installed Herdr binary as the syntax authority. If the official `herdr` skill is available, follow it for control semantics. Otherwise read `herdr --skill` and the relevant command-group help.
3. Resolve the management scope (see [Scope](#scope)) before any inventory. Every list, read, dispatch, and cleanup command runs inside that scope.
4. Inspect live state and parse IDs from JSON responses. Never infer an ID from sidebar position or examples.
5. Determine the requested mode and authority before mutating anything. A status or inspection request is read-only.

## Scope

Scope decides which agents the leader may call. Calling an agent means prompting it and reading its output.

- **Every agent in the caller's workspace is callable by default**: `$HERDR_WORKSPACE_ID`. This includes agents this orchestration did not create. Do not ask for per-agent permission before dispatching to one.
- **Agents in other workspaces are not callable by default.** They are neither listed, read, prompted, nor closed. There are exactly two ways one becomes callable:
  1. **The user names that agent** for the task at hand, by agent name or pane ID. The grant covers that agent and that task only.
  2. **The user authorizes a workspace**, by ID (`w4`), number, or label (`ai-coding`), or asks for the whole session (`all workspaces`, `fleet-wide`, `全部 space`). The grant covers every agent in the named workspaces and lasts for the current conversation unless the user narrows it.
- **Never infer a cross-workspace grant.** A task that would merely benefit from another workspace's agent, an agent whose name resembles the one requested, or an authorization given in an earlier conversation does not count. Ask instead.
- Resolve a workspace label or number to an ID with `herdr workspace list`; never guess the mapping.
- **State the scope in every report**: workspace ID and label, and whether each workspace is the default or user-authorized.
- **Cross-scope evidence stays read-only**. If a task requires context from another workspace (for example a worker was moved there), read it and say so, but do not call or manage it without a grant.

`herdr pane list --workspace <id>` and `herdr tab list --workspace <id>` filter natively. `herdr agent list` has no workspace filter (verified on 0.9.0); filter its JSON by `.workspace_id` instead of reading the unfiltered fleet.

## Addressing agents by name

The user should be able to say "have `bt-codex` do X" without first looking up where that agent lives. Pane IDs change when panes move; names do not.

- Before the first dispatch in a conversation, list the callable agents and give every unnamed one a name: `herdr agent rename <pane-id> <name>`. Naming sends no input to the agent and does not interrupt it, but an in-flight `agent wait` or `agent prompt --wait` addressed by the old name fails with `agent_not_running`; rename before dispatch, or address waits by pane ID.
- Name by purpose, not position (`bt-codex`, `doc-writer`, `reviewer`). Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents. Map a spoken name such as "BT Codex" to its valid form (`bt-codex`) and tell the user the mapping once.
- Start new helpers with their name already set (`herdr agent start <name> ...`).
- A pane label is display-only and is not an address: `herdr agent prompt <pane-label>` does not resolve. Only the agent name or the pane ID does.
- After naming, address and report agents by name. A name lasts as long as the agent process; rename after a restart.
- Patrol stays read-only: report unnamed agents and the name you would assign, and rename only when the request includes dispatch or the user asks for it.

## Launching helpers

Every helper starts through a launch profile: a command name in the user's interactive shell, usually an alias that carries the model environment and permission flags, or a plain agent executable such as `claude` or `codex`. A profile may carry plain arguments after the command name, such as a launcher that takes a model name: `<launcher> <model>`. Pass the whole profile as one quoted argument.

- **Resolve the profile per role**, first match wins:
  1. A profile the user names for the task.
  2. The role's environment variable (see the table below).
  3. Discovery: `scripts/list_profiles.sh` lists the configured profiles and every alias or executable in the local shell that starts an agent kind Herdr can detect. With one candidate, use it and name it in the report. With several, ask the user once per conversation and suggest exporting the role variable so the question does not recur.
- **How**: run `scripts/start_helper.sh <name> <profile> <pane-id>`. It checks that the profile exists in the user's shell, starts it with `herdr pane run`, waits for agent detection, and names the agent. Do not use `herdr agent start --kind` for helpers: it cannot carry alias environment variables. Never print an alias definition; it can embed tokens.
- **One-step wrapper**: where the device provides a wrapper that creates the helper's tab in the caller's workspace, starts a model launcher through `start_helper.sh`, names the agent, and sends the brief without waiting, prefer it. The brief rules below still apply. Keep each model in the harness its launcher selects (for example GPT models in Codex, other models in Claude Code). When a model fails there (for example, it reports no tools), find the cause or pick a sibling model that works in that harness; do not move it to the other harness.
- **Permission mode comes with the profile.** A profile that skips approval prompts keeps a helper from stalling on Bash approvals; an allowlist does not help, because workers compose compound commands (`mkdir … && cmd > file`, `… | python3 -c`) that never match a prefix rule. A profile with approvals is stricter: its helper turns `blocked` at each prompt and goes through Unblock. Use the resolved profile as is; do not ask about permission mode per dispatch and do not add or strip permission flags.
- **Where**: each helper gets its own tab in the scoped workspace (`herdr tab create --no-focus`, then start in its root pane). The leader's tab never holds more than two panes: the leader and at most one short-lived helper. Count before splitting; when in doubt, create a tab.
- **The brief is the gate that always applies**: write the mutation boundary (writable paths, no git, no messages, no external writes) into every brief, and verify it afterwards from outside the transcript (`git status`, file listing). For a helper without approval prompts, the brief is the only gate.
- This covers helpers the orchestration starts. Do not change the permission mode of an agent someone else started.

### Choose the profile by role

Pick the role from what the worker has to produce, not from habit:

| Role | Variable | Fits | Leader follow-up |
| --- | --- | --- | --- |
| Executor | `HERDR_WORKSPACE_LEAD_EXECUTOR_PROFILE` | Running commands, searching and collecting material, repo exploration, code edits, tests, mechanical multi-step work | Verify claimed artifacts and exit status |
| Writer | `HERDR_WORKSPACE_LEAD_WRITER_PROFILE` | Writing documents, summaries, weekly reports, turning collected evidence into prose | Read the full text against the source material; writers tend to add facts that are not in the evidence and to overrun length |

Key judgments, and the final check of anything delivered to management or outside the team, stay with the leader. Do not send evidence gathering to a writer profile or long-form writing to an executor profile just because that agent is already idle.

## Authority boundaries

Being callable covers prompting an agent and reading its output, nothing more. The limits below apply to every agent, in the default scope or under a grant.

- Use unique live agent names, or explicit pane IDs where no name exists yet. Prefer `--current` for the caller and `--no-focus` for background work.
- Use `herdr agent ...` for recognized agents. Use `herdr pane ...` only for raw terminals, shells, tests, and servers.
- Never answer an approval, permission prompt, or material design choice merely because an agent is `blocked`. Read the UI and ask the user unless the current request already contains the exact decision and authority.
- Never interrupt a `working` agent unless the user explicitly requests cancellation or the task has a concrete, evidenced failure condition.
- Never close a workspace, tab, pane, or session that this orchestration did not create unless the user explicitly names it for closure. Never run `herdr server stop` as cleanup.
- Never act on a pane outside the callable scope, even if it appears in an unfiltered listing or its name matches what the user said. When two workspaces hold agents with the same name, the one in the caller's workspace wins; the other needs a grant.
- Respect repository instructions and the parent task's authorization. Do not hardcode a branch, commit target, or push policy into worker prompts. A profile without approval prompts removes the prompt, not the task's authorization: a helper may still only do what the parent task allows, and the brief says so.

## State model

Use Herdr's semantic state instead of guessing from terminal silence:

- `working`: active; leave it alone unless cancellation is authorized.
- `blocked`: approval or question UI; inspect and escalate the decision.
- `done`: background work settled but has not been viewed.
- `idle`: ready for input and already seen.
- `unknown`: unclassified; it does not prove completion.

CLI reads do not mark work as seen. A quiet terminal is not completion evidence.

## Concurrency safety

- Allow at most one writer per Git checkout.
- Read-only reviewers may share a checkout if their prompt forbids edits.
- Give parallel writers separate Git worktrees and branches. Never tell multiple agents to commit into the same working tree.
- Require workers to preserve unrelated changes and stage only files they own. Never instruct them to use destructive reset/checkout commands or blind `git add .` in a shared checkout.
- Treat each worker's output as evidence, not authority. The leader verifies important claims before reporting completion.
- For a change whose failure is costly (architecture, security boundary, data migration), or when the user asks for cross-checking, have it reviewed by a worker running a different underlying model than the implementer. Judge by the model each worker actually reaches, not by agent kind or endpoint. If only a same-model review is possible, do it and say in the report that verification strength is limited; do not skip the review and do not substitute silently.
- Do not settle several reviewers' conclusions by majority vote. List the disagreements with each side's position and where to ask for the reasoning; two agreeing reviewers that share a model share its blind spots. Rerunning finished work on another agent is a redo, not a review.

## Workflow routing

Read only the relevant section of [references/workflows.md](references/workflows.md):

- **Patrol**: inventory agents in scope and report status without changing them.
- **Dispatch and collect**: name and prompt an existing callable agent, or create a pane or worktree in scope and start a named helper; submit bounded work and collect the result.
- **Unblock**: inspect a blocked or idle agent in scope and proceed only within existing authority.
- **Cleanup**: verify completion and close only resources that are in scope and owned by this orchestration. Close a helper when the user goal it serves is complete, not when one round settles; keep it open while it waits on an external thread or a likely follow-up, and reuse it for follow-ups.

After every dispatch, read [references/monitoring.md](references/monitoring.md): probes and background watch, failure classes and retry limits, silent gateway truncation, `unknown` diagnosis, error codes, user notification, and stop conditions.

## Reporting

Report in the user's language. Open with the scope (workspace ID, label, default or specified). For multiple agents, use a compact table with target, location, semantic state, current result, blocker, and next action. Separate verified facts from worker claims and mention any action still awaiting user approval.
