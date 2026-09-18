# Docker

A [DMS](https://github.com/AvengeMedia/DankMaterialShell) bar widget for Docker.

The popout opens with just the tree:

- **Tree:** Compose projects (with their containers and networks), standalone containers, images, networks and volumes. Click the chevron to expand or collapse. Hover a row for quick actions.
- **Detail pane:** clicking a container or Compose project widens the popout and opens the pane on the right. It shows state, image, ports, networks and volumes, the action buttons, and **live logs** (`docker logs -f`, or `docker compose logs -f` for a project), with a filter, follow / pause, wrap, copy all, clear, and open in terminal. Click the same item again or the × to collapse it.

## Actions

| Item | Actions |
|---|---|
| Container | Start / stop, restart, recreate (compose containers only), terminal shell, delete (`rm -f`) |
| Compose project | Start, stop, restart, recreate (`up -d --force-recreate`), down |
| Image / network / volume | Delete |
| Images / networks / volumes section | Prune dangling images / unused networks / unused anonymous volumes |

Delete, down and prune need a second click to confirm (this can be turned off in settings). When a command fails, the error from docker shows up as a toast.

Recreate and the other compose commands reuse what compose recorded in the container labels: project name, working directory, config files and env files. The result is the same as running `docker compose up -d --force-recreate` in the project directory.

## How it works

- `docker-state.py` reads everything in one pass from the Engine API over the unix socket (`DOCKER_HOST=unix://...` is honoured) and prints JSON.
- **While the popout is open**, a `docker events` process triggers a refresh (debounced), so the state updates as soon as anything changes. If the daemon goes away, the plugin reconnects every 5 s.
- **While the popout is closed**, no resident process runs: the event stream and log stream are stopped, the logs and the selection are cleared, and the popout content is unloaded once the close animation ends. The bar's running count is refreshed once a minute by running `docker-state.py`, which exits right away.

## Settings

Bar display (running count / running / total / icon only), hide stopped containers, confirm destructive actions, number of log lines loaded on open, log timestamps, and the terminal command prefix (default `kitty`; use `alacritty -e` for alacritty).

## Installation

```bash
git clone https://github.com/HotcocoaCanary/Canary-DMS-Plugins.git
ln -s "$PWD/Canary-DMS-Plugins/Docker" ~/.config/DankMaterialShell/plugins/canaryDocker
dms ipc call plugin-scan scan
dms ipc call plugins enable canaryDocker
```

Then add it to the bar under DMS Settings > Bar.
