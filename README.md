# Canary DMS Plugins

Plugins for [Dank Material Shell](https://github.com/AvengeMedia/DankMaterialShell). Each plugin has its own repository; this one pulls them in as submodules so they can be cloned and linked in one go.

| Plugin | ID | Repository | What it does |
|---|---|---|---|
| [Docker Dashboard](DockerDashboard/) | `dockerDashboard` | [Canary-DMS-DockerDashboard](https://github.com/HotcocoaCanary/Canary-DMS-DockerDashboard) | Containers, Compose projects, images, networks and volumes in a bar popout, with start / stop / restart / recreate / delete and live logs |
| [Claude Usage and Stats](ClaudeUsageStats/) | `claudeUsageStats` | [Canary-DMS-ClaudeUsageStats](https://github.com/HotcocoaCanary/Canary-DMS-ClaudeUsageStats) | Claude Code `/usage` limits and `/stats` charts built from local transcripts |
| [Tailscale Dashboard](TailscaleDashboard/) | `tailscaleDashboard` | [Canary-DMS-TailscaleDashboard](https://github.com/HotcocoaCanary/Canary-DMS-TailscaleDashboard) | Read-only Tailscale status: this device, the devices in the tailnet, traffic and relay latencies as charts, plus a link to the admin console |

## Installation

Clone with the submodules and link the plugins you want into the DMS plugins folder:

```bash
git clone --recurse-submodules https://github.com/HotcocoaCanary/Canary-DMS-Plugins.git
ln -s "$PWD/Canary-DMS-Plugins/DockerDashboard" ~/.config/DankMaterialShell/plugins/dockerDashboard
ln -s "$PWD/Canary-DMS-Plugins/ClaudeUsageStats" ~/.config/DankMaterialShell/plugins/claudeUsageStats
ln -s "$PWD/Canary-DMS-Plugins/TailscaleDashboard" ~/.config/DankMaterialShell/plugins/tailscaleDashboard
dms ipc call plugin-scan scan
```

Then enable them under DMS Settings > Plugins and add them to the bar. See each plugin's README for details.

A single plugin can also be cloned on its own — the plugin repositories have their `plugin.json` at the root, so the clone is what gets linked into the plugins folder.

## Working with the submodules

```bash
git submodule update --remote            # pull each plugin's latest main
git -C DockerDashboard commit -am "..." && git -C DockerDashboard push   # work inside a plugin as usual
git commit -am "Bump Docker Dashboard"             # then record the new commit here
```

## License

MIT. See the `LICENSE` file in each plugin repository.
