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
    property string pillMode: pluginData.pillMode || "peers" // peers | ratio | ip | icon
    property bool hideOffline: pluginData.hideOffline === true
    property bool netcheckOnOpen: pluginData.netcheckOnOpen !== false
    property string adminUrl: (pluginData.adminUrl || "https://login.tailscale.com/admin").replace(/\/+$/, "")

    // --- Snapshot from tailscale-state.py ---
    property var snapshot: ({
            peers: [],
            health: [],
            prefs: {}
        })
    property string tsError: ""
    readonly property bool available: tsError === "" && snapshot.version !== undefined
    readonly property var prefs: snapshot.prefs || ({})
    readonly property var selfNode: snapshot.self || null
    readonly property var peers: snapshot.peers || []
    readonly property string backendState: snapshot.backendState || ""
    readonly property bool running: available && backendState === "Running"
    readonly property bool needsLogin: available && (backendState === "NeedsLogin" || prefs.loggedOut === true)

    readonly property var visiblePeers: hideOffline ? peers.filter(function (p) {
        return p.online;
    }) : peers
    readonly property int onlinePeers: peers.filter(function (p) {
        return p.online;
    }).length
    readonly property int directPeers: peers.filter(function (p) {
        return p.online && p.curAddr;
    }).length
    readonly property int relayedPeers: onlinePeers - directPeers
    readonly property var exitNode: {
        for (var i = 0; i < peers.length; i++)
            if (peers[i].exitNode)
                return peers[i];
        return null;
    }

    // Peers that moved traffic, biggest first, for the traffic chart
    readonly property var trafficPeers: {
        var list = peers.filter(function (p) {
            return (p.rx + p.tx) > 0;
        });
        list.sort(function (a, b) {
            return (b.rx + b.tx) - (a.rx + a.tx);
        });
        return list.slice(0, 5);
    }
    readonly property real trafficMax: {
        var max = 0;
        for (var i = 0; i < trafficPeers.length; i++)
            max = Math.max(max, trafficPeers[i].rx, trafficPeers[i].tx);
        return max;
    }

    readonly property string scriptPath: Qt.resolvedUrl("tailscale-state.py").toString().replace(/^file:\/\//, "")

    popoutWidth: 440

    // --- UI state ---
    property bool popoutOpen: false
    property bool contentActive: false // popout content is unloaded while closed
    property real contentHeight: 0

    // --- Formatting ---

    function formatBytes(n) {
        if (n >= 1e9)
            return (n / 1e9).toFixed(1) + " GB";
        if (n >= 1e6)
            return (n / 1e6).toFixed(1) + " MB";
        if (n >= 1e3)
            return (n / 1e3).toFixed(0) + " KB";
        return n + " B";
    }

    function ago(iso) {
        if (!iso)
            return "";
        var d = new Date(iso);
        if (isNaN(d))
            return "";
        var s = (Date.now() - d.getTime()) / 1000;
        if (s < 90)
            return tr("just now");
        var n, unit;
        if (s < 3600) {
            n = Math.round(s / 60);
            unit = tr("min");
        } else if (s < 86400) {
            n = Math.round(s / 3600);
            unit = tr("hours");
        } else {
            n = Math.round(s / 86400);
            unit = tr("days");
        }
        return tr("%1 ago").replace("%1", lang === "zh" ? n + unit : n + " " + unit);
    }

    function daysUntil(iso) {
        if (!iso)
            return -1;
        var d = new Date(iso);
        if (isNaN(d))
            return -1;
        return Math.round((d.getTime() - Date.now()) / 86400000);
    }

    function stateText(state) {
        switch (state) {
        case "Running":
            return tr("Connected");
        case "Stopped":
            return tr("Disconnected");
        case "NeedsLogin":
            return tr("Needs login");
        case "Starting":
            return tr("Starting");
        case "NoState":
            return tr("Not configured");
        }
        return state;
    }

    function osIcon(os) {
        var s = (os || "").toLowerCase();
        if (s === "ios" || s === "android")
            return "smartphone";
        if (s === "tvos")
            return "tv";
        if (s === "macos")
            return "laptop_mac";
        if (s === "windows")
            return "desktop_windows";
        if (s === "linux")
            return "computer";
        return "devices";
    }

    function deviceColor(d) {
        if (d.expired)
            return Theme.error;
        if (!d.online)
            return Theme.surfaceVariantText;
        if (d.exitNode)
            return Theme.primary;
        return Theme.success;
    }

    function openUrl(url) {
        Quickshell.execDetached(["xdg-open", url]);
    }

    function copyText(text) {
        Quickshell.clipboardText = text;
        ToastService.showInfo(tr("Copied") + ": " + text, "");
    }

    // --- Preferences shown as chips, in a fixed order ---

    readonly property var prefChips: {
        var out = [];
        if (exitNode || prefs.exitNodeIP)
            out.push({
                icon: "vpn_lock",
                label: tr("Exit node") + " " + (exitNode ? exitNode.name : prefs.exitNodeIP),
                on: true
            });
        if (prefs.advertiseExitNode)
            out.push({
                icon: "ios_share",
                label: tr("Offers exit node"),
                on: true
            });
        out.push({
            icon: "alt_route",
            label: tr("Routes"),
            on: prefs.acceptRoutes === true
        });
        out.push({
            icon: "dns",
            label: "DNS",
            on: prefs.acceptDNS === true
        });
        if (prefs.runSSH)
            out.push({
                icon: "terminal",
                label: "SSH",
                on: true
            });
        if (prefs.shieldsUp)
            out.push({
                icon: "shield",
                label: tr("Incoming blocked"),
                on: true
            });
        if ((prefs.advertiseRoutes || []).length)
            out.push({
                icon: "lan",
                label: prefs.advertiseRoutes.join(" "),
                on: true
            });
        var days = selfNode ? daysUntil(selfNode.keyExpiry) : -1;
        if (days >= 0)
            out.push({
                icon: "key",
                label: days + " " + tr("days"),
                on: days > 14,
                warn: days <= 14
            });
        return out;
    }

    // --- State refresh ---

    property bool refreshAgain: false

    function refresh() {
        if (stateProcess.running)
            refreshAgain = true;
        else
            stateProcess.running = true;
    }

    Process {
        id: stateProcess
        command: ["python3", root.scriptPath]
        stdout: StdioCollector {
            onStreamFinished: {
                var out;
                try {
                    out = JSON.parse(text);
                } catch (e) {
                    root.tsError = "bad output";
                    return;
                }
                if (out.error) {
                    root.tsError = out.error;
                    return;
                }
                root.tsError = "";
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

    // Polled: often while the popout is open, once a minute for the bar pill
    Timer {
        interval: root.popoutOpen ? 5000 : 60000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()

    // --- Network check (read-only diagnostics, drives the latency chart) ---

    property var net: null
    property string netError: ""
    property real netAt: 0
    readonly property bool netRunning: netProcess.running

    function runNetcheck() {
        if (netProcess.running)
            return;
        netError = "";
        netProcess.running = true;
    }

    Process {
        id: netProcess
        command: ["python3", root.scriptPath, "netcheck"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out;
                try {
                    out = JSON.parse(text);
                } catch (e) {
                    root.netError = "bad output";
                    return;
                }
                if (out.error) {
                    root.netError = out.error;
                    return;
                }
                root.net = out;
                root.netAt = Date.now();
            }
        }
    }

    readonly property var derpRegions: net && net.regions ? net.regions.slice(0, 6) : []
    readonly property real derpMax: {
        var max = 0;
        for (var i = 0; i < derpRegions.length; i++)
            max = Math.max(max, derpRegions[i].ms);
        return max;
    }

    readonly property var netChips: {
        if (!net)
            return [];
        var c = net.checks;
        var out = [
            {
                icon: "podcasts",
                label: "UDP",
                on: c.udp
            },
            {
                icon: "language",
                label: "IPv4",
                on: c.ipv4
            },
            {
                icon: "language",
                label: "IPv6",
                on: c.ipv6
            },
            {
                icon: "swap_horiz",
                label: tr("Easy NAT"),
                on: c.easyNAT
            },
            {
                icon: "settings_ethernet",
                label: tr("Port mapping"),
                on: c.upnp || c.pmp || c.pcp
            }
        ];
        if (c.captivePortal)
            out.push({
                icon: "wifi_lock",
                label: tr("Captive portal"),
                on: false,
                warn: true
            });
        return out;
    }

    // --- Popout lifecycle ---

    function popoutOpened() {
        unloadTimer.stop();
        contentActive = true;
        popoutOpen = true;
        refresh();
        if (netcheckOnOpen && running && Date.now() - netAt > 60000)
            runNetcheck();
    }

    function popoutClosed() {
        popoutOpen = false;
        unloadTimer.restart();
    }

    Timer {
        id: unloadTimer
        interval: 600
        onTriggered: root.contentActive = false
    }

    // --- Bar pill ---

    readonly property string pillIcon: {
        if (!available || needsLogin)
            return "vpn_key_off";
        if (exitNode || prefs.exitNodeIP)
            return "vpn_lock";
        return running ? "vpn_key" : "vpn_key_off";
    }

    readonly property color pillColor: {
        if (!available)
            return Theme.error;
        if (needsLogin || snapshot.health.length > 0)
            return Theme.warning;
        if (!running)
            return Theme.surfaceVariantText;
        return Theme.surfaceText;
    }

    readonly property string pillText: {
        if (!available)
            return "!";
        if (needsLogin)
            return "?";
        if (pillMode === "icon")
            return "";
        if (pillMode === "ip")
            return selfNode ? selfNode.ip : "";
        if (pillMode === "ratio")
            return onlinePeers + "/" + peers.length;
        return String(onlinePeers);
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: root.pillIcon
                size: root.iconSize
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: text !== ""
                text: root.pillText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: root.pillIcon
                size: root.iconSize
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: text !== "" && root.pillMode !== "ip"
                text: root.pillText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // --- Chart and layout building blocks ---

    // One bar: 4px rounded data end, square at the baseline, on a light track
    component Bar: Item {
        id: bar
        property real fraction: 0
        property color fill: Theme.primary
        property bool track: true
        height: 8

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            visible: bar.track
            color: Theme.withAlpha(bar.fill, 0.12)
        }

        Item {
            id: barFill
            width: Math.max(4, bar.width * Math.max(0, Math.min(1, bar.fraction)))
            height: bar.height

            Rectangle {
                anchors.fill: parent
                radius: 4
                color: bar.fill
            }
            // Squares off the baseline end, the rounding belongs to the data end
            Rectangle {
                width: Math.min(4, barFill.width)
                height: barFill.height
                color: bar.fill
            }
        }
    }

    // Icon + label pill, used for preferences and netcheck results
    component Chip: Rectangle {
        id: chip
        property string icon: ""
        property string label: ""
        property bool active: false
        property bool warn: false
        readonly property color tint: warn ? Theme.warning : active ? Theme.primary : Theme.surfaceVariantText
        width: chipRow.implicitWidth + Theme.spacingS * 2
        height: 22
        radius: 11
        color: Theme.withAlpha(chip.tint, warn || active ? 0.14 : 0.07)

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 3

            DankIcon {
                name: chip.warn ? "warning" : chip.active ? chip.icon : "remove"
                size: 12
                color: chip.tint
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: chip.label
                font.pixelSize: 11
                color: chip.active || chip.warn ? Theme.surfaceText : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    component SectionTitle: Item {
        id: sectionTitle
        property string label: ""
        property string note: ""
        width: parent.width
        height: 20

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: sectionTitle.label
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
        }
        StyledText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: sectionTitle.note
            font.pixelSize: 11
            color: Theme.surfaceVariantText
        }
    }

    // Colored dot + label, the identity channel for the stacked bars
    component LegendKey: Row {
        id: legendKey
        property color swatch: Theme.primary
        property string label: ""
        spacing: 4

        Rectangle {
            width: 8
            height: 8
            radius: 4
            color: legendKey.swatch
            anchors.verticalCenter: parent.verticalCenter
        }
        StyledText {
            text: legendKey.label
            font.pixelSize: 11
            color: Theme.surfaceVariantText
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    component IconButton: Rectangle {
        id: iconButton
        property string icon: ""
        signal clicked
        width: 24
        height: 24
        radius: 12
        color: btnArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.18) : "transparent"

        DankIcon {
            anchors.centerIn: parent
            name: iconButton.icon
            size: Math.round(iconButton.width * 0.6)
            color: Theme.surfaceText
        }

        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: iconButton.clicked()
        }
    }

    // --- Popout ---

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: root.tr("Tailscale")
            detailsText: {
                if (!root.available)
                    return root.tr("tailscaled is not reachable") + (root.tsError ? ": " + root.tsError : "");
                var parts = [root.stateText(root.backendState)];
                if (root.snapshot.tailnet)
                    parts.push(root.snapshot.tailnet);
                return parts.join("  ·  ");
            }
            showCloseButton: true

            headerActions: Component {
                Row {
                    spacing: 2

                    IconButton {
                        icon: "refresh"
                        onClicked: {
                            root.refresh();
                            root.runNetcheck();
                        }
                    }
                    IconButton {
                        icon: "open_in_new"
                        onClicked: root.openUrl(root.adminUrl + "/machines")
                    }
                }
            }

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
                height: root.available ? Math.min(620, root.contentHeight || 360) : 110
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
                            text: root.tr("tailscaled is not reachable") + (root.tsError ? "\n" + root.tsError : "")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankFlickable {
                            id: flick
                            anchors.fill: parent
                            visible: root.available
                            clip: true
                            contentHeight: content.height

                            Column {
                                id: content
                                width: flick.width
                                spacing: Theme.spacingM
                                onHeightChanged: root.contentHeight = height

                                // ============ Health warnings ============
                                Repeater {
                                    model: root.snapshot.health

                                    delegate: Rectangle {
                                        width: content.width
                                        height: warnText.implicitHeight + Theme.spacingS * 2
                                        radius: Theme.cornerRadius
                                        color: Theme.withAlpha(Theme.warning, 0.12)

                                        DankIcon {
                                            id: warnIcon
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.top: parent.top
                                            anchors.topMargin: Theme.spacingS
                                            name: "warning"
                                            size: 14
                                            color: Theme.warning
                                        }
                                        StyledText {
                                            id: warnText
                                            anchors.left: warnIcon.right
                                            anchors.leftMargin: Theme.spacingXS
                                            anchors.right: parent.right
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData
                                            wrapMode: Text.WordWrap
                                            font.pixelSize: 11
                                            color: Theme.surfaceText
                                        }
                                    }
                                }

                                // ============ This device ============
                                Rectangle {
                                    width: content.width
                                    height: 72
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainerHigh

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.selfNode)
                                                root.copyText(root.selfNode.ip);
                                        }
                                    }

                                    Rectangle {
                                        id: stateRing
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 44
                                        height: 44
                                        radius: 22
                                        color: "transparent"
                                        border.width: 3
                                        border.color: root.running ? Theme.success : root.needsLogin ? Theme.warning : Theme.surfaceVariantText

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: root.pillIcon
                                            size: 20
                                            color: parent.border.color
                                        }
                                    }

                                    Column {
                                        anchors.left: stateRing.right
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.right: adminButton.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        StyledText {
                                            width: parent.width
                                            text: root.selfNode ? root.selfNode.ip : root.stateText(root.backendState)
                                            font.pixelSize: Theme.fontSizeLarge + 2
                                            font.weight: Font.DemiBold
                                            isMonospace: true
                                            elide: Text.ElideRight
                                            color: Theme.surfaceText
                                        }
                                        StyledText {
                                            width: parent.width
                                            text: {
                                                if (!root.selfNode)
                                                    return "";
                                                var parts = [root.selfNode.name];
                                                if (root.selfNode.relay)
                                                    parts.push(root.tr("Relay") + " " + root.selfNode.relay);
                                                if (root.snapshot.version)
                                                    parts.push("v" + root.snapshot.version);
                                                return parts.join("  ·  ");
                                            }
                                            elide: Text.ElideRight
                                            font.pixelSize: 11
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    IconButton {
                                        id: adminButton
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 32
                                        height: 32
                                        radius: 16
                                        icon: "open_in_new"
                                        onClicked: root.openUrl(root.adminUrl + "/machines")
                                    }
                                }

                                // ============ Preference chips ============
                                Flow {
                                    width: content.width
                                    spacing: Theme.spacingXS

                                    Repeater {
                                        model: root.prefChips
                                        delegate: Chip {
                                            icon: modelData.icon
                                            label: modelData.label
                                            active: modelData.on
                                            warn: modelData.warn === true
                                        }
                                    }

                                    Chip {
                                        visible: root.needsLogin
                                        icon: "login"
                                        label: root.tr("Needs login")
                                        warn: true

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: root.snapshot.authURL !== ""
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.openUrl(root.snapshot.authURL)
                                        }
                                    }

                                    Chip {
                                        visible: !!(root.snapshot.clientVersion && root.snapshot.clientVersion.latest && !root.snapshot.clientVersion.runningLatest)
                                        icon: "system_update_alt"
                                        label: root.tr("Update") + " " + (root.snapshot.clientVersion ? root.snapshot.clientVersion.latest : "")
                                        warn: true
                                    }
                                }

                                // ============ Devices ============
                                Column {
                                    width: content.width
                                    spacing: Theme.spacingXS

                                    SectionTitle {
                                        label: root.tr("Devices")
                                        note: root.onlinePeers + " / " + root.peers.length + " " + root.tr("online")
                                    }

                                    // Stacked bar: direct / relayed / offline
                                    Row {
                                        width: parent.width
                                        height: 10
                                        spacing: 2
                                        visible: root.peers.length > 0

                                        Rectangle {
                                            width: Math.max(0, (parent.width - 4) * root.directPeers / Math.max(1, root.peers.length))
                                            height: parent.height
                                            radius: 5
                                            visible: width > 0
                                            color: Theme.success
                                        }
                                        Rectangle {
                                            width: Math.max(0, (parent.width - 4) * root.relayedPeers / Math.max(1, root.peers.length))
                                            height: parent.height
                                            radius: 5
                                            visible: width > 0
                                            color: Theme.primary
                                        }
                                        Rectangle {
                                            width: Math.max(0, (parent.width - 4) * (root.peers.length - root.onlinePeers) / Math.max(1, root.peers.length))
                                            height: parent.height
                                            radius: 5
                                            visible: width > 0
                                            color: Theme.withAlpha(Theme.surfaceText, 0.15)
                                        }
                                    }

                                    Row {
                                        spacing: Theme.spacingM
                                        visible: root.peers.length > 0

                                        LegendKey {
                                            swatch: Theme.success
                                            label: root.tr("direct") + " " + root.directPeers
                                        }
                                        LegendKey {
                                            swatch: Theme.primary
                                            label: root.tr("relay") + " " + root.relayedPeers
                                        }
                                        LegendKey {
                                            swatch: Theme.withAlpha(Theme.surfaceText, 0.15)
                                            label: root.tr("offline") + " " + (root.peers.length - root.onlinePeers)
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: root.visiblePeers.length === 0
                                        text: root.peers.length ? root.tr("No devices online") : root.tr("No other devices")
                                        font.pixelSize: 11
                                        color: Theme.surfaceVariantText
                                    }

                                    Repeater {
                                        model: root.visiblePeers

                                        delegate: Item {
                                            id: peerRow
                                            readonly property var d: modelData
                                            width: parent.width
                                            height: 32

                                            Rectangle {
                                                anchors.fill: parent
                                                radius: Theme.cornerRadius
                                                color: peerArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
                                            }

                                            MouseArea {
                                                id: peerArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.copyText(peerRow.d.ip)
                                            }

                                            Row {
                                                id: peerLead
                                                anchors.left: parent.left
                                                anchors.leftMargin: Theme.spacingXS
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 6

                                                Rectangle {
                                                    width: 8
                                                    height: 8
                                                    radius: 4
                                                    color: root.deviceColor(peerRow.d)
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                DankIcon {
                                                    name: root.osIcon(peerRow.d.os)
                                                    size: 15
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }

                                            Row {
                                                anchors.left: peerLead.right
                                                anchors.leftMargin: 6
                                                anchors.right: peerTrail.left
                                                anchors.rightMargin: 6
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 6

                                                StyledText {
                                                    text: peerRow.d.name
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    elide: Text.ElideRight
                                                    color: Theme.surfaceText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                StyledText {
                                                    text: peerRow.d.ip
                                                    font.pixelSize: 11
                                                    isMonospace: true
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }

                                            Row {
                                                id: peerTrail
                                                anchors.right: parent.right
                                                anchors.rightMargin: Theme.spacingXS
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2

                                                Chip {
                                                    visible: !peerArea.containsMouse
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    icon: peerRow.d.exitNode ? "vpn_lock" : peerRow.d.curAddr ? "bolt" : "cell_tower"
                                                    active: peerRow.d.online
                                                    label: {
                                                        var d = peerRow.d;
                                                        if (!d.online)
                                                            return d.lastSeen ? root.ago(d.lastSeen) : root.tr("offline");
                                                        if (d.curAddr)
                                                            return root.tr("direct");
                                                        return d.relay ? d.relay : root.tr("relay");
                                                    }
                                                }

                                                IconButton {
                                                    visible: peerArea.containsMouse
                                                    icon: "content_copy"
                                                    onClicked: root.copyText(peerRow.d.ip)
                                                }
                                                IconButton {
                                                    visible: peerArea.containsMouse
                                                    icon: "open_in_new"
                                                    onClicked: root.openUrl(root.adminUrl + "/machines/" + peerRow.d.ip)
                                                }
                                            }
                                        }
                                    }
                                }

                                // ============ Traffic ============
                                Column {
                                    width: content.width
                                    spacing: Theme.spacingXS
                                    visible: root.trafficPeers.length > 0

                                    SectionTitle {
                                        label: root.tr("Traffic")
                                    }

                                    Row {
                                        spacing: Theme.spacingM

                                        LegendKey {
                                            swatch: Theme.primary
                                            label: root.tr("received")
                                        }
                                        LegendKey {
                                            swatch: Theme.tertiary
                                            label: root.tr("sent")
                                        }
                                    }

                                    Repeater {
                                        model: root.trafficPeers

                                        delegate: Item {
                                            id: trafficRow
                                            readonly property var d: modelData
                                            width: parent.width
                                            height: 30

                                            StyledText {
                                                id: trafficName
                                                anchors.left: parent.left
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 90
                                                text: trafficRow.d.name
                                                elide: Text.ElideRight
                                                font.pixelSize: 11
                                                color: Theme.surfaceVariantText
                                            }

                                            Column {
                                                anchors.left: trafficName.right
                                                anchors.leftMargin: Theme.spacingS
                                                anchors.right: trafficValue.left
                                                anchors.rightMargin: Theme.spacingS
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2

                                                Bar {
                                                    width: parent.width
                                                    height: 6
                                                    track: false
                                                    fill: Theme.primary
                                                    fraction: root.trafficMax > 0 ? trafficRow.d.rx / root.trafficMax : 0
                                                }
                                                Bar {
                                                    width: parent.width
                                                    height: 6
                                                    track: false
                                                    fill: Theme.tertiary
                                                    fraction: root.trafficMax > 0 ? trafficRow.d.tx / root.trafficMax : 0
                                                }
                                            }

                                            StyledText {
                                                id: trafficValue
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 68
                                                horizontalAlignment: Text.AlignRight
                                                text: root.formatBytes(trafficRow.d.rx + trafficRow.d.tx)
                                                font.pixelSize: 11
                                                isMonospace: true
                                                color: Theme.surfaceText
                                            }
                                        }
                                    }
                                }

                                // ============ DERP latency ============
                                Column {
                                    width: content.width
                                    spacing: Theme.spacingXS

                                    SectionTitle {
                                        label: root.tr("Relay latency")
                                        note: root.net && root.netAt > 0 ? root.ago(new Date(root.netAt).toISOString()) : ""
                                    }

                                    Row {
                                        spacing: Theme.spacingS
                                        visible: root.netRunning

                                        DankSpinner {
                                            size: 14
                                            running: root.netRunning
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        StyledText {
                                            text: root.tr("Checking the network...")
                                            font.pixelSize: 11
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: !root.netRunning && root.derpRegions.length === 0
                                        text: root.netError ? root.netError : root.tr("Not checked yet")
                                        wrapMode: Text.WordWrap
                                        font.pixelSize: 11
                                        color: root.netError ? Theme.error : Theme.surfaceVariantText
                                    }

                                    Repeater {
                                        model: root.derpRegions

                                        delegate: Item {
                                            id: derpRow
                                            readonly property var region: modelData
                                            width: parent.width
                                            height: 22

                                            StyledText {
                                                id: regionName
                                                anchors.left: parent.left
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 104
                                                text: derpRow.region.name
                                                elide: Text.ElideRight
                                                font.pixelSize: 11
                                                font.weight: derpRow.region.preferred ? Font.Medium : Font.Normal
                                                color: derpRow.region.preferred ? Theme.surfaceText : Theme.surfaceVariantText
                                            }

                                            Bar {
                                                anchors.left: regionName.right
                                                anchors.leftMargin: Theme.spacingS
                                                anchors.right: regionValue.left
                                                anchors.rightMargin: Theme.spacingS
                                                anchors.verticalCenter: parent.verticalCenter
                                                fill: derpRow.region.preferred ? Theme.primary : Theme.withAlpha(Theme.primary, 0.45)
                                                fraction: root.derpMax > 0 ? derpRow.region.ms / root.derpMax : 0
                                            }

                                            StyledText {
                                                id: regionValue
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 56
                                                horizontalAlignment: Text.AlignRight
                                                text: Math.round(derpRow.region.ms) + " ms"
                                                font.pixelSize: 11
                                                isMonospace: true
                                                color: derpRow.region.preferred ? Theme.surfaceText : Theme.surfaceVariantText
                                            }
                                        }
                                    }

                                    Flow {
                                        width: parent.width
                                        spacing: Theme.spacingXS
                                        visible: root.netChips.length > 0

                                        Repeater {
                                            model: root.netChips
                                            delegate: Chip {
                                                icon: modelData.icon
                                                label: modelData.label
                                                active: modelData.on
                                                warn: modelData.warn === true
                                            }
                                        }
                                    }
                                }

                                Item {
                                    width: 1
                                    height: Theme.spacingXS
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
