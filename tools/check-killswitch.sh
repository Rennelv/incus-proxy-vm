#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env

testurl='https://1.1.1.1/cdn-cgi/trace'
echo 'Preflight: both containers MUST reach HTTPS while Redsocks runs.'
sudo docker run --rm alpine:latest wget -T 6 -t 1 -q -O /dev/null "$testurl"
podman run --rm docker.io/library/alpine:latest wget -T 6 -t 1 -q -O /dev/null "$testurl"

restarted=0
restore() {
  if (( restarted == 0 )); then
    sudo systemctl start proxyvm-redsocks.service
    restarted=1
  fi
}
trap restore EXIT
sudo systemctl stop proxyvm-redsocks.service
failed=0
if timeout 15 sudo docker run --rm alpine:latest wget -T 4 -t 1 -q -O /dev/null "$testurl"; then
  echo 'FAIL: Docker still has external TCP without Redsocks' >&2
  failed=1
else
  echo 'Docker blocked: OK'
fi
if timeout 15 podman run --rm docker.io/library/alpine:latest wget -T 4 -t 1 -q -O /dev/null "$testurl"; then
  echo 'FAIL: Podman still has external TCP without Redsocks' >&2
  failed=1
else
  echo 'Podman blocked: OK'
fi
restore
trap - EXIT
systemctl is-active --quiet proxyvm-redsocks.service
(( failed == 0 )) || exit 1
curl -4 -fS --noproxy '*' --max-time 20 -o /dev/null "$testurl"
echo 'TCP killswitch checks OK; DNS and UDP require separate packet-level testing.'
