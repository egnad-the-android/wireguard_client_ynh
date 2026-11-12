# The Gate

The Gate is the gateway to your Compy — a Personal Keepsake Cloud running [YunoHost](https://yunohost.org). It gives a home server that has no public IP (for example behind Starlink CGNAT) a public IPv4 address, by running a full [WireGuard®](https://www.wireguard.com/) tunnel to a cheap Debian VPS.

This package is a fork of [YunoHost-Apps/wireguard_client_ynh](https://github.com/YunoHost-Apps/wireguard_client_ynh). It is **not affiliated with or endorsed by YunoHost or WireGuard**. The YunoHost app id remains `wireguard_client`, so an existing install upgrades in place and the live tunnel keeps working:

```
sudo yunohost app upgrade wireguard_client -u https://github.com/egnad-the-android/wireguard_client_ynh
```

A fresh install:

```
sudo yunohost app install https://github.com/egnad-the-android/wireguard_client_ynh
```

## What The Gate does

The Gate turns a minimal Debian VPS into a public doorway for your Compy (this YunoHost server). The VPS runs only WireGuard® and NAT; all HTTPS certificates stay on your Compy.

After setup, **all IPv4 internet traffic from your Compy goes through the VPS**, except local networks (LAN, RFC1918, and Starlink CGNAT `100.64.0.0/10`). YunoHost then sees the VPS public IP, so diagnosis, Let's Encrypt, nohost.me DynDNS (automatic via ip.yunohost.org — no manual `yunohost dyndns update --ipv4`), and outbound mail all use that address. Set a PTR/rDNS record for the VPS in the provider panel (for example the US OVH VPS panel). For a custom domain, point the A record at the VPS IPv4 and do not publish an AAAA record (IPv6 internet is disabled while the tunnel is up).

The VPS is a **single point of failure** and all bandwidth counts through it (OVH US standard region is typically unmetered 500 Mbps). If the VPS dies, your Compy loses internet until a watchdog (about 3 minutes without a handshake) takes the tunnel down, or you click **Turn tunnel off**. LAN and LAN SSH stay reachable. Setup is verify-then-commit: the tunnel is kept only if handshake, a tunnel ping, and `https://ip.yunohost.org` returning the VPS IP all succeed; otherwise it is rolled back.

This works behind carrier-grade NAT, including Starlink: the underlay CGNAT/LAN routes stay outside the tunnel.

The Advanced interfaces page from upstream is still there, for uploading ordinary WireGuard® client configs.

## User flow

1. Install this app (or upgrade an existing `wireguard_client` install from this tree).
2. Open the app configuration panel, **The Gate** page, and copy the SSH public key shown there.
3. In the OVH (or other) panel, create a minimal Debian VPS and add that public key for the SSH user (often `debian` on OVH Debian images).
4. Back in YunoHost, enter the VPS IP address or hostname (and the SSH user or port if they are not the defaults). Click **Test connection**, compare the fingerprint with the provider console, then click **Pin host key**.
5. Review the port list (pre-filled from the YunoHost firewall) and the networks that stay outside the tunnel, then press **Connect and set up the VPS**.
6. For nohost.me, wait for DynDNS to pick up the VPS IP. For a custom domain, point the DNS A record at the VPS IPv4 address. Do not publish an AAAA record in this version. Set PTR/rDNS on the VPS if you send mail.

If a button fails, the panel may only show "Failed to run action". The details are in **Tools > Logs** (or `yunohost log show`). If a log entry stays open and later admin tasks appear under it, run `sudo systemctl restart yunohost-api`.

Removing the app does not uninstall the VPS side. To tear The Gate down later, run the setup script on the VPS with `--uninstall` while you still have SSH access.

## Changelog

### 1.0.20210914+gate1~ynh1

The public-access feature (previously called Compy) is now named **The Gate**. The app id, the tunnel interface name `compy`, setting keys, and install paths are unchanged, so a live install upgrades in place.

Fixes in this version:

- Every SSH and network call has a timeout, and SSH probes do not read stdin. A stalled "Test public ports" action can no longer leave a YunoHost operation log open (which then collected every later admin task). If that ever happens again, `sudo systemctl restart yunohost-api` clears it.
- The VPS firewall allows ICMP echo-request on the WireGuard® interface, so a ping to the tunnel gateway (for example 10.99.0.1) works. After upgrading, click **Re-sync ports** on The Gate page so the VPS applies the new rule. Re-running setup is also safe and idempotent.
- Status no longer shows "Interface state: unknown" (normal for a WireGuard® interface). It reports whether the tunnel is up or down from the link flags and the handshake.
- Clearer error messages on failure. Details are in Tools > Logs.
- Cleanup of stale comments and leftover labels (for example "Re-sync ports (v1.1)").

## License, trademark, and credit

This software is released under the MIT License. See [LICENSE](LICENSE).

This project is a fork of [YunoHost-Apps/wireguard_client_ynh](https://github.com/YunoHost-Apps/wireguard_client_ynh) (upstream maintainer: tituspijean) and is not affiliated with or endorsed by the YunoHost project.

WireGuard is a registered trademark of Jason A. Donenfeld. This project uses WireGuard® only as a descriptive reference to the protocol it employs, never as part of the product name. It is not affiliated with or endorsed by Jason A. Donenfeld or the WireGuard project.

Upstream copyright is held by YunoHost contributors. The Gate fork is Copyright (c) 2026 Egnad the Android and contributors.
