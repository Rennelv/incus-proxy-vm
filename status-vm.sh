#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -z ${1:-} ]]; then echo 'Usage: ./status-vm.sh VM_NAME' >&2; exit 2; fi
VM="$1"
if (( EUID == 0 )); then INCUS=(incus); else INCUS=(/usr/bin/sudo incus); fi
"${INCUS[@]}" list "$VM"
if ! "${INCUS[@]}" exec "$VM" -- bash -c '
  echo "=== Provisioning state ==="
  test -f /var/lib/proxyvm/finalize.state && cat /var/lib/proxyvm/finalize.state || echo UNAVAILABLE
  test -f /var/lib/proxyvm/ready && echo READY_MARKER_PRESENT || true
  test -f /var/lib/proxyvm/finalize.failed && echo FAILED_MANUAL_ACTION_REQUIRED || true
  echo "=== SELinux ==="
  getenforce
  echo "=== Cloud-init (first boot only) ==="
  cloud-init status || true
'; then
  echo 'Agent unavailable during reboot/relabel or guest failed to start.' >&2
  echo "Check: /usr/bin/sudo incus console $VM --show-log" >&2
  exit 1
fi
