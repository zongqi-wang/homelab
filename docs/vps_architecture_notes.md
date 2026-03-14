# VPS Architecture for Jellyfin & VLESS
The user wants to use a single VPS for two purposes:
1. As a reverse proxy front-door for Jellyfin (routing traffic via Tailscale to their home Unraid server).
2. As a VLESS (Xray/V2Ray) VPN endpoint for their family in China to bypass the Great Firewall (GFW).

Key considerations:
- VLESS with XTLS-Reality or WebSocket requires port 443 to look like standard HTTPS traffic to fool the GFW.
- Nginx Proxy Manager (NPM) also requires port 443 to serve the Jellyfin web interface.
- They cannot both listen on port 443 simultaneously without a multiplexer.

Solution:
- Use Xray (VLESS) as the primary listener on port 443. 
- Xray has a built-in "fallback" routing mechanism. If a packet is a VLESS VPN packet, Xray handles it and decrypts the VPN traffic. 
- If a packet is normal HTTPS web traffic (like someone trying to load `jellyfin.wangflix.com`), Xray "falls back" and forwards that raw TCP traffic directly to Nginx Proxy Manager (listening on a different local port, e.g., 8443).
- NPM then handles the SSL termination and forwards the traffic over Tailscale to the Unraid server.