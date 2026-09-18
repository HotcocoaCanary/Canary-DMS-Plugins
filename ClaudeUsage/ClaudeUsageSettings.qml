import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginSettings {
    id: root
    pluginId: "canaryClaudeUsage"

    property string lang: (SessionData.locale || Qt.locale().name).split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }

    component SectionTitle: StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.primary
    }

    StyledText {
        width: parent.width
        text: root.tr("Claude Code Usage")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: root.tr("Claude Code usage from local transcripts, offline. The /usage limits are fetched on refresh, or on the schedule below.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // --- Sync ---
    SectionTitle {
        text: root.tr("Sync")
    }

    SelectionSetting {
        settingKey: "syncInterval"
        label: root.tr("/usage sync frequency")
        description: root.tr("Manual: only the refresh button hits the network. Failed syncs wait a full interval before retrying.")
        defaultValue: "0"
        options: [
            {
                label: root.tr("Manual only"),
                value: "0"
            },
            {
                label: root.tr("Every 5 min"),
                value: "5"
            },
            {
                label: root.tr("Every 10 min"),
                value: "10"
            },
            {
                label: root.tr("Every 15 min"),
                value: "15"
            },
            {
                label: root.tr("Every 30 min"),
                value: "30"
            },
            {
                label: root.tr("Every 60 min"),
                value: "60"
            }
        ]
    }

    ToggleSetting {
        settingKey: "syncOnOpen"
        label: root.tr("Sync when opening the popout")
        description: root.tr("At most once a minute.")
        defaultValue: false
    }

    // --- Bar ---
    SectionTitle {
        text: root.tr("Bar")
    }

    SelectionSetting {
        settingKey: "pillMetric"
        label: root.tr("Bar shows")
        description: root.tr("Today's tokens are local and always up to date; the percentages are as of the last sync.")
        defaultValue: "five_hour"
        options: [
            {
                label: root.tr("5h window %"),
                value: "five_hour"
            },
            {
                label: root.tr("7-day %"),
                value: "seven_day"
            },
            {
                label: root.tr("Today's tokens"),
                value: "today_tokens"
            }
        ]
    }

    ToggleSetting {
        settingKey: "showPacing"
        label: root.tr("Show pacing")
        description: root.tr("Show whether usage is ahead of or behind the time window")
        defaultValue: true
    }

    // --- Popout ---
    SectionTitle {
        text: root.tr("Popout")
    }

    SelectionSetting {
        settingKey: "defaultTab"
        label: root.tr("Tab on open")
        defaultValue: "last"
        options: [
            {
                label: root.tr("Keep last"),
                value: "last"
            },
            {
                label: root.tr("Usage"),
                value: "0"
            },
            {
                label: root.tr("Stats"),
                value: "1"
            },
            {
                label: root.tr("Models"),
                value: "2"
            }
        ]
    }

    SelectionSetting {
        settingKey: "defaultRange"
        label: root.tr("Range on open")
        defaultValue: "last"
        options: [
            {
                label: root.tr("Keep last"),
                value: "last"
            },
            {
                label: root.tr("All"),
                value: "0"
            },
            {
                label: root.tr("30d"),
                value: "30"
            },
            {
                label: root.tr("7d"),
                value: "7"
            }
        ]
    }

    SelectionSetting {
        settingKey: "weekStart"
        label: root.tr("Week starts on")
        description: root.tr("Affects the heatmap columns and this week's figures.")
        defaultValue: "monday"
        options: [
            {
                label: root.tr("Monday"),
                value: "monday"
            },
            {
                label: root.tr("Sunday"),
                value: "sunday"
            }
        ]
    }

    SelectionSetting {
        settingKey: "heatmapMetric"
        label: root.tr("Heatmap colors by")
        defaultValue: "tokens"
        options: [
            {
                label: "Tokens",
                value: "tokens"
            },
            {
                label: root.tr("Messages"),
                value: "messages"
            }
        ]
    }

    // --- Data ---
    SectionTitle {
        text: root.tr("Data")
    }

    StringSetting {
        settingKey: "claudeConfigDir"
        label: root.tr("Claude config directory")
        description: root.tr("Same as CLAUDE_CONFIG_DIR. Leave empty for ~/.claude. Each directory keeps its own cache.")
        placeholder: "~/.claude"
        defaultValue: ""
    }
}
