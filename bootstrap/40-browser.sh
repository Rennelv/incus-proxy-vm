#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/proxyvm/config/guest.env
source /opt/proxyvm/config/packages.sh

dnf install -y --disablerepo=fedora-cisco-openh264 \
  "${PACKAGES_BROWSER[@]}"

bash /opt/proxyvm/bootstrap/selinux-labels.sh

runuser -u "$GUEST_USER" -- env HOME="$GUEST_HOME" \
  PATH="$GUEST_HOME/.local/bin:$GUEST_HOME/.bun/bin:$GUEST_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin" \
  TOOL_PLAYWRIGHT="$TOOL_PLAYWRIGHT" TOOL_PLAYWRIGHT_NPM_PACKAGE="$TOOL_PLAYWRIGHT_NPM_PACKAGE" \
  bash -euc '
    mkdir -p "$HOME/tools/browser"
    cd "$HOME/tools/browser"
    if [[ ! -f package.json ]]; then npm init -y; fi
    if [[ "$TOOL_PLAYWRIGHT" == 1 ]]; then
      npm install --save-exact "$TOOL_PLAYWRIGHT_NPM_PACKAGE"
      npx playwright install chromium
    fi
  '

if [[ "$TOOL_X11_FORWARDING" == 1 ]]; then
  install -D -m 0644 /opt/proxyvm/files/etc/ssh/sshd_config.d/50-proxyvm-x11.conf \
    /etc/ssh/sshd_config.d/50-proxyvm-x11.conf
  sshd -t
  systemctl reload sshd.service
fi

cat >"$GUEST_HOME/tools/browser/smoke.mjs" <<'JS'
import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto('https://example.org', { waitUntil: 'domcontentloaded', timeout: 30000 });
  console.log('Title:', await page.title());
} finally {
  await browser.close();
}
JS
chown "$GUEST_USER:$GUEST_USER" "$GUEST_HOME/tools/browser/smoke.mjs"
