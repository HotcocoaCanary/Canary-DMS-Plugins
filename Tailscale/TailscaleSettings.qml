import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginSettings {
    id: root
    pluginId: "canaryTailscale"

    property string lang: (SessionData.locale || Qt.locale().name).split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }

    StyledText {
        width: parent.width
        text: "Tailscale"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: root.tr("Read-only Tailscale status: this device, the devices in the tailnet, traffic and the relay latencies.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: root.tr("Bar shows")
        defaultValue: "peers"
        options: [
            {
                label: root.tr("Peers online"),
                value: "peers"
            },
            {
                label: root.tr("Online / total"),
                value: "ratio"
            },
            {
                label: root.tr("This device's IP"),
                value: "ip"
            },
            {
                label: root.tr("Icon only"),
                value: "icon"
            }
        ]
    }

    ToggleSetting {
        settingKey: "hideOffline"
        label: root.tr("Hide offline devices")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "netcheckOnOpen"
        label: root.tr("Check the network when the popout opens")
        description: root.tr("Runs tailscale netcheck for the relay latency chart, at most once a minute.")
        defaultValue: true
    }

    StringSetting {
        settingKey: "adminUrl"
        label: root.tr("Admin console URL")
        description: root.tr("Base URL of the admin console, without /machines. Change it for a self-hosted control server.")
        placeholder: "https://login.tailscale.com/admin"
        defaultValue: "https://login.tailscale.com/admin"
    }
}
