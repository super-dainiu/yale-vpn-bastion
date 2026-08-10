#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
  echo "Run with sudo: sudo bash install.sh" >&2
  exit 2
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prefix=/opt/yale-vpn
venv="$prefix/venv"
browsers="$prefix/browsers"
epel=https://dl.fedoraproject.org/pub/epel/9/Everything/$(uname -m)/

if command -v apt-get >/dev/null; then
  apt-get update
  apt-get install -y ca-certificates curl openconnect vpnc-scripts python3-venv
elif command -v dnf >/dev/null; then
  # Amazon Linux 2023 ships no openconnect. Pull it from EPEL9 without
  # leaving a repo file behind, so a later `dnf upgrade` never considers
  # EPEL for anything else on the system.
  dnf install -y python3 python3-pip
  command -v openconnect >/dev/null ||
    dnf install -y --repofrompath="epel9,$epel" --nogpgcheck openconnect
  # Shared libraries the bundled Chromium needs, all from the distro's repo.
  dnf install -y --setopt=install_weak_deps=False \
    libXcomposite libXdamage libXfixes libXrandr alsa-lib atk at-spi2-core \
    at-spi2-atk mesa-libgbm libxkbcommon cups-libs pango
else
  echo "Need apt-get or dnf" >&2
  exit 1
fi

# vpn-slice does the split routing; Playwright drives the SSO login. Both live
# in their own venv so the system Python stays untouched. Playwright talks to
# Chromium over CDP, which avoids chromedriver -- there is no chromedriver
# build for linux-arm64, so Selenium cannot work on Graviton at all.
python3 -m venv "$venv"
"$venv/bin/pip" install --quiet --upgrade pip
"$venv/bin/pip" install --quiet playwright vpn-slice
PLAYWRIGHT_BROWSERS_PATH="$browsers" "$venv/bin/playwright" install chromium

# Chromium needs room to start; the box may have no swap.
if (( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) < 1500000 )) &&
   ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  if [[ ! -f /swapfile ]]; then
    # dd rather than fallocate: mkswap rejects the sparse extents that
    # fallocate leaves behind on xfs.
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab ||
    printf '%s\n' '/swapfile none swap sw,nofail 0 0' >>/etc/fstab
fi

install -m 0755 "$root/yale-vpn" /usr/local/sbin/yale-vpn
install -m 0755 "$root/yale-sso-browser" /usr/local/sbin/yale-sso-browser
unlink /usr/local/sbin/yale-open-url 2>/dev/null || true

# Older versions hijacked the default route and needed a watchdog to keep SSH
# alive. Split tunnelling leaves the default route alone, so the policy rules,
# the nftables table and the 5-second timer are all obsolete -- remove them
# rather than leave them rewriting the routing table forever.
for unit in yale-route-watchdog.timer yale-route-watchdog.service yale-route.service; do
  systemctl disable --now "$unit" 2>/dev/null || true
  rm -f "/etc/systemd/system/$unit"
done
rm -f /etc/systemd/networkd.conf.d/90-yale-management.conf
systemctl daemon-reload
if command -v nft >/dev/null; then
  nft delete table inet yale_management 2>/dev/null || true
fi
while ip rule del priority 90 2>/dev/null; do :; done
while ip rule del priority 100 2>/dev/null; do :; done
ip route flush table 200 2>/dev/null || true

echo "Installed. Next: sudo yale-vpn connect"
