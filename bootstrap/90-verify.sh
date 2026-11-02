#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env

for unit in proxyvm-netfilter.service proxyvm-redsocks.service docker.service systemd-resolved.service sshd.service; do
  systemctl is-active --quiet "$unit" || { echo "Inactive service: $unit" >&2; exit 1; }
done
nft list table ip proxyvm_nat >/dev/null
nft list table inet proxyvm_guard >/dev/null
curl -4 -fS --noproxy '*' --connect-timeout 10 --max-time 25 -o /dev/null "$TEST_URL"
resolvectl query "$DNS_TEST_DOMAIN"

docker_script='nslookup "$DNS_TEST_DOMAIN"; wget -T 10 -t 1 -q -O /dev/null "$TEST_URL"; echo "Docker DNS/HTTPS OK"'
docker run --rm \
  -e TEST_URL="$TEST_URL" -e DNS_TEST_DOMAIN="$DNS_TEST_DOMAIN" \
  docker.io/library/alpine:latest sh -ec "$docker_script"

podman_script='nslookup "$DNS_TEST_DOMAIN"; wget -T 10 -t 1 -q -O /dev/null "$TEST_URL"; echo Rootless_Podman_DNS_HTTPS_OK'
runuser -u "$GUEST_USER" -- env HOME="$GUEST_HOME" \
  PATH="$GUEST_HOME/.local/bin:$GUEST_HOME/.bun/bin:$GUEST_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin" \
  TEST_URL="$TEST_URL" DNS_TEST_DOMAIN="$DNS_TEST_DOMAIN" PODMAN_SCRIPT="$podman_script" \
  bash -euc '
    cd "$HOME"
    podman run --rm -e TEST_URL="$TEST_URL" -e DNS_TEST_DOMAIN="$DNS_TEST_DOMAIN" \
      docker.io/library/alpine:latest sh -ec "$PODMAN_SCRIPT"
  '

for cmd in git node npm python3 docker podman chromium-browser Xvfb; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done
for cmd in claude codex opencode agy bun pnpm uv; do
  case "$cmd" in
    claude) enabled="$TOOL_CLAUDE";; codex) enabled="$TOOL_CODEX";;
    opencode) enabled="$TOOL_OPENCODE";; agy) enabled="$TOOL_ANTIGRAVITY";;
    bun) enabled="$TOOL_BUN";; pnpm) enabled="$TOOL_PNPM";; uv) enabled="$TOOL_UV";;
  esac
  [[ "$enabled" == 1 ]] || continue
  runuser -u "$GUEST_USER" -- env HOME="$GUEST_HOME" \
    PATH="$GUEST_HOME/.local/bin:$GUEST_HOME/.bun/bin:$GUEST_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -c "command -v $cmd >/dev/null" || { echo "Missing: $cmd" >&2; exit 1; }
done

echo "SELinux: $(getenforce)"
if [[ "$(getenforce)" == Disabled && -e /.autorelabel ]]; then
  echo '[SELinux] Policy installed; first reboot will relabel in Permissive mode.'
  echo '[SELinux] After the reboot, validate then run tools/enable-enforcing.sh.'
elif [[ "$(getenforce)" != Enforcing ]]; then
  echo "[SELinux] Current mode: $(getenforce); run tools/enable-enforcing.sh after relabel + verification."
fi
if ! systemctl is-active --quiet incus-agent.service; then
  echo 'WARNING: Incus agent unavailable; inspect journalctl -u incus-agent.' >&2
fi

echo 'Bootstrap smoke tests passed. Run a separate killswitch test before sensitive work.'
