#!/usr/bin/env bash
set -Eeuo pipefail

mode="$(getenforce 2>/dev/null || true)"
if [[ "$mode" != Disabled && "$mode" != Enforcing && "$mode" != Permissive ]]; then
  echo "[SELinux] Unknown mode '$mode'; refusing to modify policy" >&2
  exit 1
fi
if ! rpm -q selinux-policy-targeted >/dev/null 2>&1; then
  echo '[SELinux] targeted policy package not installed' >&2
  exit 1
fi

if ! custom="$(semanage fcontext -l -C 2>/dev/null)"; then
  if [[ "$mode" == Disabled ]]; then
    echo '[SELinux] Policy installed, but store is not yet manageable. Deferring labels to first Permissive boot.'
    exit 0
  fi
  echo '[SELinux] Active, but policy store cannot be accessed' >&2
  exit 1
fi

set_label() {
  local path="$1" type="$2"
  [[ -e "$path" ]] || return 0
  local row
  row="$(printf '%s\n' "$custom" | awk -v path="$path" '$1 == path { print; exit }')"
  if [[ -z "$row" ]]; then
    semanage fcontext -a -t "$type" "$path"
  elif [[ "$row" != *"object_r:${type}:"* ]]; then
    semanage fcontext -m -t "$type" "$path"
  fi
  if [[ "$mode" != Disabled ]]; then
    restorecon -v "$path"
  fi
}

set_label /run/incus_agent/incus-agent bin_t
set_label /usr/lib/chromium-browser bin_t
set_label /usr/lib/chromium-browser/chromium-browser.sh bin_t
set_label /usr/lib/chrome-sandbox chrome_sandbox_exec_t
