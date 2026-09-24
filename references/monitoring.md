# Herdr Workspace Lead monitoring and failure handling

Covers the span between dispatch and collection: how to learn a worker's real state, how to classify a failure, and when to stop. The installed `herdr` binary overrides examples here when syntax changes (verified on 0.9.0).

## Table of Contents

- [Probes](#probes)
- [When to probe](#when-to-probe)
- [Background watch](#background-watch)
- [Failure classes](#failure-classes)
- [Silent gateway truncation](#silent-gateway-truncation)
- [Resume instead of re-dispatch](#resume-instead-of-re-dispatch)
- [Diagnosing unknown](#diagnosing-unknown)
- [Error codes](#error-codes)
- [Notify the user](#notify-the-user)
- [Stop conditions](#stop-conditions)

## Probes

Use the cheapest probe that settles the question; move down only when the previous one cannot.

| Probe | Command | Tells you |
| --- | --- | --- |
| Fleet snapshot | `herdr agent list \| jq -r --arg ws "$ws" '.result.agents[] \| select(.workspace_id==$ws) \| "\(.name)\t\(.agent_status)\t\(.state_change_seq)"'` | State and state-change sequence of every worker in scope, in one call |
| Artifact progress | `ls -l <artifact-dir>` | Whether the artifact exists and is growing |
| Classification basis | `herdr agent explain <name> --format text` | Which rule produced the state and the screen evidence it matched |
| Runtime health | `herdr agent read <name> --source recent-unwrapped --lines 12` | Status bar: actual model, context usage, trailing error text |

- `agent_status` cannot tell "still running" from "hung": both show `working`. Compare `state_change_seq` between two probes; an unchanged value means no state transition happened in between.
- For several workers use the fleet snapshot, not one `agent get` per worker.
- Do not use `explain --verbose` or `explain --json`: they dump every candidate rule and screen fragment. `--format text` is a few lines and carries the full basis.
- Probe output is for deciding whether to intervene. Do not relay a worker's intermediate output to the user.

## When to probe

Probe only on a trigger. Unconditional fixed-interval polling by the leader is not allowed.

| Trigger | Meaning |
| --- | --- |
| `agent prompt --wait` or `agent wait` returned on timeout | Event-driven waiting has ended; look actively |
| State is `unknown` | Unclassified; proves nothing about completion |
| Worker disappeared from `agent list` | The process may have exited |
| More than 1.5x the estimated duration with no artifact | Estimate was wrong or the worker stalled |
| Context usage above 80% | Compaction is near; output quality will drop |

- Bounded: three consecutive probes of the same worker with no change in `state_change_seq`, artifact size, and context usage means stalled. Stop probing and report.
- Intervals start at 30 seconds and double each round. Never probe more often than every 30 seconds.
- When there is a concrete target state, prefer `herdr agent wait <target> --until <state> --timeout <ms>`; it is event-driven.
- After a wait times out or is aborted, judge completion from artifact signals (file exists, non-empty, modified after dispatch; target commit changed; verification command passes). Do not resend the prompt: the worker may still be working and the prompt would stack.
- A killed background watch or an aborted `agent wait` is not a user cancellation. The worker is still running; re-attach the watch. Stopping a worker needs explicit user words.

## Background watch

A worker that stops quietly (gateway truncation, process exit, approval prompt) produces no trigger, so tracking starts at dispatch, not when something looks wrong.

- Attach one background watch per worker at dispatch time and keep it alive until the artifact is collected; re-attach when it expires.
- Do not merge workers into one watch script: one worker's terminal state or error ends or blocks the loop and the rest lose tracking.
- The watch is event-driven: print one line only on a state change (`idle`, `done`, `blocked`, `unknown`, disappeared from `agent list`) or an artifact signal (file appears, becomes non-empty, mtime updates). Do not print every round.
- "Back to `idle`/`done` with no artifact" must be reported. A watch that only looks at the artifact file waits until timeout while the worker has long stopped.
- Act on every watch line: verify the artifact, resume, relay the blocker, or escalate.
- On Claude Code, implement the watch with the `Monitor` tool: one call per worker, a shell loop that reads `herdr agent get <pane-id>` and checks `test -s <artifact>` plus mtime, sleeping at least 30 seconds. Do not block the foreground on `agent wait`; while blocked the leader can neither answer the user nor see other workers.
- Address waits and watches by pane ID, not by name. Renaming a `working` agent does not interrupt it, but every in-flight `agent wait` / `agent prompt --wait` addressed by the old name fails with `agent_not_running`; a wait addressed by pane ID survives the rename (verified on 0.9.0, 2026-09-21).

## Failure classes

Classify first. The three classes differ completely in retry value.

| Class | Typical signals | Handling |
| --- | --- | --- |
| Transient | 5xx, broken stream, `unexpected EOF`, `Connection error`, rate limit, KV-cache allocation failure, no available backend, `agent_pane_busy`, startup timeout | Retry on the same profile twice with backoff (15s, 45s). Still failing: restart on another profile suited to the same role if one exists, otherwise report what was tried |
| Deterministic | 401/403 auth failure, 404 model not found, 400 parameter rejected, context limit exceeded | Never retry unchanged. Fix the profile or configuration, then restart |
| Task | Output misses the bar, drifts, or fails verification | Correct once. Still failing: report. Repeated failure usually means the brief is ambiguous; rewording beats retrying |

- Gateways and internal models jitter routinely. One transient failure is neither a reason to report nor a task failure.
- Do not switch to a weaker profile just to get around a failure; that trades output quality for availability. If the profile changed, say which model produced the result. No silent substitution.
- Five cumulative transient failures on one worker: stop, treat that source as unavailable, report.
- Transient retries do not count toward the [stop conditions](#stop-conditions).

## Silent gateway truncation

A truncated request does not make the worker `blocked` and raises no Herdr-level error. The worker quietly returns to `idle` with one `API Error` line on screen. By lifecycle state alone it is indistinguishable from normal completion.

Read the screen when any of these holds:

- State is `idle` or `done` but the artifact is missing.
- Context usage is far below what the task should need.
- The screen tail shows `API Error`, `unexpected EOF`, `Connection error`, or similar.

Never treat `idle` as completion on its own. After confirming truncation, resume; do not re-dispatch.

## Resume instead of re-dispatch

| Situation | Handling |
| --- | --- |
| Process alive, back to `idle` | Resume. Do not resend the original task; finished parts would be redone |
| Process alive, stuck in `unknown` | Diagnose per the next section, then resume |
| Process exited | Start a new helper and put the existing artifact path in the brief with "do not redo completed parts" |

Resume prompt:

```
The previous request was interrupted. Check how far you got, continue from that point, and do not redo completed parts. Keep writing the artifact to <artifact-path>.
```

## Diagnosing unknown

`unknown` means Herdr sees an agent but cannot classify it. It is neither completion nor process death.

1. `herdr agent explain <name> --format text`; read `state` and `rule`.
2. If the rule is a viewer overlay (such as `transcript_viewer` or `model_picker_menu`), the process is healthy and the overlay hides the detection area. `herdr agent send-keys <name> esc` closes it; run `explain` again to confirm.
3. If no rule matched (`fallback_reason` is set), judge by artifact file and context usage: either still changing means still working; both static means stalled.
4. Still undecided: report to the user with the worker's location.

Step 2 applies only when `explain` reports `state: unknown` with a viewer-overlay rule. Never send `esc` to a `blocked` agent: that is an approval dialog, and a key press answers it on the user's behalf.

## Error codes

| Response | Handling |
| --- | --- |
| `agent_pane_busy` | The pane shell is not ready yet. Wait 2 seconds and retry once; do not recreate the pane |
| `agent_not_ready` | The worker was `blocked` at start. The name still works for `agent read`; read what it is asking first |
| `agent_blocked` on prompt | The worker sits in an approval dialog and Herdr refused the send as protection. Do not resend: the prompt text would become the answer to a y/n question. Follow Unblock |
| `agent_prompt_stalled` | No state change within 5 seconds of the prompt, usually because the worker was not ready. Confirm `idle`, prompt once more, then report |
| `agent_not_running` on a wait | The agent was renamed while the wait was in flight, or the process exited. Check `agent list` by pane ID before concluding the process is gone |
| Reports `idle` but the process has exited | The prompt went into a bare shell. Confirm with `agent read --source visible`; if no agent UI remains, replace the pane instead of sending more keys |
| Worker disappeared from `agent list` | Confirm with `herdr pane list`, report to the user; do not restart silently |

## Notify the user

When a decision needs the user, raise a notification as well as writing it in the conversation; the user may not be looking at this pane.

```bash
herdr notification show "<what the user must do>" --body "<where: workspace / tab>" --sound request
```

Notify only in four cases: a worker is waiting on an approval that needs the user, a probe concluded the worker is stalled, every alternative profile is exhausted, or all work is complete. Notifications on every state change become noise and get ignored.

## Stop conditions

Stop and report as soon as any of these holds. An unattended orchestration without stop conditions keeps consuming quota.

- The same non-transient failure occurred twice.
- Two consecutive rounds made no real progress.
- Ten minutes with no artifact of substance, and probes show no change.
- Unattended, and any worker became `blocked`. When the user is present, a `blocked` worker goes through Unblock instead; an approval dialog is routine, not a failure.

On stop, handle in-flight workers before reporting: ask the user to cancel them, or interrupt only where cancellation is already authorized (see Authority boundaries in `SKILL.md`). Do not report and walk away; in-flight workers keep consuming quota.
