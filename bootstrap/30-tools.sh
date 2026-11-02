#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env

runuser -u "$GUEST_USER" -- env HOME="$GUEST_HOME" \
  PATH="$GUEST_HOME/.local/bin:$GUEST_HOME/.bun/bin:$GUEST_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin" \
  TOOL_CLAUDE="$TOOL_CLAUDE" TOOL_CODEX="$TOOL_CODEX" TOOL_OPENCODE="$TOOL_OPENCODE" TOOL_ANTIGRAVITY="$TOOL_ANTIGRAVITY" \
  TOOL_CLAUDE_INSTALLER="$TOOL_CLAUDE_INSTALLER" TOOL_CODEX_NPM_PACKAGE="$TOOL_CODEX_NPM_PACKAGE" \
  TOOL_OPENCODE_INSTALLER="$TOOL_OPENCODE_INSTALLER" TOOL_ANTIGRAVITY_INSTALLER="$TOOL_ANTIGRAVITY_INSTALLER" \
  bash -euc '
    mkdir -p "$HOME/.cache/proxyvm-installers"
    cd "$HOME/.cache/proxyvm-installers"
    if [[ "$TOOL_CLAUDE" == 1 ]] && ! command -v claude >/dev/null; then
      curl -fsSL "$TOOL_CLAUDE_INSTALLER" -o claude-install.sh
      bash claude-install.sh
    fi
    if [[ "$TOOL_CODEX" == 1 ]] && ! command -v codex >/dev/null; then
      npm install --global --no-audit --no-fund "$TOOL_CODEX_NPM_PACKAGE"
    fi
    if [[ "$TOOL_OPENCODE" == 1 ]] && ! command -v opencode >/dev/null; then
      curl -fsSL "$TOOL_OPENCODE_INSTALLER" -o opencode-install.sh
      bash opencode-install.sh
    fi
    if [[ "$TOOL_ANTIGRAVITY" == 1 ]] && ! command -v agy >/dev/null; then
      curl -fsSL "$TOOL_ANTIGRAVITY_INSTALLER" -o agy-install.sh
      bash agy-install.sh
    fi
    rm -f -- *-install.sh
  '
