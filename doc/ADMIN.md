Use **The Gate** page in the app configuration panel to give your Compy (this YunoHost server) a public IP through a cheap Debian VPS, or the Advanced interfaces page to upload ordinary WireGuard® client configs.

After The Gate is set up, this server sends all IPv4 internet traffic through the VPS except local networks (LAN, RFC1918, Starlink CGNAT). YunoHost then sees the VPS public IP: diagnosis, Let's Encrypt, nohost.me DynDNS (automatic, no manual `dyndns update --ipv4`), and outbound mail all use that address. Set a PTR/rDNS record for the VPS in the provider panel. For a custom domain, point the A record at the VPS and do not publish an AAAA record (IPv6 internet is disabled while the tunnel is up; set DNS exposure to IPv4 only).

The VPS is a single point of failure and all bandwidth counts through it (OVH US standard region is typically unmetered 500 Mbps). If the VPS dies, your Compy loses internet until the watchdog (about 3 minutes) takes the tunnel down, or you click Turn tunnel off in the panel. LAN and LAN SSH stay reachable. Setup itself is verify-then-commit: a failed tunnel is rolled back automatically.

If a button fails, the panel may only show "Failed to run action". The details are in Tools > Logs (or `yunohost log show`). If a log entry stays open, run `sudo systemctl restart yunohost-api`.

This package is a fork of YunoHost-Apps/wireguard_client_ynh. It is not affiliated with or endorsed by YunoHost or WireGuard. WireGuard is a registered trademark of Jason A. Donenfeld.
