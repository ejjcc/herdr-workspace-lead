#!/usr/bin/env bash
# List launch profiles for helpers: the profile configured per role, plus every
# alias or executable in the user's interactive shell that starts an agent kind
# Herdr can detect. Alias definitions can embed tokens: they are read only to
# find the agent executable and are never printed.
#
# Usage:  list_profiles.sh
# Output: one JSON object {configured: {executor, writer}, candidates: [{profile, kind, agent}]}
# Exit:   1 when the supported agent kinds cannot be read from herdr
set -euo pipefail
set -f  # alias words must not glob-expand

kinds="$(herdr agent start --help 2>/dev/null | sed -n 's/.*\[possible values: \(.*\)\].*/\1/p' | tr -d ' ' | tr ',' '\n')"
if [[ -z "$kinds" ]]; then
  echo "cannot read supported agent kinds from 'herdr agent start --help'" >&2
  exit 1
fi

candidates="$(
  # aliases: the first word whose basename is a supported kind is the agent
  "${SHELL:-/bin/sh}" -ic alias 2>/dev/null | sed -E 's/^alias //' | while IFS= read -r line; do
    [[ "$line" =~ ^([A-Za-z0-9_][A-Za-z0-9_-]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    for word in ${value//[\'\";|&()]/ }; do
      if grep -qxF -- "${word##*/}" <<<"$kinds"; then
        printf '%s\talias\t%s\n' "$name" "${word##*/}"
        break
      fi
    done
  done
  # plain executables on PATH
  while IFS= read -r kind; do
    if command -v "$kind" >/dev/null 2>&1; then
      printf '%s\tcommand\t%s\n' "$kind" "$kind"
    fi
  done <<<"$kinds"
)"

jq -n \
  --arg executor "${HERDR_WORKSPACE_LEAD_EXECUTOR_PROFILE:-}" \
  --arg writer "${HERDR_WORKSPACE_LEAD_WRITER_PROFILE:-}" \
  --arg c "$candidates" '
  {
    configured: {
      executor: (($executor | select(. != "")) // null),
      writer: (($writer | select(. != "")) // null)
    },
    candidates: ([$c | split("\n")[] | select(. != "") | split("\t")
                  | {profile: .[0], kind: .[1], agent: .[2]}] | unique_by(.profile))
  }'
