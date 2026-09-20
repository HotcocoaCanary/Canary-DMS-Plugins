# Canary DMS Plugins

Plugins for [Dank Material Shell](https://github.com/AvengeMedia/DankMaterialShell). Each plugin has its own repository; this one pulls them in as submodules so they can be cloned and linked in one go.

| Plugin | ID | Repository | What it does |
|---|---|---|---|
| [Docker](Docker/) | `canaryDocker` | [Canary-DMS-Docker](https://github.com/HotcocoaCanary/Canary-DMS-Docker) | Containers, Compose projects, images, networks and volumes in a bar popout, with start / stop / restart / recreate / delete and live logs |
| [Claude Usage And Stats](ClaudeUsage/) | `canaryClaudeUsage` | [Canary-DMS-ClaudeUsage](https://github.com/HotcocoaCanary/Canary-DMS-ClaudeUsage) | Claude Code `/usage` limits and `/stats` charts built from local transcripts |
| [Tailscale](Tailscale/) | `canaryTailscale` | [Canary-DMS-Tailscale](https://github.com/HotcocoaCanary/Canary-DMS-Tailscale) | Read-only Tailscale status: this device, the devices in the tailnet, traffic and relay latencies as charts, plus a link to the admin console |

## Installation

Clone with the submodules and link the plugins you want into the DMS plugins folder:

```bash
git clone --recurse-submodules https://github.com/HotcocoaCanary/Canary-DMS-Plugins.git
ln -s "$PWD/Canary-DMS-Plugins/Docker" ~/.config/DankMaterialShell/plugins/canaryDocker
ln -s "$PWD/Canary-DMS-Plugins/ClaudeUsage" ~/.config/DankMaterialShell/plugins/canaryClaudeUsage
ln -s "$PWD/Canary-DMS-Plugins/Tailscale" ~/.config/DankMaterialShell/plugins/canaryTailscale
dms ipc call plugin-scan scan
```

Then enable them under DMS Settings > Plugins and add them to the bar. See each plugin's README for details.

A single plugin can also be cloned on its own — the plugin repositories have their `plugin.json` at the root, so the clone is what gets linked into the plugins folder.

## Working with the submodules

```bash
git submodule update --remote            # pull each plugin's latest main
git -C Docker commit -am "..." && git -C Docker push   # work inside a plugin as usual
git commit -am "Bump Docker"             # then record the new commit here
```

## License

MIT. See the `LICENSE` file in each plugin repository.
