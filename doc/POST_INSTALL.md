Open the app configuration panel. Use **The Gate** to connect a VPS gateway (full-tunnel IPv4, local subnets excluded), or Advanced interfaces to upload a WireGuard® client config.

After The Gate is set up, YunoHost sees the VPS public IP. nohost.me DynDNS updates automatically; for a custom domain, point the A record at the VPS and do not publish an AAAA record. Set PTR/rDNS on the VPS for outbound mail.

If a button fails, the panel may only show "Failed to run action". The details are in Tools > Logs.
