import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginComponent {
    id: root

    property string lang: (SessionData.locale || Qt.locale().name).split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }

    // Settings
    property bool hideStopped: pluginData.hideStopped === true
    property bool confirmDestructive: pluginData.confirmDestructive !== false
    property string terminalCommand: pluginData.terminalCommand || "kitty"
    property int logTail: pluginData.logTail || 500
    property bool logTimestamps: pluginData.logTimestamps !== false
    property string pillMode: pluginData.pillMode || "running" // running | ratio | icon

    // --- Snapshot from docker-state.py ---
    property var snapshot: ({
            containers: [],
            projects: [],
            images: [],
            networks: [],
            volumes: []
        })
    property string dockerError: ""
    readonly property bool available: dockerError === "" && snapshot.version !== undefined

    readonly property var containerById: {
        var m = {};
        for (var i = 0; i < snapshot.containers.length; i++)
            m[snapshot.containers[i].id] = snapshot.containers[i];
        return m;
    }
    readonly property int runningCount: snapshot.containers.filter(function (c) {
        return c.state === "running";
    }).length

    readonly property string scriptPath: Qt.resolvedUrl("docker-state.py").toString().replace(/^file:\/\//, "")

    // Tree only until something is selected, then tree + detail/logs
    popoutWidth: selected ? 880 : 380

    // --- UI state ---
    property var expanded: ({})
    property var selected: null // { kind: "container" | "project", id } shown in the right pane
    property bool popoutOpen: false
    property bool contentActive: false // popout content is unloaded while closed
    property real treeContentHeight: 0
    property string hoverHint: "" // tree buttons, shown under the tree
    property string logHint: "" // log toolbar buttons, shown under the logs
    property var busy: ({}) // row key -> true while an action runs
    property string pendingConfirm: "" // "rowKey|action" awaiting a second click

    function isExpanded(key, def) {
        return key in expanded ? expanded[key] : def;
    }

    function toggle(key, def) {
        var e = Object.assign({}, expanded);
        e[key] = !isExpanded(key, def);
        expanded = e;
    }

    function setBusy(key, on) {
        var b = Object.assign({}, busy);
        if (on)
            b[key] = true;
        else
            delete b[key];
        busy = b;
    }

    // --- Formatting ---

    function formatBytes(n) {
        if (n >= 1e9)
            return (n / 1e9).toFixed(1) + " GB";
        if (n >= 1e6)
            return (n / 1e6).toFixed(0) + " MB";
        if (n >= 1e3)
            return (n / 1e3).toFixed(0) + " KB";
        return n + " B";
    }

    function formatPorts(ports) {
        return ports.filter(function (p) {
            return p.public;
        }).map(function (p) {
            return p.public + "→" + p.private + (p.type !== "tcp" ? "/" + p.type : "");
        }).join(", ");
    }

    function stateColor(c) {
        if (c.state === "running") {
            if (c.health === "unhealthy")
                return Theme.error;
            if (c.health === "starting")
                return Theme.warning;
            return Theme.success;
        }
        if (c.state === "paused" || c.state === "restarting")
            return Theme.warning;
        if (c.state === "dead")
            return Theme.error;
        return Theme.surfaceVariantText;
    }

    // --- Tree, flattened into rows for one ListView ---

    function containerRows(list, depth, out) {
        for (var i = 0; i < list.length; i++) {
            var c = list[i];
            if (hideStopped && c.state !== "running")
                continue;
            var ports = formatPorts(c.ports);
            out.push({
                key: "container:" + c.id,
                kind: "container",
                depth: depth,
                expandable: false,
                icon: "deployed_code",
                dot: stateColor(c),
                title: c.service || c.name,
                subtitle: c.status + (ports ? "  ·  " + ports : ""),
                data: c
            });
        }
    }

    function section(key, title, count, icon, out) {
        var open = isExpanded(key, false);
        out.push({
            key: key,
            kind: "section",
            depth: 0,
            expandable: count > 0,
            open: open,
            icon: icon,
            title: title,
            subtitle: String(count)
        });
        return open;
    }

    readonly property var rows: {
        var out = [], s = snapshot;

        for (var p = 0; p < s.projects.length; p++) {
            var pr = s.projects[p];
            var list = pr.containers.map(function (id) {
                return containerById[id];
            });
            var running = list.filter(function (c) {
                return c.state === "running";
            }).length;
            var key = "project:" + pr.name;
            var open = isExpanded(key, true);
            out.push({
                key: key,
                kind: "project",
                depth: 0,
                expandable: true,
                open: open,
                icon: "stacks",
                dot: running === list.length ? Theme.success : running > 0 ? Theme.warning : Theme.surfaceVariantText,
                title: "Compose: " + pr.name,
                subtitle: running + " / " + list.length + " " + tr("running") + (pr.workingDir ? "  ·  " + pr.workingDir.replace(/^\/home\/[^/]+/, "~") : ""),
                data: pr,
                running: running,
                total: list.length
            });
            if (!open)
                continue;
            containerRows(list, 1, out);
            for (var n = 0; n < pr.networks.length; n++)
                out.push({
                    key: key + ":net:" + pr.networks[n],
                    kind: "detail",
                    depth: 1,
                    expandable: false,
                    icon: "lan",
                    title: pr.networks[n]
                });
        }

        var standalone = s.containers.filter(function (c) {
            return !c.project;
        });
        if (standalone.length && section("section:containers", tr("Containers"), standalone.length, "deployed_code", out))
            containerRows(standalone, 1, out);

        if (section("section:images", tr("Images"), s.images.length, "layers", out))
            for (var i = 0; i < s.images.length; i++) {
                var im = s.images[i];
                out.push({
                    key: "image:" + im.id,
                    kind: "image",
                    depth: 1,
                    expandable: false,
                    icon: "layers",
                    title: im.tags.length ? im.tags[0] + (im.tags.length > 1 ? "  +" + (im.tags.length - 1) : "") : "<none>  " + im.id,
                    subtitle: formatBytes(im.size) + "  ·  " + (im.dangling ? tr("dangling") : im.containers > 0 ? tr("in use") + " (" + im.containers + ")" : tr("unused")),
                    data: im
                });
            }

        if (section("section:networks", tr("Networks"), s.networks.length, "lan", out))
            for (var k = 0; k < s.networks.length; k++) {
                var nw = s.networks[k];
                out.push({
                    key: "network:" + nw.id,
                    kind: "network",
                    depth: 1,
                    expandable: false,
                    icon: "lan",
                    title: nw.name,
                    subtitle: nw.driver + "  ·  " + (nw.containers > 0 ? nw.containers + " " + tr("containers") : tr("unused")) + (nw.project ? "  ·  " + nw.project : ""),
                    data: nw
                });
            }

        if (section("section:volumes", tr("Volumes"), s.volumes.length, "database", out))
            for (var v = 0; v < s.volumes.length; v++) {
                var vo = s.volumes[v];
                out.push({
                    key: "volume:" + vo.name,
                    kind: "volume",
                    depth: 1,
                    expandable: false,
                    icon: "database",
                    title: vo.anonymous ? tr("anonymous") + "  " + vo.name.substring(0, 12) : vo.name,
                    subtitle: (vo.containers > 0 ? tr("in use") + " (" + vo.containers + ")" : tr("unused")) + (vo.project ? "  ·  " + vo.project : ""),
                    data: vo
                });
            }

        return out;
    }

    // --- Actions ---

    function composeArgs(pr) {
        var args = ["docker", "compose", "-p", pr.name];
        if (pr.workingDir)
            args.push("--project-directory", pr.workingDir);
        for (var i = 0; i < pr.configFiles.length; i++)
            args.push("-f", pr.configFiles[i]);
        for (var j = 0; j < pr.envFiles.length; j++)
            args.push("--env-file", pr.envFiles[j]);
        return args;
    }

    function projectOf(c) {
        for (var i = 0; i < snapshot.projects.length; i++)
            if (snapshot.projects[i].name === c.project)
                return snapshot.projects[i];
        return null;
    }

    // Available actions for a row: [{ id, icon, label, danger, cmd }]
    function actionsFor(row) {
        var a = [], d = row.data;
        if (row.kind === "container") {
            var pr = projectOf(d);
            if (d.state === "running")
                a.push({
                    id: "stop",
                    icon: "stop",
                    label: tr("Stop"),
                    cmd: ["docker", "stop", d.id]
                });
            else
                a.push({
                    id: "start",
                    icon: "play_arrow",
                    label: tr("Start"),
                    cmd: ["docker", "start", d.id]
                });
            if (d.state === "running")
                a.push({
                    id: "restart",
                    icon: "restart_alt",
                    label: tr("Restart"),
                    cmd: ["docker", "restart", d.id]
                });
            if (pr && d.service)
                a.push({
                    id: "recreate",
                    icon: "autorenew",
                    label: tr("Recreate"),
                    cmd: composeArgs(pr).concat(["up", "-d", "--force-recreate", "--no-deps", d.service])
                });
            a.push({
                id: "logs",
                icon: "article",
                label: tr("Logs")
            });
            if (d.state === "running")
                a.push({
                    id: "shell",
                    icon: "terminal",
                    label: tr("Shell")
                });
            a.push({
                id: "delete",
                icon: "delete",
                label: tr("Delete"),
                danger: true,
                cmd: ["docker", "rm", "-f", d.id]
            });
        } else if (row.kind === "project") {
            var base = composeArgs(d);
            if (row.running < row.total)
                a.push({
                    id: "start",
                    icon: "play_arrow",
                    label: tr("Start"),
                    cmd: base.concat(["start"])
                });
            if (row.running > 0)
                a.push({
                    id: "stop",
                    icon: "stop",
                    label: tr("Stop"),
                    cmd: base.concat(["stop"])
                });
            a.push({
                id: "restart",
                icon: "restart_alt",
                label: tr("Restart"),
                cmd: base.concat(["restart"])
            });
            a.push({
                id: "recreate",
                icon: "autorenew",
                label: tr("Recreate"),
                cmd: base.concat(["up", "-d", "--force-recreate"])
            });
            a.push({
                id: "logs",
                icon: "article",
                label: tr("Logs")
            });
            a.push({
                id: "down",
                icon: "delete",
                label: tr("Down"),
                danger: true,
                cmd: base.concat(["down"])
            });
        } else if (row.kind === "image") {
            a.push({
                id: "delete",
                icon: "delete",
                label: tr("Delete"),
                danger: true,
                // An image with several tags can only be removed by id with -f
                cmd: d.tags.length > 1 ? ["docker", "image", "rm", "-f", d.id] : ["docker", "image", "rm", d.tags[0] || d.id]
            });
        } else if (row.kind === "network" && !d.builtin) {
            a.push({
                id: "delete",
                icon: "delete",
                label: tr("Delete"),
                danger: true,
                cmd: ["docker", "network", "rm", d.name]
            });
        } else if (row.kind === "volume") {
            a.push({
                id: "delete",
                icon: "delete",
                label: tr("Delete"),
                danger: true,
                cmd: ["docker", "volume", "rm", d.name]
            });
        } else if (row.kind === "section") {
            var prune = {
                "section:images": ["image", tr("Prune dangling images")],
                "section:networks": ["network", tr("Prune unused networks")],
                "section:volumes": ["volume", tr("Prune unused anonymous volumes")]
            }[row.key];
            if (prune)
                a.push({
                    id: "prune",
                    icon: "cleaning_services",
                    label: prune[1],
                    danger: true,
                    cmd: ["docker", prune[0], "prune", "-f"]
                });
        }
        return a;
    }

    function trigger(row, action) {
        if (action.id === "logs") {
            select(row);
            return;
        }
        if (action.id === "shell") {
            openShell(row.data);
            return;
        }
        var token = row.key + "|" + action.id;
        if (action.danger && confirmDestructive && pendingConfirm !== token) {
            pendingConfirm = token;
            confirmTimer.restart();
            return;
        }
        pendingConfirm = "";
        runAction(row.key, row.title + ": " + action.label, action.cmd);
    }

    Timer {
        id: confirmTimer
        interval: 3000
        onTriggered: root.pendingConfirm = ""
    }

    Component {
        id: actionProcess
        Process {
            property string rowKey
            property string label
            stderr: StdioCollector {
                id: errOut
            }
            onExited: code => {
                root.setBusy(rowKey, false);
                if (code !== 0)
                    ToastService.showError(label + " " + root.tr("failed"), errOut.text.trim());
                root.refresh();
                destroy();
            }
        }
    }

    function runAction(rowKey, label, cmd) {
        setBusy(rowKey, true);
        var p = actionProcess.createObject(root, {
            rowKey: rowKey,
            label: label,
            command: cmd
        });
        p.running = true;
    }

    function terminalArgs() {
        return terminalCommand.trim().split(/\s+/);
    }

    function openShell(c) {
        Quickshell.execDetached(terminalArgs().concat(["docker", "exec", "-it", c.id, "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]));
    }

    // --- State refresh, driven by docker events ---

    function refresh() {
        if (stateProcess.running)
            refreshAgain = true;
        else
            stateProcess.running = true;
    }
    property bool refreshAgain: false

    Process {
        id: stateProcess
        command: ["python3", root.scriptPath]
        stdout: StdioCollector {
            onStreamFinished: {
                var out;
                try {
                    out = JSON.parse(text);
                } catch (e) {
                    root.dockerError = "bad output";
                    return;
                }
                if (out.error) {
                    root.dockerError = out.error;
                    return;
                }
                root.dockerError = "";
                root.snapshot = out;
            }
        }
        onExited: {
            if (root.refreshAgain) {
                root.refreshAgain = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    // Coalesce event bursts (compose up emits dozens) into one refresh
    Timer {
        id: debounce
        interval: 300
        onTriggered: root.refresh()
    }

    Process {
        id: eventsProcess
        command: ["docker", "events", "--format", "{{.Type}}"]
        stdout: SplitParser {
            onRead: debounce.restart()
        }
        onExited: {
            if (root.popoutOpen)
                reconnect.start();
        }
    }

    // Daemon restarted or not up yet: retry the event stream and refresh
    Timer {
        id: reconnect
        interval: 5000
        onTriggered: {
            if (!root.popoutOpen)
                return;
            eventsProcess.running = true;
            root.refresh();
        }
    }

    // Keeps the bar count current while closed (no resident process then), and
    // texts like "Up 5 minutes" current while open
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()

    // --- Live logs ---

    property bool logFollow: true
    property bool logWrap: true
    property string logFilter: ""
    property var logBuffer: []
    readonly property int logMax: 5000

    ListModel {
        id: logModel
    }

    function select(row) {
        var id = row.kind === "project" ? row.data.name : row.data.id;
        if (selected && selected.kind === row.kind && selected.id === id) {
            clearSelection();
            return;
        }
        selected = {
            kind: row.kind,
            id: row.kind === "project" ? row.data.name : row.data.id
        };
        startLogs();
    }

    function clearSelection() {
        logProcess.running = false;
        selected = null;
        logModel.clear();
        logBuffer = [];
        logFilter = "";
    }

    function popoutOpened() {
        unloadTimer.stop();
        contentActive = true;
        popoutOpen = true;
        eventsProcess.running = true;
        refresh();
    }

    // Closing: stop every stream and drop the heavy parts; the content itself is
    // unloaded once the close animation is over
    function popoutClosed() {
        popoutOpen = false;
        eventsProcess.running = false;
        reconnect.stop();
        clearSelection();
        pendingConfirm = "";
        hoverHint = "";
        logHint = "";
        unloadTimer.restart();
    }

    Timer {
        id: unloadTimer
        interval: 600
        onTriggered: root.contentActive = false
    }

    // Row-shaped object for the selection, rebuilt from each snapshot
    readonly property var selectedRow: {
        if (!selected)
            return null;
        if (selected.kind === "container") {
            var c = containerById[selected.id];
            return c ? {
                key: "container:" + c.id,
                kind: "container",
                title: c.service || c.name,
                data: c
            } : null;
        }
        for (var i = 0; i < snapshot.projects.length; i++) {
            var pr = snapshot.projects[i];
            if (pr.name !== selected.id)
                continue;
            var running = pr.containers.filter(function (id) {
                return containerById[id] && containerById[id].state === "running";
            }).length;
            return {
                key: "project:" + pr.name,
                kind: "project",
                title: "Compose: " + pr.name,
                data: pr,
                running: running,
                total: pr.containers.length
            };
        }
        return null;
    }

    function logCommand(row) {
        var tail = String(logTail);
        if (row.kind === "project")
            return composeArgs(row.data).concat(["logs", "-f", "--no-color", "--tail", tail, "--timestamps"]);
        return ["docker", "logs", "-f", "--tail", tail, "--timestamps", row.data.id];
    }

    function startLogs() {
        logProcess.running = false;
        logModel.clear();
        logBuffer = [];
        logFollow = true;
        if (!selectedRow)
            return;
        logProcess.command = logCommand(selectedRow);
        logProcess.running = true;
    }

    // Selected item vanished -> drop it; container came back up -> reattach logs
    onSnapshotChanged: {
        if (!selected)
            return;
        if (!selectedRow) {
            clearSelection();
            return;
        }
        if (popoutOpen && !logProcess.running && selected.kind === "container" && selectedRow.data.state === "running")
            startLogs();
    }

    // "svc-1  | 2026-09-18T10:00:00.123Z msg" or "2026-09-18T10:00:00.123Z msg"
    function parseLogLine(line) {
        line = line.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
        var m = line.match(/^(\S+\s*\|\s)?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d))\s?(.*)$/);
        if (!m)
            return {
                time: "",
                source: "",
                text: line
            };
        var d = new Date(m[2]);
        var time = isNaN(d) ? "" : Qt.formatTime(d, "HH:mm:ss");
        return {
            time: time,
            source: m[1] ? m[1].replace(/\s*\|\s$/, "").trim() : "",
            text: m[3]
        };
    }

    function pushLog(line) {
        var b = logBuffer;
        b.push(line);
        if (!flushTimer.running)
            flushTimer.start();
    }

    Timer {
        id: flushTimer
        interval: 100
        onTriggered: {
            var b = root.logBuffer;
            root.logBuffer = [];
            for (var i = 0; i < b.length; i++) {
                var p = root.parseLogLine(b[i]);
                var lower = p.text.toLowerCase();
                logModel.append({
                    time: p.time,
                    source: p.source,
                    msg: p.text,
                    level: /\b(error|fatal|panic|exception)\b/.test(lower) ? 2 : /\bwarn(ing)?\b/.test(lower) ? 1 : 0
                });
            }
            var extra = logModel.count - root.logMax;
            if (extra > 0)
                logModel.remove(0, extra);
            root.logFlushed();
        }
    }
    signal logFlushed

    Process {
        id: logProcess
        stdout: SplitParser {
            onRead: data => root.pushLog(data)
        }
        stderr: SplitParser {
            onRead: data => root.pushLog(data)
        }
    }

    function copyLogs() {
        var lines = [];
        for (var i = 0; i < logModel.count; i++) {
            var l = logModel.get(i);
            lines.push((l.time ? l.time + " " : "") + (l.source ? l.source + " | " : "") + l.msg);
        }
        Quickshell.clipboardText = lines.join("\n");
    }

    function openLogsInTerminal() {
        if (selectedRow)
            Quickshell.execDetached(terminalArgs().concat(logCommand(selectedRow)));
    }

    // --- Bar pill ---

    readonly property string pillText: {
        if (!available)
            return "!";
        if (pillMode === "icon")
            return "";
        if (pillMode === "ratio")
            return runningCount + "/" + snapshot.containers.length;
        return String(runningCount);
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "deployed_code"
                size: root.iconSize
                color: root.available ? Theme.surfaceText : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: text !== ""
                text: root.pillText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.available ? Theme.surfaceText : Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "deployed_code"
                size: root.iconSize
                color: root.available ? Theme.surfaceText : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: text !== ""
                text: root.pillText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.available ? Theme.surfaceText : Theme.error
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // --- Shared building blocks ---

    component IconButton: Rectangle {
        property string icon: ""
        property bool danger: false
        property bool armed: false
        property string hint: ""
        property string hintProp: "hoverHint"
        signal clicked
        width: 26
        height: 26
        radius: 13
        color: armed ? Theme.error : btnArea.containsMouse ? Theme.withAlpha(danger ? Theme.error : Theme.primary, 0.18) : "transparent"

        DankIcon {
            anchors.centerIn: parent
            name: icon
            size: 16
            color: armed ? Theme.primaryText : danger && btnArea.containsMouse ? Theme.error : Theme.surfaceText
        }

        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
            onContainsMouseChanged: {
                if (containsMouse)
                    root[hintProp] = hint;
                else if (root[hintProp] === hint)
                    root[hintProp] = "";
            }
        }
    }

    // Outlined button with icon + label, used in the detail pane header
    component TextButton: Rectangle {
        property string icon: ""
        property string label: ""
        property bool danger: false
        property bool armed: false
        signal clicked
        width: tbRow.implicitWidth + Theme.spacingM * 2
        height: 30
        radius: 15
        color: armed ? Theme.error : tbArea.containsMouse ? Theme.withAlpha(danger ? Theme.error : Theme.primary, 0.14) : "transparent"
        border.width: 1
        border.color: armed ? Theme.error : Theme.withAlpha(danger ? Theme.error : Theme.surfaceText, 0.25)

        Row {
            id: tbRow
            anchors.centerIn: parent
            spacing: 4

            DankIcon {
                name: icon
                size: 16
                color: armed ? Theme.primaryText : danger ? Theme.error : Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: armed ? root.tr("Click again to confirm") : label
                font.pixelSize: Theme.fontSizeSmall
                color: armed ? Theme.primaryText : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: tbArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    // --- Popout: tree on the left, selected item + live logs on the right ---

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: root.tr("Docker")
            detailsText: {
                if (!root.available)
                    return root.dockerError ? root.tr("Docker is not reachable") + ": " + root.dockerError : "";
                var s = root.snapshot;
                return "v" + s.version + "  ·  " + root.runningCount + " / " + s.containers.length + " " + root.tr("running") + "  ·  " + s.images.length + " " + root.tr("images");
            }
            showCloseButton: true

            Component.onCompleted: root.popoutOpened()
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible)
                        root.popoutOpened();
                    else
                        root.popoutClosed();
                }
            }

            Loader {
                width: parent.width - Theme.spacingM * 2
                height: !root.available ? 120 : root.selectedRow ? 640 : Math.min(640, root.treeContentHeight + 24)
                anchors.horizontalCenter: parent.horizontalCenter
                active: root.contentActive
                sourceComponent: Component {
            Item {

                // ================= Unavailable =================
                StyledText {
                    anchors.centerIn: parent
                    width: parent.width
                    visible: !root.available
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.tr("Docker is not reachable") + (root.dockerError ? "\n" + root.dockerError : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                // ================= Left: tree =================
                Column {
                    id: leftPane
                    width: root.selectedRow ? 330 : parent.width
                    height: parent.height
                    spacing: Theme.spacingXS
                    visible: root.available

                    ListView {
                        id: tree
                        width: parent.width
                        height: parent.height - hintLine.height - parent.spacing
                        clip: true
                        model: root.rows
                        boundsBehavior: Flickable.StopAtBounds
                        onContentHeightChanged: root.treeContentHeight = contentHeight

                        delegate: Item {
                            id: rowItem
                            readonly property var row: modelData
                            readonly property bool isDetail: row.kind === "detail"
                            readonly property bool selectable: row.kind === "container" || row.kind === "project"
                            readonly property bool isSelected: selectable && root.selectedRow !== null && root.selectedRow.key === row.key
                            readonly property var actions: isDetail ? [] : root.actionsFor(row)
                            readonly property bool isBusy: root.busy[row.key] === true
                            readonly property bool armedHere: root.pendingConfirm.indexOf(row.key + "|") === 0
                            width: tree.width
                            height: isDetail ? 24 : row.subtitle ? 42 : 34

                            MouseArea {
                                id: rowArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: rowItem.isDetail ? Qt.ArrowCursor : Qt.PointingHandCursor
                                onClicked: {
                                    if (rowItem.selectable)
                                        root.select(row);
                                    else if (row.expandable)
                                        root.toggle(row.key, false);
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.cornerRadius
                                    color: rowItem.isSelected ? Theme.withAlpha(Theme.primary, 0.16) : rowArea.containsMouse && !rowItem.isDetail ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
                                }

                                Row {
                                    id: lead
                                    x: row.depth * 18 + 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6

                                    // Chevron has its own click target so a project can be
                                    // selected without collapsing it
                                    Item {
                                        width: 16
                                        height: 16
                                        anchors.verticalCenter: parent.verticalCenter

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: "chevron_right"
                                            size: 16
                                            rotation: row.open ? 90 : 0
                                            opacity: row.expandable ? 1 : 0
                                            color: Theme.surfaceVariantText
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            enabled: row.expandable
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggle(row.key, row.kind === "project")
                                        }
                                    }
                                    Rectangle {
                                        visible: row.dot !== undefined
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: row.dot || "transparent"
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    DankIcon {
                                        visible: !!row.icon
                                        name: row.icon || ""
                                        size: 16
                                        color: row.kind === "section" || row.kind === "project" ? Theme.primary : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                Column {
                                    anchors.left: lead.right
                                    anchors.leftMargin: 6
                                    anchors.right: actionRow.visible ? actionRow.left : parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1

                                    StyledText {
                                        width: parent.width
                                        text: row.title
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideMiddle
                                        font.pixelSize: rowItem.isDetail ? 11 : Theme.fontSizeSmall
                                        font.weight: row.kind === "section" || row.kind === "project" ? Font.Medium : Font.Normal
                                        color: rowItem.isDetail ? Theme.surfaceVariantText : Theme.surfaceText
                                    }
                                    StyledText {
                                        width: parent.width
                                        visible: !!row.subtitle && !rowItem.isDetail
                                        text: row.subtitle || ""
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideRight
                                        font.pixelSize: 11
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                // Quick actions on hover (the detail pane has the full set)
                                Row {
                                    id: actionRow
                                    anchors.right: parent.right
                                    anchors.rightMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: rowItem.actions.length > 0 && (rowArea.containsMouse || rowItem.isBusy || rowItem.armedHere)

                                    DankSpinner {
                                        visible: rowItem.isBusy
                                        size: 16
                                        running: rowItem.isBusy
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Repeater {
                                        model: rowItem.isBusy ? [] : rowItem.actions.filter(function (a) {
                                            return a.id !== "logs" && a.id !== "shell";
                                        })
                                        delegate: IconButton {
                                            readonly property string token: rowItem.row.key + "|" + modelData.id
                                            icon: modelData.icon
                                            danger: modelData.danger === true
                                            armed: root.pendingConfirm === token
                                            hint: armed ? modelData.label + " · " + root.tr("Click again to confirm") : modelData.label
                                            onClicked: root.trigger(rowItem.row, modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Fixed-height hint line: what the hovered button does
                    StyledText {
                        id: hintLine
                        width: parent.width
                        height: 16
                        text: {
                            if (root.pendingConfirm !== "" && root.hoverHint === "")
                                return root.tr("Click again to confirm");
                            return root.hoverHint || root.tr("Hover an item for actions");
                        }
                        elide: Text.ElideRight
                        font.pixelSize: 11
                        color: root.pendingConfirm !== "" ? Theme.error : Theme.surfaceVariantText
                    }
                }

                Rectangle {
                    id: divider
                    visible: root.available && !!root.selectedRow
                    x: leftPane.width + Theme.spacingS
                    width: 1
                    height: parent.height
                    color: Theme.withAlpha(Theme.surfaceText, 0.1)
                }

                // ================= Right: selected item + logs =================
                Item {
                    id: rightPane
                    visible: root.available && !!root.selectedRow
                    x: divider.x + divider.width + Theme.spacingM
                    width: parent.width - x
                    height: parent.height

                    readonly property var row: root.selectedRow

                    Column {
                        id: detailHead
                        visible: !!rightPane.row
                        width: parent.width
                        spacing: Theme.spacingS

                        // Title line: state dot, name, short id; close collapses the pane
                        Item {
                            width: parent.width
                            height: 28

                            IconButton {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                icon: "close"
                                hintProp: "logHint"
                                hint: root.tr("Close")
                                onClicked: root.clearSelection()
                            }

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: {
                                    var r = rightPane.row;
                                    if (!r)
                                        return "transparent";
                                    if (r.kind === "container")
                                        return root.stateColor(r.data);
                                    return r.running === r.total ? Theme.success : r.running > 0 ? Theme.warning : Theme.surfaceVariantText;
                                }
                            }
                            StyledText {
                                text: rightPane.row ? rightPane.row.title : ""
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                visible: !!rightPane.row && rightPane.row.kind === "container"
                                text: rightPane.row && rightPane.row.kind === "container" ? rightPane.row.data.id : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.family: Theme.monoFontFamily
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        }

                        // Facts about the selection
                        StyledText {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            font.pixelSize: 11
                            color: Theme.surfaceVariantText
                            text: {
                                var r = rightPane.row;
                                if (!r)
                                    return "";
                                var d = r.data, parts = [];
                                if (r.kind === "container") {
                                    parts.push(d.status);
                                    parts.push(root.tr("Image") + " " + d.image);
                                    var ports = root.formatPorts(d.ports);
                                    if (ports)
                                        parts.push(root.tr("Ports") + " " + ports);
                                    if (d.networks.length)
                                        parts.push(root.tr("Networks") + " " + d.networks.join(", "));
                                    if (d.volumes.length)
                                        parts.push(root.tr("Volumes") + " " + d.volumes.join(", "));
                                } else {
                                    parts.push(r.running + " / " + r.total + " " + root.tr("running"));
                                    if (d.workingDir)
                                        parts.push(root.tr("Project dir") + " " + d.workingDir);
                                    if (d.networks.length)
                                        parts.push(root.tr("Networks") + " " + d.networks.join(", "));
                                }
                                return parts.join("  ·  ");
                            }
                        }

                        // Actions for the selection
                        Flow {
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: rightPane.row && !root.busy[rightPane.row.key] ? root.actionsFor(rightPane.row).filter(function (a) {
                                    return a.id !== "logs";
                                }) : []
                                delegate: TextButton {
                                    readonly property string token: rightPane.row.key + "|" + modelData.id
                                    icon: modelData.icon
                                    label: modelData.id === "shell" ? root.tr("Terminal") : modelData.label
                                    danger: modelData.danger === true
                                    armed: root.pendingConfirm === token
                                    onClicked: root.trigger(rightPane.row, modelData)
                                }
                            }

                            Row {
                                visible: !!rightPane.row && root.busy[rightPane.row.key] === true
                                spacing: Theme.spacingS
                                height: 30

                                DankSpinner {
                                    size: 16
                                    running: parent.visible
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: root.tr("Working...")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        // Log toolbar
                        Item {
                            width: parent.width
                            height: 32

                            DankTextField {
                                anchors.left: parent.left
                                anchors.right: logTools.left
                                anchors.rightMargin: Theme.spacingXS
                                height: 32
                                placeholderText: root.tr("Filter")
                                text: root.logFilter
                                onTextChanged: root.logFilter = text
                            }

                            Row {
                                id: logTools
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter

                                IconButton {
                                    icon: root.logFollow ? "vertical_align_bottom" : "pause"
                                    hintProp: "logHint"
                                    hint: root.logFollow ? root.tr("Follow") : root.tr("Paused")
                                    color: root.logFollow ? Theme.withAlpha(Theme.primary, 0.18) : "transparent"
                                    onClicked: {
                                        root.logFollow = !root.logFollow;
                                        if (root.logFollow)
                                            logView.positionViewAtEnd();
                                    }
                                }
                                IconButton {
                                    icon: "wrap_text"
                                    hintProp: "logHint"
                                    hint: root.tr("Wrap")
                                    color: root.logWrap ? Theme.withAlpha(Theme.primary, 0.18) : "transparent"
                                    onClicked: root.logWrap = !root.logWrap
                                }
                                IconButton {
                                    icon: "content_copy"
                                    hintProp: "logHint"
                                    hint: root.tr("Copy all")
                                    onClicked: root.copyLogs()
                                }
                                IconButton {
                                    icon: "delete_sweep"
                                    hintProp: "logHint"
                                    hint: root.tr("Clear")
                                    onClicked: logModel.clear()
                                }
                                IconButton {
                                    icon: "open_in_new"
                                    hintProp: "logHint"
                                    hint: root.tr("Open in terminal")
                                    onClicked: root.openLogsInTerminal()
                                }
                            }
                        }
                    }

                    Rectangle {
                        visible: !!rightPane.row
                        y: detailHead.height + Theme.spacingS
                        width: parent.width
                        height: parent.height - y - logStatus.height - Theme.spacingXS
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        ListView {
                            id: logView
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            clip: true
                            model: logModel
                            boundsBehavior: Flickable.StopAtBounds

                            // Scrolling up pauses follow; scrolling back to the bottom resumes it
                            onMovementEnded: root.logFollow = atYEnd

                            Connections {
                                target: root
                                function onLogFlushed() {
                                    if (root.logFollow)
                                        logView.positionViewAtEnd();
                                }
                            }

                            delegate: Item {
                                readonly property bool match: root.logFilter === "" || msg.toLowerCase().indexOf(root.logFilter.toLowerCase()) >= 0 || source.toLowerCase().indexOf(root.logFilter.toLowerCase()) >= 0
                                width: logView.width
                                height: match ? lineText.implicitHeight : 0
                                visible: match

                                Text {
                                    id: lineText
                                    width: parent.width
                                    textFormat: Text.StyledText
                                    wrapMode: root.logWrap ? Text.WrapAnywhere : Text.NoWrap
                                    elide: root.logWrap ? Text.ElideNone : Text.ElideRight
                                    font.family: Theme.monoFontFamily
                                    font.pixelSize: 11
                                    color: level === 2 ? Theme.error : level === 1 ? Theme.warning : Theme.surfaceText
                                    text: {
                                        function esc(s) {
                                            return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                                        }
                                        var head = "";
                                        if (root.logTimestamps && time)
                                            head += "<font color='" + Theme.surfaceVariantText + "'>" + time + "</font> ";
                                        if (source)
                                            head += "<font color='" + Theme.primary + "'>" + esc(source) + "</font> ";
                                        return head + esc(msg);
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        id: logStatus
                        visible: !!rightPane.row
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 16
                        elide: Text.ElideRight
                        font.pixelSize: 11
                        color: Theme.surfaceVariantText
                        text: root.logHint || ((logProcess.running ? root.tr("Streaming") : root.tr("Log stream ended")) + "  ·  " + logModel.count + " " + root.tr("lines") + (root.logFollow ? "" : "  ·  " + root.tr("Paused")))
                    }
                }
            }
            }
            }
        }
    }
}
