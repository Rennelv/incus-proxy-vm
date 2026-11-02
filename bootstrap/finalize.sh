#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env
umask 022
readonly DIR=/var/lib/proxyvm
readonly STATUS="$DIR/finalize.state"
readonly FAILED="$DIR/finalize.failed"
readonly READY="$DIR/ready"
readonly REBOOT_ID="$DIR/enforcing-reboot.boot-id"
readonly BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"

mkdir -p "$DIR" /var/log
exec > >(tee -a /var/log/proxyvm-finalize.log) 2>&1

status() { printf '%s\n' "$1" > "$STATUS"; echo "[FINALIZE] $1 -- $(date -Is)"; }
cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "exit=$rc boot=$BOOT_ID $(date -Is)" > "$FAILED"
    status FAILED
    echo '[FINALIZE] Stopped; no further automatic reboots. Inspect journalctl -u proxyvm-finalize and /var/log/proxyvm-finalize.log.' >&2
  fi
}
trap cleanup EXIT

if [[ -e "$READY" ]]; then
  status READY
  exit 0
fi
if [[ -e "$FAILED" ]]; then
  echo '[FINALIZE] Previous failure exists. Refusing automatic retries.' >&2
  exit 1
fi
[[ -e "$DIR/bootstrap.done" ]] || { echo '[FINALIZE] Bootstrap is incomplete' >&2; exit 1; }
[[ -f "$DIR/bootstrap.boot-id" ]] || { echo '[FINALIZE] Missing bootstrap boot ID' >&2; exit 1; }
[[ "$BOOT_ID" != "$(cat "$DIR/bootstrap.boot-id")" ]] || {
  echo '[FINALIZE] Must reboot after bootstrap before SELinux transition' >&2
  exit 1
}
[[ ! -e /.autorelabel ]] || {
  echo '[FINALIZE] SELinux relabel marker remains; refusing to enable Enforcing' >&2
  exit 1
}

verify() {
  local unit
  for unit in incus-agent.service proxyvm-redsocks.service proxyvm-netfilter.service docker.service systemd-resolved.service sshd.service proxyvm-docker-dns.service; do
    systemctl is-active --quiet "$unit" || { echo "[FINALIZE] Inactive service: $unit" >&2; return 1; }
  done
  ls -Z /run/incus_agent/incus-agent | grep -Fq ':bin_t:'
  rpm -q selinux-policy-targeted >/dev/null
  [[ -z "$(ip -6 route show default)" ]] || { echo '[FINALIZE] Unexpected IPv6 default route' >&2; return 1; }
  ss -lun | grep -Fq "${DOCKER_DNS_IP}:53"
  bash /opt/proxyvm/bootstrap/90-verify.sh
}

echo "=== proxyvm finalize: $(date -Is), boot $BOOT_ID ==="
mode="$(getenforce)"
echo "[FINALIZE] SELinux mode: $mode"

if [[ -e "$REBOOT_ID" ]]; then
  [[ "$BOOT_ID" != "$(cat "$REBOOT_ID")" ]] || {
    echo '[FINALIZE] Enforcing verification requires a distinct reboot' >&2
    exit 1
  }
  [[ "$mode" == Enforcing ]] || { echo "[FINALIZE] Expected Enforcing after final reboot; got $mode" >&2; exit 1; }
  grep -qx 'SELINUX=enforcing' /etc/selinux/config
  status VERIFYING_FINAL_BOOT
  verify
  touch "$READY"
  status READY
  echo '=== proxyvm READY: SELinux Enforcing; networking and containers verified ==='
  exit 0
fi

[[ "$mode" == Permissive || "$mode" == Enforcing ]] || {
  echo "[FINALIZE] SELinux is not active after relabel: $mode" >&2
  exit 1
}
status VERIFYING_AFTER_RELABEL
verify
if [[ "$mode" == Permissive ]]; then
  status ENABLING_ENFORCING
  bash /opt/proxyvm/tools/enable-enforcing.sh
else
  echo '[FINALIZE] Already Enforcing; checking persistent configuration.'
fi
[[ "$(getenforce)" == Enforcing ]] || { echo '[FINALIZE] Enforcing transition did not complete' >&2; exit 1; }
grep -qx 'SELINUX=enforcing' /etc/selinux/config
verify

printf '%s\n' "$BOOT_ID" > "$REBOOT_ID"
status ENFORCING_AWAITING_FINAL_REBOOT
/usr/sbin/shutdown -r +1 'proxyvm Enforcing verified; rebooting for final check'
echo '[FINALIZE] Final verification reboot queued.'
