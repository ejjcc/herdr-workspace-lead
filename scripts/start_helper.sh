#!/usr/bin/env bash
# Start a named helper agent in an existing Herdr pane through a launch profile.
#
# A launch profile is a command name in the user's interactive shell: usually an
# alias that carries the model environment and permission flags, or a plain
# agent executable. `herdr agent start --kind` cannot carry alias environment
# variables, so helpers start through the profile instead.
#
# Usage: start_helper.sh <name> <profile> <pane-id> [timeout-seconds]
# Output: one JSON object {name, profile, pane_id, agent, agent_status}
# Exit:   2 usage / invalid name, 3 profile not found, 4 agent not detected
set -euo pipefail

name="${1:-}"; profile="${2:-}"; pane="${3:-}"; timeout="${4:-90}"

if [[ -z "$name" || -z "$profile" || -z "$pane" ]]; then
  echo "usage: start_helper.sh <name> <profile> <pane-id> [timeout-seconds]" >&2
  [[ -z "$profile" ]] && echo "no profile given: the role variable is unset; pick one from list_profiles.sh" >&2
  exit 2
fi
if ! [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
  echo "invalid agent name: $name (must match [a-z][a-z0-9_-]{0,31})" >&2
  exit 2
fi
if ! [[ "$profile" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
  echo "invalid profile name: $profile" >&2
  exit 2
fi

# Resolve in the user's interactive shell so aliases and functions count.
# `type` prints alias definitions, which can embed tokens: discard its output.
shell="${SHELL:-/bin/sh}"
if ! "$shell" -ic "type $profile" >/dev/null 2>&1; then
  echo "launch profile '$profile' is not an alias, function, or command in $shell on this device" >&2
  exit 3
fi

herdr pane run "$pane" "$profile" >/dev/null

deadline=$((SECONDS + timeout))
agent=""; status=""
while (( SECONDS < deadline )); do
  info="$(herdr pane list | jq -c --arg p "$pane" '.result.panes[] | select(.pane_id==$p)' 2>/dev/null || true)"
  agent="$(jq -r '.agent // empty' <<<"$info")"
  status="$(jq -r '.agent_status // empty' <<<"$info")"
  # blocked: the helper opened on a prompt (folder trust, approval) for the leader to handle
  if [[ -n "$agent" && ( "$status" == "idle" || "$status" == "done" || "$status" == "blocked" ) ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$agent" ]]; then
  echo "no agent detected in $pane after ${timeout}s; read the pane before retrying" >&2
  exit 4
fi

herdr agent rename "$pane" "$name" >/dev/null
jq -cn --arg name "$name" --arg profile "$profile" --arg pane "$pane" \
  --arg agent "$agent" --arg status "$status" \
  '{name:$name, profile:$profile, pane_id:$pane, agent:$agent, agent_status:$status}'
