WireGuard® is a fast and modern VPN that utilizes state-of-the-art cryptography.
It aims to be faster, simpler, leaner, and more useful than IPsec. It intends to be considerably more performant than OpenVPN. WireGuard is designed as a general purpose VPN.

This package ships a YunoHost configuration panel to load WireGuard® configuration files and create the VPNs.

This fork also adds **The Gate**, a page that can expose your Compy (this YunoHost server) through a cheap Debian VPS (WireGuard® plus NAT only). After setup, all IPv4 internet from the server goes through the VPS except local subnets, so YunoHost sees the VPS public IP. This package is a fork of YunoHost-Apps/wireguard_client_ynh and is not affiliated with or endorsed by YunoHost or WireGuard.
