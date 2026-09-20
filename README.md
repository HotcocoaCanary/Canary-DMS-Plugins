# Canary DMS Plugins

Plugins for [Dank Material Shell](https://github.com/AvengeMedia/DankMaterialShell).

| Plugin | ID | What it does |
|---|---|---|
| [Docker](Docker/) | `canaryDocker` | Containers, Compose projects, images, networks and volumes in a bar popout, with start / stop / restart / recreate / delete and live logs |
| [Canary Claude Usage](ClaudeUsage/) | `canaryClaudeUsage` | Claude Code `/usage` limits and `/stats` charts built from local transcripts |
| [Tailscale](Tailscale/) | `canaryTailscale` | Read-only Tailscale status: this device, the devices in the tailnet, traffic and relay latencies as charts, plus a link to the admin console |

## Installation

Each plugin lives in its own directory. Clone the repository and link the ones you want into the DMS plugins folder:

```bash
git clone https://github.com/HotcocoaCanary/Canary-DMS-Plugins.git
ln -s "$PWD/Canary-DMS-Plugins/Docker" ~/.config/DankMaterialShell/plugins/canaryDocker
ln -s "$PWD/Canary-DMS-Plugins/ClaudeUsage" ~/.config/DankMaterialShell/plugins/canaryClaudeUsage
ln -s "$PWD/Canary-DMS-Plugins/Tailscale" ~/.config/DankMaterialShell/plugins/canaryTailscale
dms ipc call plugin-scan scan
```

Then enable them under DMS Settings > Plugins and add them to the bar. See each plugin's README for details.

## License

MIT. See the `LICENSE` file in each plugin directory.
