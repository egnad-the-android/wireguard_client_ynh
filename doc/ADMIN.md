Use the Public access (Compy) page in the app configuration panel to connect a cheap Debian VPS as a public gateway, or the Advanced interfaces page to upload ordinary WireGuard client configs.

After Compy setup, this server sends all IPv4 internet traffic through the VPS except local networks (LAN, RFC1918, Starlink CGNAT). YunoHost then sees the VPS public IP: diagnosis, Let's Encrypt, nohost.me DynDNS (automatic, no manual `dyndns update --ipv4`), and outbound mail all use that address. Set a PTR/rDNS record for the VPS in the provider panel. For a custom domain, point the A record at the VPS and do not publish an AAAA record (IPv6 internet is disabled while the tunnel is up; set DNS exposure to IPv4 only).

The VPS is a single point of failure and all bandwidth counts through it (OVH US standard region is typically unmetered 500 Mbps). If the VPS dies, this box loses internet until the watchdog (about 3 minutes) takes the tunnel down, or you click Turn tunnel off in the panel. LAN and LAN SSH stay reachable. Setup itself is verify-then-commit: a failed tunnel is rolled back automatically.

This Compy fork has not been tested on a real YunoHost server or a real VPS.
