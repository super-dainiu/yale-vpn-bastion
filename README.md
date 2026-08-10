# yale-vpn

A tiny Yale VPN jump host. Runs on Ubuntu 24.04 and Amazon Linux 2023,
on x86_64 and arm64.

## 1. Install

```bash
git clone https://github.com/super-dainiu/yale-vpn.git
cd yale-vpn
sudo bash install.sh
```

## 2. Connect

```bash
ssh ubuntu@BASTION_IP
sudo yale-vpn connect First.Last@yale.edu
```

Enter the NetID password and approve Duo if prompted. A headless browser on the
bastion completes Yale's Microsoft/Duo flow and then exits.

```bash
sudo yale-vpn status
sudo yale-vpn routes
sudo yale-vpn disconnect
```

The password, temporary browser profile, and VPN cookie are not stored.

## 3. SSH to YCRC

Copy [`ssh_config`](ssh_config) to `~/.ssh/config`, replace `BASTION_IP` and
`YOUR_NETID`, then:

```bash
mkdir -p ~/.ssh/cm
chmod 700 ~/.ssh ~/.ssh/cm
ssh yale-aws
ssh misha
```

Each YCRC host needs Duo once. Its ControlMaster then reuses that authenticated
connection.

## Split tunnel

Only Yale's own address space enters the tunnel. Everything else keeps using
the cloud default route, untouched:

```
128.36.0.0/16   130.132.0.0/16   192.31.2.0/24
192.31.236.0/24 192.35.89.0/24   172.18.190.0/24 (Yale DNS)
```

Those are the prefixes AS29 (Yale University) announces, plus the internal
resolver subnet. `vpn-slice` installs exactly these routes and nothing more, so
the default route never moves.

That matters more than it sounds. A full tunnel sends every packet to New Haven
first. From an instance in Tokyo that turns a 2.6 ms hop to a nearby API into
roughly 175 ms, and caps a 300 MB/s download at about 13 MB/s -- the round trip
to Connecticut is ~164 ms and no amount of tuning removes it. Yale traffic has
to pay that; GitHub, npm and everything else should not.

Because the default route stays put, SSH, Tailscale and any other existing
connectivity are unaffected, and none of the policy rules, nftables tables or
watchdog timers that a full tunnel needs exist here at all.

Two consequences worth knowing:

- Most `*.yale.edu` sites are hosted off-campus (Fastly, Pantheon, AWS, and
  `docs.ycrc.yale.edu` on GitHub Pages). They are public, so they resolve and
  load without the VPN -- routing them through it would only add latency.
- Licensed journal content authorizes by source IP and is served from publisher
  networks, so a split tunnel does not cover it. Use the library's EZproxy
  (`ezproxy.library.yale.edu`), which needs no VPN.

## DNS

Cluster names like `misha.ycrc.yale.edu` exist only in Yale's internal
resolver. `vpn-slice` resolves them at connect time and writes `/etc/hosts`,
removing them again on disconnect. `/etc/resolv.conf` is never modified, so a
host resolver such as Tailscale's MagicDNS keeps working.

To add a name, put it in `YALE_HOSTS` in [`yale-vpn`](yale-vpn).

## Login

Yale's SSO runs through Microsoft and Duo, which needs a real browser.
Playwright drives Chromium over CDP; both live in a venv under `/opt/yale-vpn`,
so the system Python is untouched. CDP also avoids chromedriver, which has no
official `linux-arm64` build -- the reason a Selenium-based login cannot work
on Graviton.

The entire implementation is in three readable files:

- [`install.sh`](install.sh): packages, venv, bundled Chromium
- [`yale-vpn`](yale-vpn): routes, connect, status, disconnect
- [`yale-sso-browser`](yale-sso-browser): Microsoft/Duo browser steps

MIT licensed.
