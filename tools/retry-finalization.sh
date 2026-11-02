#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
if [[ ! -e /var/lib/proxyvm/bootstrap.done ]]; then
  echo 'Bootstrap has not finished; run /opt/proxyvm/bootstrap/entrypoint.sh first.' >&2
  exit 1
fi
if [[ -e /.autorelabel ]]; then
  echo 'SELinux relabel is still pending; do not retry finalization.' >&2
  exit 1
fi
if [[ -e /var/lib/proxyvm/ready ]]; then
  echo 'Already READY; no retry needed.'
  exit 0
fi
rm -f /var/lib/proxyvm/finalize.failed
systemctl reset-failed proxyvm-finalize.service
systemctl start proxyvm-finalize.service
cat /var/lib/proxyvm/finalize.state
