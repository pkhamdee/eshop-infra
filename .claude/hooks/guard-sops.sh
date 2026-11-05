#!/usr/bin/env bash
# PreToolUse hook: SOPS files (*.sops.yaml) are human-only (docs/agents/conventions.md, "Human-only steps"): agents
# never create, encrypt, edit or decrypt them, not even with a placeholder. Blocks Write/Edit/MultiEdit of such a
# path, and any Bash command naming one that runs sops or writes, moves or deletes files. Reading the ciphertext
# (cat, grep, git diff) stays allowed. Exit 2 blocks the call and shows stderr to the agent.
# Tested by .claude/hooks/test-guard-sops.sh.
set -euo pipefail

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")

block() {
  echo "Blocked: $1 SOPS files (*.sops.yaml) are human-only (docs/agents/conventions.md, \"Human-only steps\")." \
    "Give the user the exact commands to run instead." >&2
  exit 2
}

case "$tool" in
  Write | Edit | MultiEdit | NotebookEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    [[ "$path" == *.sops.yaml ]] && block "$tool of $path."
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    # A command (at the start of a line or after ; & | or $(, optionally behind VAR=value assignments) that is sops
    # itself (encrypt, edit, decrypt), tee, an in-place sed/perl, or a file copy/move/delete, with a SOPS path before
    # the next ; & |; or a redirect straight into a SOPS path. Text that only mentions SOPS files (a commit message,
    # a PR body) is not a command and passes.
    at='(^|[;&|]|\$\()[[:space:]]*([[:alpha:]_][[:alnum:]_]*=[^[:space:]]*[[:space:]]+)*'
    tool_re='(sops|tee|cp|mv|rm|install|truncate|dd|(sed|perl)[[:space:]]+(-[[:alnum:]]*[[:space:]]+)*-[[:alnum:]]*i)'
    if grep -qE "${at}${tool_re}([[:space:]][^;&|]*)?\.sops\.yaml|>>?[[:space:]]*[^[:space:];&|]*\.sops\.yaml" <<<"$cmd"; then
      block "this command runs sops on, or writes to, a SOPS file."
    fi
    ;;
esac
exit 0
