import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginSettings {
    id: root
    pluginId: "canaryDocker"

    property string lang: (SessionData.locale || Qt.locale().name).split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }

    StyledText {
        width: parent.width
        text: "Docker"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: root.tr("Show Docker containers, compose projects, images, networks and volumes, with actions and live logs.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: root.tr("Bar shows")
        defaultValue: "running"
        options: [
            {
                label: root.tr("Running containers"),
                value: "running"
            },
            {
                label: root.tr("Running / total"),
                value: "ratio"
            },
            {
                label: root.tr("Icon only"),
                value: "icon"
            }
        ]
    }

    ToggleSetting {
        settingKey: "hideStopped"
        label: root.tr("Hide stopped containers")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "confirmDestructive"
        label: root.tr("Confirm destructive actions")
        description: root.tr("Delete, down and prune need a second click.")
        defaultValue: true
    }

    SliderSetting {
        settingKey: "logTail"
        label: root.tr("Log lines on open")
        defaultValue: 500
        minimum: 50
        maximum: 5000
        leftIcon: "article"
    }

    ToggleSetting {
        settingKey: "logTimestamps"
        label: root.tr("Show log timestamps")
        defaultValue: true
    }

    StringSetting {
        settingKey: "terminalCommand"
        label: root.tr("Terminal command")
        description: root.tr("Prefix used to open a shell or logs in a terminal, e.g. kitty, alacritty -e, foot.")
        placeholder: "kitty"
        defaultValue: "kitty"
    }
}
