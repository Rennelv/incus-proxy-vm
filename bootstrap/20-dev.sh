#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env
source /opt/proxyvm/config/packages.sh

dnf install -y --disablerepo=fedora-cisco-openh264 \
  "${PACKAGES_DEVELOPMENT[@]}"

runuser -u "$GUEST_USER" -- env HOME="$GUEST_HOME" \
  PATH="$GUEST_HOME/.local/bin:$GUEST_HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin" \
  TOOL_PNPM="$TOOL_PNPM" TOOL_BUN="$TOOL_BUN" TOOL_UV="$TOOL_UV" \
  TOOL_BUN_INSTALLER="$TOOL_BUN_INSTALLER" TOOL_UV_INSTALLER="$TOOL_UV_INSTALLER" \
  TOOL_PNPM_NPM_PACKAGE="$TOOL_PNPM_NPM_PACKAGE" \
  bash -euc '
    mkdir -p "$HOME/.local/bin"
    npm config set prefix "$HOME/.local"
    if [[ "$TOOL_PNPM" == 1 ]]; then npm install -g "$TOOL_PNPM_NPM_PACKAGE"; fi
    mkdir -p "$HOME/.cache/proxyvm-installers"
    if [[ "$TOOL_BUN" == 1 ]]; then
      curl -fsSL "$TOOL_BUN_INSTALLER" -o "$HOME/.cache/proxyvm-installers/bun-install.sh"
      bash "$HOME/.cache/proxyvm-installers/bun-install.sh"
    fi
    if [[ "$TOOL_UV" == 1 ]]; then
      curl -fsSL "$TOOL_UV_INSTALLER" -o "$HOME/.cache/proxyvm-installers/uv-install.sh"
      bash "$HOME/.cache/proxyvm-installers/uv-install.sh"
    fi
    rm -f "$HOME/.cache/proxyvm-installers/bun-install.sh" "$HOME/.cache/proxyvm-installers/uv-install.sh"
    line="export PATH=\"\$HOME/.local/bin:\$HOME/.bun/bin:\$HOME/.opencode/bin:\$PATH\""
    grep -Fqx "$line" "$HOME/.bashrc" || printf "%s\n" "$line" >>"$HOME/.bashrc"
  '
