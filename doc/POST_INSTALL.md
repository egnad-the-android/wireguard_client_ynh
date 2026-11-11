Open the WireGuard Client configuration panel. Use Public access (Compy) to connect a VPS gateway (full-tunnel IPv4, local subnets excluded), or Advanced interfaces to upload a WireGuard client config.

After Compy setup, YunoHost sees the VPS public IP. nohost.me DynDNS updates automatically; for a custom domain, point the A record at the VPS and do not publish an AAAA record. Set PTR/rDNS on the VPS for outbound mail.

This Compy fork has not been tested on a real YunoHost server or a real VPS.
