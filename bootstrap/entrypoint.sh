#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
mkdir -p /var/log /var/lib/proxyvm
exec > >(tee -a /var/log/proxyvm-bootstrap.log) 2>&1
trap 'rc=$?; echo "[ERROR] $(date -Is) command at line $LINENO failed (exit $rc)" >&2; exit "$rc"' ERR

echo "=== proxyvm bootstrap: $(date -Is) ==="
for script in /opt/proxyvm/bootstrap/[0-9][0-9]-*.sh; do
  marker="/var/lib/proxyvm/$(basename "$script").done"
  if [[ -e "$marker" ]]; then
    echo "[SKIP] $(basename "$script")"
    continue
  fi
  echo "[RUN] $(basename "$script")"
  bash "$script"
  touch "$marker"
  echo "[DONE] $(basename "$script")"
done

if [[ ! -e /var/lib/proxyvm/bootstrap.done ]]; then
  install -D -m 0644 /opt/proxyvm/files/etc/systemd/system/proxyvm-finalize.service \
    /etc/systemd/system/proxyvm-finalize.service
  systemctl daemon-reload
  systemctl enable proxyvm-finalize.service
  cat /proc/sys/kernel/random/boot_id > /var/lib/proxyvm/bootstrap.boot-id
  touch /var/lib/proxyvm/bootstrap.done
  printf 'BOOTSTRAP_DONE_AWAITING_RELABEL_REBOOT\n' > /var/lib/proxyvm/finalize.state
  echo "=== Bootstrap complete: $(date -Is); reboot queued for SELinux relabel ==="
  if ! /usr/sbin/shutdown -r +1 'proxyvm bootstrap done; rebooting to relabel SELinux'; then
    rm -f /var/lib/proxyvm/bootstrap.done /var/lib/proxyvm/bootstrap.boot-id
    echo '[ERROR] Cannot schedule first reboot; bootstrap remains restartable.' >&2
    exit 1
  fi
else
  echo '=== Bootstrap was already complete; no additional reboot scheduled ==='
fi
