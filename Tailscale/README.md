# Tailscale

A read-only [DMS](https://github.com/AvengeMedia/DankMaterialShell) bar widget for Tailscale.

The pill shows the connection state as an icon plus how many peers are online. The popout is a status panel — it never changes anything, so it needs no privileges:

- **This device:** a state ring, the Tailscale IP in large type, the hostname, the nearest relay and the client version. Click the card to copy the IP, or the button on its right to open the admin console in the browser.
- **Chips:** the exit node in use, whether this node offers one, accepted routes and DNS, Tailscale SSH, blocked incoming connections, advertised routes and the days left on the node key. A chip is filled when the setting is on and muted when it is off, so a glance is enough.
- **Devices:** a stacked bar of direct / relayed / offline peers with a legend, then one row per device — state dot, OS icon, name, IP and a chip saying how it is reached (direct, the relay code, or how long ago it was last seen). Hover a row to copy its IP or open its page in the admin console.
- **Traffic:** the five busiest peers, received and sent as paired bars against the busiest one.
- **Relay latency:** a bar chart of the six fastest DERP regions from `tailscale netcheck`, with the region in use highlighted, followed by chips for UDP, IPv4, IPv6, NAT type, port mapping and a captive portal.

Everything the popout shows is read straight from `tailscaled`. There are no start / stop / connect controls: changing anything would need root or the operator user, so those actions live in the `tailscale` CLI and in the admin console this widget links to.

## How it works

- `tailscale-state.py` reads `/localapi/v0/status` and `/localapi/v0/prefs` from `tailscaled` over the unix socket (`TS_SOCKET` is honoured) and prints JSON. Reading needs no privileges.
- `tailscale-state.py netcheck` runs `tailscale netcheck --format=json` and pairs the per-region latencies with the region names from `tailscale debug derp-map`. It runs when the popout opens (at most once a minute, and it can be turned off) or when you press refresh.
- The state is polled every 5 s while the popout is open and once a minute while it is closed, for the bar pill. Nothing stays resident: the popout content is unloaded once the close animation ends.

## Settings

Bar display (peers online / online / total / this device's IP / icon only), hide offline devices, whether to run a network check when the popout opens, and the admin console URL — change it for a self-hosted control server.

## Installation

```bash
git clone https://github.com/HotcocoaCanary/Canary-DMS-Plugins.git
ln -s "$PWD/Canary-DMS-Plugins/Tailscale" ~/.config/DankMaterialShell/plugins/canaryTailscale
dms ipc call plugin-scan scan
dms ipc call plugins enable canaryTailscale
```

Then add it to the bar under DMS Settings > Bar.
