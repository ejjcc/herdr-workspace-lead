# Herdr Workspace Lead workflows

The installed `herdr` binary and official `herdr` skill override examples here when syntax changes.

## Table of Contents

- [Patrol](#patrol)
- [Dispatch and collect](#dispatch-and-collect)
- [Unblock](#unblock)
- [Cleanup](#cleanup)

## Patrol

Patrol is read-only unless the user also requests management actions. It covers one workspace: the caller's by default, or the one the user named.

1. Resolve the scope and discover topology and live agents inside it:

   ```bash
   ws="${HERDR_WORKSPACE_ID}"            # default: caller's workspace
   # user named a workspace by label/number: resolve it, never guess
   # ws=$(herdr workspace list | jq -r '.result.workspaces[] | select(.label=="ai-coding") | .workspace_id')
   herdr tab list --workspace "$ws"
   herdr pane list --workspace "$ws"
   herdr agent list | jq --arg ws "$ws" '.result.agents |= map(select(.workspace_id==$ws))'
   ```

   `agent list` has no `--workspace` flag; filter its JSON. Run unfiltered `workspace list` only to resolve a name the user gave or when the user asked for the whole session.

2. For each relevant agent, inspect semantic state first:

   ```bash
   herdr agent get <name-or-pane-id>
   ```

3. Read output only when needed to explain a blocker or recent result:

   ```bash
   herdr agent read <target> --source recent-unwrapped --lines 120
   ```

4. Report the scope, then what is `working`, `blocked`, `done`, `idle`, or `unknown`, listing each agent by name. For an unnamed agent, show its pane ID and the name you would assign. Do not send prompts, keys, interrupts, renames, or close commands during a status-only patrol. Do not list or read panes outside the callable scope.

## Dispatch and collect

### Choose location and isolation

Create new panes inside the scoped workspace. The leader's tab holds at most two panes: the leader and one helper. Any further helper gets its own tab (`herdr tab create --workspace "$ws" --label <name> --cwd <dir> --no-focus`), and a new tab is the default even for the first helper; split the leader's tab only for a single short-lived helper. Before splitting, count the leader's tab (`herdr pane list --workspace "$ws" | jq --arg t "$HERDR_TAB_ID" '[.result.panes[] | select(.tab_id==$t)] | length'`); if it already reports two, create a tab. When the user named another workspace, create the tab there (`herdr tab create --workspace <id>`); do not put its helper next to the caller.

- A read-only helper may share the current checkout.
- A single writer may use the current checkout only when no other agent writes there.
- Parallel writers require separate worktrees. Use `herdr worktree create --help`, choose an explicit base and unique branch, and capture returned IDs from JSON.

### Dispatch to an existing agent

Any agent in the caller's workspace is callable, including ones this orchestration did not create. An agent in another workspace needs a grant first (see Scope in `SKILL.md`). Name it once, then address it by name:

```bash
ws="${HERDR_WORKSPACE_ID}"
# callable agents and whether they already have a name
herdr agent list | jq -c --arg ws "$ws" \
  '.result.agents[] | select(.workspace_id==$ws) | {pane_id, name, agent, agent_status}'

# name the unnamed ones by purpose; this sends no input to the agent
herdr agent rename w5:p3 bt-codex
herdr agent get bt-codex          # confirm the name resolves

herdr agent prompt bt-codex "<bounded task>" --wait --timeout 300000
```

Names must match `[a-z][a-z0-9_-]{0,31}`; the CLI rejects anything else, so map a spoken name ("BT Codex") to `bt-codex`. A pane label is not an address. If the target is `working`, do not prompt over it unless the user asked to queue or steer that agent; if it is `blocked`, follow Unblock instead.

### Start a helper

Keep the caller focused and preserve its working directory. Give the helper its own tab, then start it through the launch profile resolved for its role (see "Launching helpers" in `SKILL.md`):

```bash
skill_dir=<absolute path of this skill's directory>
"$skill_dir"/scripts/list_profiles.sh    # configured profile per role, local candidates

tab=$(herdr tab create --workspace "$ws" --label collector --cwd "$PWD" --no-focus)
helper_pane=$(printf '%s\n' "$tab" | jq -r '.result.root_pane.pane_id')
# start_helper.sh <name> <profile> <pane-id> [timeout-seconds]
"$skill_dir"/scripts/start_helper.sh collector "$HERDR_WORKSPACE_LEAD_EXECUTOR_PROFILE" "$helper_pane"
"$skill_dir"/scripts/start_helper.sh doc-writer "$HERDR_WORKSPACE_LEAD_WRITER_PROFILE" "$helper_pane2"
```

One helper per tab. Agent output contains code blocks and diffs that wrap badly at half width, and a tab carries its own agent state indicator, so the user reads the fleet from the tab bar. Only for a single short-lived helper, and only while the leader's tab still has one pane, may it go into a sibling pane instead: `herdr pane split --current --direction right --cwd "$PWD" --no-focus`, pane ID from `.result.pane.pane_id`.

The script prints `{name, profile, pane_id, agent, agent_status}` and exits 3 when the profile is not found in the user's shell; pick another candidate from `list_profiles.sh` or ask the user instead of falling back to `herdr agent start --kind`, which cannot carry alias environment variables. `agent_status: blocked` means the helper opened on a prompt such as folder trust or an approval; follow Unblock before dispatching to it.

Resolve the profile as described in "Launching helpers" in `SKILL.md`: the user's choice, then the role variable, then discovery. Names must be unique and match `[a-z][a-z0-9_-]{0,31}`.

For a different layout requested by the user, `herdr tab create` and `herdr workspace create` return their root pane IDs. Parse those responses instead of predicting IDs.

### Submit bounded work

A worker is a separate process with none of the leader's context, and it may be another vendor's agent that never reads this skill. Whatever it must respect has to travel in the brief. Use this template, with fixed labels, instead of free-form paragraphs:

```markdown
**Goal** <one sentence naming the deliverable>
**Read first** `<brief path>` - <what to take from it>
**Scope**
- Read-only: `<paths>`
- Writable: only `<paths>`
**Constraints**
- <one per line>
- No git, no messages, no external writes
- No planning narration, no further delegation, no cleanup of unrelated code
- Write the artifact in sections; verify it is non-empty; retry a failed write yourself
**Verify** `<runnable verification command>`
**Return** Write the result to `<artifact path>`; reply only with that path and done/blocked, then stop.
```

- Omit **Read first** when there is no brief file; the other five labels are mandatory. Keep labels as bold inline text, not `##` headings, and put paths, commands, and literals in backticks.
- **Scope** always carries both lines. Stating only the writable paths lets the worker treat every unmentioned path as allowed.
- The mutation boundary in the brief always applies, and for a helper without approval prompts it is the only gate. Relax the git/messages/external-writes line only as far as the parent task authorized. Do not inject unrelated policies such as committing to `master` or pushing.
- Expand every `<path>` placeholder before sending. The worker sees only the literal text; a leftover placeholder sends the artifact somewhere the leader will not look.
- Keep a single prompt under about 1500 characters. Move longer background into a brief file in a private temporary directory and have the worker read it first. For parallel reviewers, give everyone the same brief file so that differences in output come from perspective, not input; a different angle per prompt is fine.
- Return by artifact file for anything longer than a few lines. Agents render on the alternate screen, and output that scrolled off is not recoverable by `agent read` at any `--lines` value. A short lookup may reply inline.
- When reusing a worker for a new round, say that it is a new task and how it relates to the previous one; otherwise the worker treats it as a continuation. A reused worker also carries its earlier position; start a fresh helper when an unbiased judgment is needed.

```bash
# prompt_file holds the filled-in template above
herdr agent prompt reviewer "$(cat "$prompt_file")" --wait --timeout 300000
```

Prompt only an `idle` (or `done`) worker. `agent prompt --wait` waits for a settled lifecycle state, not a uniquely tracked turn: if the target was already working, the end of its current turn satisfies the wait and the new work looks finished when it is not. With several workers, dispatch to all of them first and wait afterwards; dispatch-then-wait one by one turns parallel work into serial work. From dispatch until collection, follow [monitoring.md](monitoring.md).

### Collect the result

```bash
herdr agent get reviewer
herdr agent read reviewer --source recent-unwrapped --lines 200
```

Accept an artifact only after three checks: the file exists, it is non-empty, and its mtime is later than the dispatch time. A worker reporting done with an empty artifact is a frequent failure, and a same-named leftover from an earlier run passes the first two checks. When the same orchestration runs several rounds, prefix the file name with the round instead of overwriting, so rounds stay comparable.

If the worker replied inline and alternate-screen history omits part of the result, ask the idle helper to write its complete response to a Markdown file in a temporary directory and reply only with the path, then read that file directly.

Verify claims that affect completion: changed files, Git status, test exit status, generated artifacts, or pushed commits. Do not report a worker assertion as independently verified.

## Unblock

1. Inspect state and visible context:

   ```bash
   herdr agent get <target>
   herdr agent read <target> --source visible
   ```

2. If the agent is `blocked`, identify the exact approval, question, or decision. Ask the user unless the current request already provides that exact choice and authority.
3. After authorization, use logical keys for interactive UI:

   ```bash
   herdr agent send-keys <target> enter
   herdr agent send-keys <target> esc
   ```

4. If the agent is idle and needs ordinary follow-up work, use `agent prompt`, not raw pane input.
5. Use `herdr agent send-keys <target> ctrl+c` only when interruption is explicitly authorized. Do not synthesize control bytes through `pane send-text`.

After acting, wait for an observed state change and re-read the target. If it remains blocked or the decision changed, stop and escalate instead of repeatedly guessing.

## Cleanup

Cleanup must be explicitly requested or limited to resources created by the current orchestration, and it never leaves the resolved scope.

1. Wait for a settled state and inspect the final response:

   ```bash
   herdr agent wait <target> --timeout 300000
   herdr agent read <target> --source recent-unwrapped --lines 160
   ```

2. Verify relevant evidence outside the transcript: Git status and commits for repository work, test output for code changes, or artifact existence for generated files.
3. If completion remains ambiguous, ask the agent for a concise completion report listing completed work, verification, and remaining issues. Do not treat `idle`, `done`, or silence alone as proof.
4. Before a helper exits, send it back to clean up its own engineering side: servers and ports it started, temporary files its task produced. Only that worker knows what it started; once it exits, nobody does.
5. Close only an explicitly authorized tab or one created by this orchestration:

   ```bash
   herdr tab close <tab-id>
   ```

6. Report what was closed and what remains active. Do not stop the Herdr server as routine cleanup.
