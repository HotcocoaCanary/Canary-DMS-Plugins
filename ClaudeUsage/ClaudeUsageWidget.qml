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

    // i18n: zh or en
    property string lang: (SessionData.locale || Qt.locale().name).split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }
    // Weekday labels in display order (depends on the week start setting)
    readonly property var dayLabels: {
        var labels = lang === "zh" ? ["一", "二", "三", "四", "五", "六", "日"] : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];
        return weekStartsSunday ? [labels[6]].concat(labels.slice(0, 6)) : labels;
    }

    // Settings
    property bool showPacing: pluginData.showPacing !== false
    // /usage request frequency in minutes; 0 = manual only (refresh button)
    property int syncInterval: parseInt(pluginData.syncInterval || "0") || 0
    readonly property bool autoSync: syncInterval > 0
    property bool syncOnOpen: pluginData.syncOnOpen === true
    property string pillMetric: pluginData.pillMetric || "five_hour" // five_hour | seven_day | today_tokens
    property string defaultTab: pluginData.defaultTab || "last" // last | 0 | 1 | 2
    property string defaultRange: pluginData.defaultRange || "last" // last | 0 | 30 | 7
    property bool weekStartsSunday: pluginData.weekStart === "sunday"
    property string heatmapMetric: pluginData.heatmapMetric || "tokens" // tokens | messages
    property string claudeConfigDir: pluginData.claudeConfigDir || ""

    // UI state, kept across popout open/close
    property int activeTab: 0 // 0 usage, 1 stats, 2 models
    property int statsRange: 0 // days; 0 = all time
    property int hoveredDay: -1
    property var hoveredCell: null
    property int hoveredHour: -1
    property int hoveredSeries: -1
    property int hoveredModel: -1

    // --- Remote state: last /usage sync, only changes on refresh ---
    property string subscriptionType: ""
    property string rateLimitTier: ""
    property var usageData: null
    property real syncedAt: 0
    property real lastSyncAttempt: 0
    property string syncError: ""
    readonly property bool hasSynced: syncedAt > 0

    readonly property var fiveHour: usageData && usageData.five_hour || {}
    readonly property var sevenDay: usageData && usageData.seven_day || {}
    readonly property real fiveHourUtil: fiveHour.utilization || 0
    readonly property string fiveHourReset: fiveHour.resets_at || ""
    readonly property real sevenDayUtil: sevenDay.utilization || 0
    readonly property string sevenDayReset: sevenDay.resets_at || ""

    // --- Local state: from the offline transcript scan ---
    // days: { "YYYY-MM-DD": { tokens, messages, sessions, hours:[24],
    //         models: { id: { input, output, cacheRead, cacheWrite, messages } } } }
    // sessions: [{ start, end, messages, tokens }] (epoch ms)
    property var days: ({})
    property var sessions: []

    // Live clock, drives countdowns, pacing and day rollover
    property real countdownNow: Date.now()

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            root.countdownNow = Date.now();
            root.maybeAutoSync();
        }
    }

    readonly property string scriptPath: Qt.resolvedUrl("claude-usage.py").toString().replace(/^file:\/\//, "")

    popoutWidth: 440

    // --- Date helpers (local calendar, weeks start on Monday) ---

    function dayKey(d) {
        var m = d.getMonth() + 1, day = d.getDate();
        return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
    }

    function parseKey(k) {
        var p = k.split("-");
        return new Date(+p[0], +p[1] - 1, +p[2]);
    }

    function startOfWeek(d) {
        var r = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        r.setDate(r.getDate() - (r.getDay() + (weekStartsSunday ? 0 : 6)) % 7);
        return r;
    }

    function addDays(d, n) {
        var r = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        r.setDate(r.getDate() + n);
        return r;
    }

    readonly property var today: {
        void (countdownNow);
        return new Date();
    }
    readonly property string todayKey: dayKey(today)
    readonly property int todayIndex: (today.getDay() + (weekStartsSunday ? 0 : 6)) % 7
    readonly property string firstDayKey: {
        var keys = Object.keys(days).sort();
        return keys.length ? keys[0] : todayKey;
    }

    // --- Current calendar week / month / today ---

    readonly property var weekStats: {
        var start = startOfWeek(today);
        var daily = [], tokens = 0, messages = 0, sessionCount = 0;
        for (var i = 0; i < 7; i++) {
            var d = days[dayKey(addDays(start, i))];
            daily.push(d ? d.tokens : 0);
            if (d) {
                tokens += d.tokens;
                messages += d.messages;
                sessionCount += d.sessions;
            }
        }
        return {
            daily: daily,
            tokens: tokens,
            messages: messages,
            sessions: sessionCount
        };
    }

    readonly property var monthStats: {
        var prefix = todayKey.substring(0, 8);
        var tokens = 0, messages = 0;
        for (var k in days) {
            if (k.indexOf(prefix) === 0) {
                tokens += days[k].tokens;
                messages += days[k].messages;
            }
        }
        return {
            tokens: tokens,
            messages: messages
        };
    }

    readonly property var todayStats: days[todayKey] || {
        tokens: 0,
        messages: 0
    }
    readonly property real maxDaily: Math.max.apply(null, weekStats.daily) || 1

    // --- /stats equivalent over the selected range ---

    readonly property var rangeStats: {
        var startKey = statsRange > 0 ? dayKey(addDays(today, -(statsRange - 1))) : firstDayKey;
        if (startKey > todayKey)
            startKey = todayKey;
        var totalDays = Math.round((parseKey(todayKey) - parseKey(startKey)) / 86400000) + 1;

        var tokens = 0, messages = 0, activeDays = 0;
        var hours = [];
        for (var h = 0; h < 24; h++)
            hours.push(0);
        var models = {}, series = [], busiest = null;
        var run = 0, longestRun = 0;

        for (var i = 0; i < totalDays; i++) {
            var key = dayKey(addDays(parseKey(startKey), i));
            var d = days[key];
            var perModel = {};
            if (d && d.tokens > 0) {
                activeDays++;
                tokens += d.tokens;
                messages += d.messages;
                for (var hh = 0; hh < 24; hh++)
                    hours[hh] += d.hours ? d.hours[hh] : 0;
                for (var m in d.models) {
                    var src = d.models[m];
                    var agg = models[m] || (models[m] = {
                            id: m,
                            input: 0,
                            output: 0,
                            cacheRead: 0,
                            cacheWrite: 0,
                            messages: 0,
                            total: 0
                        });
                    var t = src.input + src.output + src.cacheRead + src.cacheWrite;
                    agg.input += src.input;
                    agg.output += src.output;
                    agg.cacheRead += src.cacheRead;
                    agg.cacheWrite += src.cacheWrite;
                    agg.messages += src.messages;
                    agg.total += t;
                    perModel[m] = t;
                }
                if (!busiest || d.tokens > busiest.tokens)
                    busiest = {
                        key: key,
                        tokens: d.tokens
                    };
                run++;
                longestRun = Math.max(longestRun, run);
            } else {
                run = 0;
            }
            series.push({
                key: key,
                total: d ? d.tokens : 0,
                perModel: perModel
            });
        }

        // Current streak: today counts if active, otherwise it ends yesterday
        var current = 0;
        var cursor = days[todayKey] && days[todayKey].tokens > 0 ? today : addDays(today, -1);
        while (dayKey(cursor) >= startKey && days[dayKey(cursor)] && days[dayKey(cursor)].tokens > 0) {
            current++;
            cursor = addDays(cursor, -1);
        }

        var sessionCount = 0, longest = null;
        for (var s = 0; s < sessions.length; s++) {
            var sess = sessions[s];
            if (dayKey(new Date(sess.start)) < startKey)
                continue;
            sessionCount++;
            if (!longest || sess.end - sess.start > longest.end - longest.start)
                longest = sess;
        }

        var peak = -1;
        for (var ph = 0; ph < 24; ph++)
            if (hours[ph] > 0 && (peak < 0 || hours[ph] > hours[peak]))
                peak = ph;

        var modelList = Object.keys(models).map(function (k) {
            return models[k];
        }).sort(function (a, b) {
            return b.total - a.total;
        });

        return {
            startKey: startKey,
            totalDays: totalDays,
            tokens: tokens,
            messages: messages,
            activeDays: activeDays,
            hours: hours,
            peakHour: peak,
            busiest: busiest,
            currentStreak: current,
            longestStreak: longestRun,
            sessions: sessionCount,
            longestSession: longest,
            models: modelList,
            series: series
        };
    }

    // Chart colors, assigned by usage rank in the selected range
    readonly property var modelPalette: [Theme.primary, Theme.info, Theme.warning, Theme.tertiary, Theme.error, Theme.secondary]
    // --- Heatmap (GitHub-style, columns are Monday-first weeks) ---

    readonly property int heatCell: 11
    readonly property int heatGap: 3
    property real heatAvailWidth: 360
    readonly property int heatWeeks: Math.max(8, Math.min(53, Math.floor((heatAvailWidth + heatGap) / (heatCell + heatGap))))

    readonly property var heatmap: {
        var first = addDays(startOfWeek(today), -7 * (heatWeeks - 1));
        var cells = [], values = [];
        for (var i = 0; i < heatWeeks * 7; i++) {
            var key = dayKey(addDays(first, i));
            var future = key > todayKey;
            var d = days[key];
            var v = d && !future ? (heatmapMetric === "messages" ? d.messages : d.tokens) : 0;
            if (v > 0)
                values.push(v);
            cells.push({
                key: key,
                dow: i % 7,
                value: v,
                tokens: d && !future ? d.tokens : 0,
                messages: d && !future ? d.messages : 0,
                future: future,
                level: 0
            });
        }

        // Quartile thresholds over the non-empty days in range (same as /stats)
        values.sort(function (a, b) {
            return a - b;
        });
        function q(p) {
            return values.length ? values[Math.min(values.length - 1, Math.floor(p * values.length))] : 0;
        }
        var t1 = q(0.25), t2 = q(0.5), t3 = q(0.75);
        var total = 0;
        for (var j = 0; j < cells.length; j++) {
            var c = cells[j];
            total += c.value;
            if (c.value > 0)
                c.level = c.value >= t3 ? 4 : c.value >= t2 ? 3 : c.value >= t1 ? 2 : 1;
        }

        // Month label at the first column containing the 1st of a month
        var months = [];
        for (var w = 0; w < heatWeeks; w++) {
            for (var dd = 0; dd < 7; dd++) {
                var cd = addDays(first, w * 7 + dd);
                if (cd.getDate() === 1 || (w === 0 && dd === 0)) {
                    months.push({
                        week: w,
                        label: lang === "zh" ? (cd.getMonth() + 1) + "月" : Qt.locale("en_US").monthName(cd.getMonth(), Locale.ShortFormat)
                    });
                    break;
                }
            }
        }
        // Drop the leading partial-month label if the next one would collide
        if (months.length > 1 && months[1].week - months[0].week < 3)
            months.shift();

        return {
            cells: cells,
            months: months,
            total: total,
            activeDays: values.length
        };
    }

    function heatColor(level) {
        if (level <= 0)
            return Theme.surfaceVariant;
        return Theme.withAlpha(Theme.primary, [0, 0.3, 0.5, 0.75, 1.0][level]);
    }

    // --- /usage details ---

    function limitLabel(l) {
        if (l.kind === "session")
            return tr("Current session");
        if (l.kind === "weekly_all")
            return tr("Current week (all models)");
        var scope = l.scope || {};
        var name = scope.model && scope.model.display_name || scope.surface && (scope.surface.display_name || scope.surface) || "";
        if (l.group === "weekly")
            return tr("Current week") + (name ? " (" + name + ")" : "");
        return (l.kind || l.group || "?").replace(/_/g, " ") + (name ? " (" + name + ")" : "");
    }

    function severityColor(severity, pct) {
        if (severity === "critical" || severity === "exceeded" || severity === "error")
            return Theme.error;
        if (severity === "warning")
            return Theme.warning;
        return progressColor(pct);
    }

    // Every limit the API reports; falls back to the legacy per-window fields
    readonly property var limits: {
        if (!usageData)
            return [];
        if (usageData.limits && usageData.limits.length)
            return usageData.limits;
        var out = [];
        var legacy = [["five_hour", "session", "session", null], ["seven_day", "weekly_all", "weekly", null], ["seven_day_opus", "weekly_scoped", "weekly", "Opus"], ["seven_day_sonnet", "weekly_scoped", "weekly", "Sonnet"]];
        for (var i = 0; i < legacy.length; i++) {
            var w = usageData[legacy[i][0]];
            if (w)
                out.push({
                    kind: legacy[i][1],
                    group: legacy[i][2],
                    percent: w.utilization || 0,
                    resets_at: w.resets_at,
                    severity: "normal",
                    scope: legacy[i][3] ? {
                        model: {
                            display_name: legacy[i][3]
                        }
                    } : null,
                    is_active: false
                });
        }
        return out;
    }

    readonly property var spend: usageData && usageData.spend || null
    readonly property var extraUsage: usageData && usageData.extra_usage || null

    function formatMoney(m) {
        if (!m)
            return "";
        var exp = m.exponent !== undefined ? m.exponent : 2;
        var v = (m.amount_minor || 0) / Math.pow(10, exp);
        var cur = m.currency || "USD";
        var sym = cur === "USD" ? "$" : cur === "EUR" ? "€" : cur === "GBP" ? "£" : "";
        return sym ? sym + v.toFixed(exp) : v.toFixed(exp) + " " + cur;
    }

    // --- Countdown / pacing ---

    function countdown(resetIso) {
        if (!resetIso)
            return "";
        var remaining = new Date(resetIso).getTime() - countdownNow;
        if (isNaN(remaining))
            return "";
        if (remaining <= 0)
            return tr("Resetting...");
        var d = Math.floor(remaining / 86400000);
        var hours = Math.floor((remaining % 86400000) / 3600000);
        var mins = Math.floor((remaining % 3600000) / 60000);
        var hm = hours + "h " + (mins < 10 ? "0" : "") + mins + "m";
        return d > 0 ? d + "d " + hm : hm;
    }

    // "今天 19:30" / "明天 09:00" / "9月25日 17:00"
    function formatResetAt(resetIso) {
        var d = new Date(resetIso);
        var hm = (d.getHours() < 10 ? "0" : "") + d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes();
        var key = dayKey(d);
        if (key === todayKey)
            return tr("today") + " " + hm;
        if (key === dayKey(addDays(today, 1)))
            return tr("tomorrow") + " " + hm;
        var date = lang === "zh" ? (d.getMonth() + 1) + "月" + d.getDate() + "日" : Qt.locale("en_US").monthName(d.getMonth(), Locale.ShortFormat) + " " + d.getDate();
        return date + " " + hm;
    }

    // Absolute reset time plus the remaining time, e.g. "今天 19:30 重置（1h 23m 后）"
    function resetText(resetIso) {
        var left = countdown(resetIso);
        if (!left)
            return "";
        if (new Date(resetIso).getTime() <= countdownNow)
            return left;
        return tr("Resets at %1 (in %2)").replace("%1", formatResetAt(resetIso)).replace("%2", left);
    }

    property string fiveHourCountdown: resetText(fiveHourReset)
    property string sevenDayCountdown: resetText(sevenDayReset)

    property var fiveHourPace: paceInfo(fiveHourUtil, fiveHourReset, 18000000)
    property var sevenDayPace: paceInfo(sevenDayUtil, sevenDayReset, 604800000)
    readonly property var pillPace: pillMetric === "seven_day" ? sevenDayPace : fiveHourPace
    readonly property bool pillOverPace: showPacing && pillMetric !== "today_tokens" && (pillPace.status === "over" || pillPace.status === "over_quota")

    // Returns { timeFrac, delta, status }; status: over_quota | over | under | on | unknown
    function paceInfo(util, resetIso, windowMs) {
        void (countdownNow);
        util = util || 0;
        if (!resetIso)
            return util >= 100 ? {
                timeFrac: 1,
                delta: util,
                status: "over_quota"
            } : {
                timeFrac: 0,
                delta: 0,
                status: "unknown"
            };
        var resetMs = new Date(resetIso).getTime();
        if (isNaN(resetMs))
            return {
                timeFrac: 0,
                delta: 0,
                status: "unknown"
            };
        var timeFrac = Math.min(1, Math.max(0, (windowMs - (resetMs - countdownNow)) / windowMs));
        var delta = util - timeFrac * 100;
        var status = util >= 100 ? "over_quota" : delta >= 5 ? "over" : delta <= -5 ? "under" : "on";
        return {
            timeFrac: timeFrac,
            delta: delta,
            status: status
        };
    }

    function paceLabel(p) {
        if (!p)
            return "";
        if (p.status === "over_quota")
            return tr("Over quota");
        if (p.status === "over")
            return Math.round(p.delta) + "% " + tr("over pace");
        if (p.status === "under")
            return Math.round(-p.delta) + "% " + tr("under pace");
        if (p.status === "on")
            return tr("On pace");
        return "";
    }

    function paceColor(status) {
        if (status === "over_quota")
            return Theme.error;
        if (status === "over")
            return Theme.warning;
        return Theme.surfaceVariantText;
    }

    // Short radial mark at the linear-burn position on a ring canvas
    function drawPaceTick(ctx, cx, cy, r, lw, pace) {
        if (!showPacing || !pace || pace.status === "unknown")
            return;
        var a = -Math.PI / 2 + 2 * Math.PI * pace.timeFrac;
        var ri = r - lw / 2 - 1, ro = r + lw / 2 + 1;
        ctx.beginPath();
        ctx.moveTo(cx + ri * Math.cos(a), cy + ri * Math.sin(a));
        ctx.lineTo(cx + ro * Math.cos(a), cy + ro * Math.sin(a));
        ctx.lineWidth = 2;
        ctx.lineCap = "butt";
        ctx.strokeStyle = Theme.surfaceText;
        ctx.stroke();
    }

    function drawRing(ctx, cx, cy, r, lw, percent) {
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, 2 * Math.PI);
        ctx.lineWidth = lw;
        ctx.strokeStyle = Theme.surfaceVariant;
        ctx.stroke();
        var pct = percent / 100;
        if (pct > 0) {
            ctx.beginPath();
            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.min(pct, 1));
            ctx.lineWidth = lw;
            ctx.strokeStyle = progressColor(percent);
            ctx.lineCap = "round";
            ctx.stroke();
        }
    }

    // --- Formatting ---

    function formatTokens(n) {
        if (n >= 1000000000)
            return (n / 1000000000).toFixed(1) + "B";
        if (n >= 1000000)
            return (n / 1000000).toFixed(1) + "M";
        if (n >= 1000)
            return (n / 1000).toFixed(1) + "K";
        return Math.round(n).toString();
    }

    function formatDuration(ms) {
        var mins = Math.floor(ms / 60000);
        var d = Math.floor(mins / 1440), h = Math.floor(mins % 1440 / 60), m = mins % 60;
        if (d > 0)
            return d + "d " + h + "h " + m + "m";
        if (h > 0)
            return h + "h " + m + "m";
        return m + "m";
    }

    // claude-opus-4-8 -> Opus 4.8, claude-sonnet-4-5-20250929 -> Sonnet 4.5, claude-3-5-sonnet -> Sonnet 3.5
    function modelName(id) {
        if (!id || id.indexOf("claude-") !== 0)
            return id;
        var parts = id.substring(7).split("-").filter(function (p) {
            return !/^\d{8}$/.test(p);
        });
        var family = "", nums = [];
        for (var i = 0; i < parts.length; i++) {
            if (/^\d+$/.test(parts[i]))
                nums.push(parts[i]);
            else if (!family)
                family = parts[i].charAt(0).toUpperCase() + parts[i].slice(1);
        }
        return (family + " " + nums.join(".")).trim();
    }

    function progressColor(pct) {
        if (pct > 80)
            return Theme.error;
        if (pct > 50)
            return Theme.warning;
        return Theme.primary;
    }

    function formatTier(tier) {
        if (!tier || tier === "unknown")
            return "";
        if (tier.indexOf("max_20x") >= 0)
            return tr("Max") + " 20x";
        if (tier.indexOf("max_5x") >= 0)
            return tr("Max") + " 5x";
        if (tier.indexOf("max") >= 0)
            return tr("Max");
        if (tier.indexOf("pro") >= 0)
            return tr("Pro");
        if (tier.indexOf("free") >= 0)
            return tr("Free");
        if (tier.indexOf("team") >= 0)
            return tr("Team");
        if (tier.indexOf("enterprise") >= 0)
            return tr("Enterprise");
        return tier.replace(/_/g, " ").replace(/\b\w/g, function (c) {
            return c.toUpperCase();
        });
    }

    function formatSubscription(subType, tier) {
        var tierLabel = formatTier(tier);
        if (!subType || subType === "unknown")
            return tierLabel;
        var subLabel = subType.replace(/^claude[_-]?/i, "").replace(/_/g, " ").replace(/\b\w/g, function (c) {
            return c.toUpperCase();
        });
        if (tierLabel.indexOf(subLabel) === 0)
            return tierLabel;
        if (tierLabel)
            return subLabel + " · " + tierLabel;
        return subLabel || tierLabel;
    }

    function formatAgo(ms) {
        var mins = Math.floor((countdownNow - ms) / 60000);
        if (mins < 1)
            return tr("just now");
        if (mins < 60)
            return mins + " " + tr("min ago");
        if (mins < 1440)
            return Math.floor(mins / 60) + " " + tr("h ago");
        return Math.floor(mins / 1440) + " " + tr("d ago");
    }

    function errorText(code) {
        var t = tr(code);
        if (t === code && code.indexOf("http_") === 0)
            return "HTTP " + code.substring(5);
        return t;
    }

    // --- Data ---

    function applyResult(text) {
        var out;
        try {
            out = JSON.parse(text);
        } catch (e) {
            console.warn("canaryClaudeUsage: bad script output", e);
            return;
        }
        days = out.days || {};
        sessions = out.sessions || [];
        if (out.syncError !== undefined)
            syncError = out.syncError;

        var u = out.usage;
        if (u && u.data) {
            subscriptionType = u.subscriptionType || "";
            rateLimitTier = u.rateLimitTier || "";
            syncedAt = u.fetchedAt || 0;
            usageData = u.data;
        }
        countdownNow = Date.now();
    }

    // Offline: local transcripts + last cached /usage
    function scanLocal() {
        if (!scanProcess.running && !syncProcess.running)
            scanProcess.running = true;
    }

    // The only network call: refresh button, plus auto sync / sync on open when enabled
    function syncUsage() {
        if (syncProcess.running)
            return;
        lastSyncAttempt = Date.now();
        syncProcess.running = true;
    }

    // Measured from the last attempt, not the last success, so a failing
    // endpoint is retried once per interval instead of every minute.
    function maybeAutoSync() {
        if (!autoSync)
            return;
        var last = Math.max(syncedAt, lastSyncAttempt);
        if (Date.now() - last >= syncInterval * 60000)
            syncUsage();
    }

    // Popout opened: sync if enabled (it rescans too), otherwise rescan offline
    function onPopoutOpened() {
        if (defaultTab !== "last")
            activeTab = parseInt(defaultTab);
        if (defaultRange !== "last")
            statsRange = parseInt(defaultRange);
        if (syncOnOpen && Date.now() - Math.max(syncedAt, lastSyncAttempt) > 60000)
            syncUsage();
        else
            scanLocal();
    }

    readonly property var scriptEnv: claudeConfigDir ? {
        "CLAUDE_CONFIG_DIR": claudeConfigDir
    } : {}

    Process {
        id: scanProcess
        command: ["timeout", "120", "python3", root.scriptPath]
        environment: root.scriptEnv
        stdout: StdioCollector {
            onStreamFinished: root.applyResult(text)
        }
    }

    Process {
        id: syncProcess
        command: ["timeout", "120", "python3", root.scriptPath, "--sync"]
        environment: root.scriptEnv
        stdout: StdioCollector {
            onStreamFinished: root.applyResult(text)
        }
    }

    // Initial scan loads the cached /usage; auto sync is evaluated after that
    // so a fresh-enough cache does not trigger a request at startup.
    Connections {
        target: scanProcess
        function onExited() {
            root.maybeAutoSync();
        }
    }

    onSyncIntervalChanged: maybeAutoSync()

    // Switching accounts: drop everything shown and reload from the new dir
    onClaudeConfigDirChanged: {
        days = {};
        sessions = [];
        usageData = null;
        syncedAt = 0;
        syncError = "";
        subscriptionType = "";
        rateLimitTier = "";
        Qt.callLater(scanLocal);
    }

    Component.onCompleted: scanLocal()

    // --- Shared building blocks ---

    component Card: StyledRect {
        default property alias content: cardCol.data
        property string title: ""
        property string subtitle: ""
        property alias spacing: cardCol.spacing
        width: parent ? parent.width : 0
        height: cardCol.implicitHeight + Theme.spacingM * 2
        color: Theme.surfaceContainerHigh

        Column {
            id: cardCol
            x: Theme.spacingM
            y: Theme.spacingM
            width: parent.width - Theme.spacingM * 2
            spacing: Theme.spacingS

            Item {
                width: parent.width
                height: cardTitle.implicitHeight
                visible: cardTitle.text !== ""

                StyledText {
                    id: cardTitle
                    text: title
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }
                StyledText {
                    anchors.right: parent.right
                    anchors.baseline: cardTitle.baseline
                    width: Math.min(implicitWidth, parent.width - cardTitle.implicitWidth - Theme.spacingS)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                    text: subtitle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    component Bar: Rectangle {
        property real fraction: 0
        property color fill: Theme.primary
        width: parent ? parent.width : 0
        height: 4
        radius: 2
        color: Theme.surfaceVariant

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, fraction))
            height: parent.height
            radius: parent.radius
            color: fill
        }
    }

    component StatCell: Column {
        property string label: ""
        property string value: ""
        spacing: 2

        StyledText {
            width: parent.width
            text: label
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
        }
        StyledText {
            width: parent.width
            text: value
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.DemiBold
            color: Theme.primary
            elide: Text.ElideRight
        }
    }

    component Segmented: Row {
        property var options: []
        property int current: 0
        property bool dimmed: false
        signal picked(int value)
        spacing: Theme.spacingXS
        opacity: dimmed ? 0.35 : 1

        Repeater {
            model: options
            delegate: Rectangle {
                readonly property bool selected: current === modelData.value
                width: segLabel.implicitWidth + Theme.spacingM * 1.5
                height: 28
                radius: 14
                color: selected && !dimmed ? Theme.primary : Theme.surfaceContainerHigh

                StyledText {
                    id: segLabel
                    anchors.centerIn: parent
                    text: modelData.label
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: selected ? Font.Medium : Font.Normal
                    color: selected && !dimmed ? Theme.primaryText : Theme.surfaceVariantText
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !dimmed
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picked(modelData.value)
                }
            }
        }
    }

    // --- Taskbar pills (last synced 5h utilization) ---

    Component {
        id: pillRing
        Canvas {
            width: root.iconSize
            height: root.iconSize
            renderStrategy: Canvas.Cooperative

            property real percent: root.pillMetric === "seven_day" ? root.sevenDayUtil : root.fiveHourUtil
            onPercentChanged: requestPaint()
            onWidthChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                root.drawRing(ctx, width / 2, height / 2, width * 0.375, width * 0.125, percent);
            }
        }
    }

    readonly property string pillText: {
        if (pillMetric === "today_tokens")
            return formatTokens(todayStats.tokens);
        if (!hasSynced)
            return "--";
        var pct = pillMetric === "seven_day" ? sevenDayUtil : fiveHourUtil;
        return Math.round(pct) + "%" + (pillOverPace ? " ↑" : "");
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            Loader {
                sourceComponent: pillRing
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.pillText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.pillOverPace ? root.paceColor(root.pillPace.status) : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            Loader {
                sourceComponent: pillRing
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.pillText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.pillOverPace ? root.paceColor(root.pillPace.status) : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // --- Popout ---

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: root.tr("Claude Code Usage")
            detailsText: {
                var parts = [];
                var label = root.formatSubscription(root.subscriptionType, root.rateLimitTier);
                if (label)
                    parts.push(root.tr("Subscription") + ": " + label);
                parts.push(root.hasSynced ? root.tr("Synced") + " " + root.formatAgo(root.syncedAt) : root.tr("Never synced"));
                return parts.join("  ·  ");
            }
            showCloseButton: true

            headerActions: Component {
                DankRefreshButton {
                    busy: syncProcess.running
                    tooltipText: root.tr("Sync /usage")
                    onClicked: root.syncUsage()
                }
            }

            // Rescan local transcripts (or sync, if enabled) every time the popout opens
            Component.onCompleted: root.onPopoutOpened()
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible)
                        root.onPopoutOpened();
                }
            }

            Column {
                width: parent.width - Theme.spacingM * 2
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingL

                // --- Tabs and range on one row; wheel over it cycles tabs ---
                Item {
                    width: parent.width
                    height: tabBar.height

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: wheel => {
                            var step = wheel.angleDelta.y < 0 ? 1 : -1;
                            root.activeTab = (root.activeTab + step + 3) % 3;
                        }
                    }

                    Segmented {
                        id: tabBar
                        options: [
                            {
                                value: 0,
                                label: root.tr("Usage")
                            },
                            {
                                value: 1,
                                label: root.tr("Stats")
                            },
                            {
                                value: 2,
                                label: root.tr("Models")
                            }
                        ]
                        current: root.activeTab
                        onPicked: value => root.activeTab = value
                    }

                    // Range applies to both Stats and Models; dimmed on the Usage tab
                    Segmented {
                        anchors.right: parent.right
                        dimmed: root.activeTab === 0
                        options: [
                            {
                                value: 0,
                                label: root.tr("All")
                            },
                            {
                                value: 30,
                                label: root.tr("30d")
                            },
                            {
                                value: 7,
                                label: root.tr("7d")
                            }
                        ]
                        current: root.statsRange
                        onPicked: value => root.statsRange = value
                    }
                }

                // --- Sync error ---
                StyledRect {
                    width: parent.width
                    height: errorRow.implicitHeight + Theme.spacingS * 2
                    color: Theme.withAlpha(Theme.error, 0.12)
                    visible: root.activeTab === 0 && root.syncError !== ""

                    Row {
                        id: errorRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            id: errorIcon
                            name: "error"
                            size: 16
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            width: parent.width - errorIcon.width - parent.spacing
                            text: root.tr("Sync failed") + ": " + root.errorText(root.syncError)
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.error
                            wrapMode: Text.WordWrap
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // ================= Usage tab (/usage) =================
                Column {
                    width: parent.width
                    spacing: Theme.spacingL
                    visible: root.activeTab === 0

                    // --- 5h Rate Window card ---
                    StyledRect {
                        width: parent.width
                        height: fiveHourContent.implicitHeight + Theme.spacingS * 2
                        color: Theme.surfaceContainerHigh
                        opacity: root.hasSynced ? 1 : 0.5

                        Row {
                            id: fiveHourContent
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingM

                            Canvas {
                                id: fiveHourRing
                                width: 100
                                height: 100
                                anchors.verticalCenter: parent.verticalCenter
                                renderStrategy: Canvas.Cooperative

                                property real percent: root.fiveHourUtil
                                onPercentChanged: requestPaint()
                                property var pace: root.fiveHourPace
                                onPaceChanged: requestPaint()

                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.reset();
                                    root.drawRing(ctx, width / 2, height / 2, 38, 8, percent);
                                    root.drawPaceTick(ctx, width / 2, height / 2, 38, 8, pace);
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    text: root.hasSynced ? Math.round(root.fiveHourUtil) + "%" : "--"
                                    font.pixelSize: Theme.fontSizeXLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            Column {
                                width: Math.max(0, parent.width - fiveHourRing.width - parent.spacing)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                StyledText {
                                    width: parent.width
                                    text: root.tr("5h Rate Window")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    text: Math.round(root.fiveHourUtil) + "% " + root.tr("used")
                                    visible: root.hasSynced
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: root.progressColor(root.fiveHourUtil)
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    text: root.paceLabel(root.fiveHourPace)
                                    visible: root.showPacing && text !== ""
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: root.paceColor(root.fiveHourPace.status)
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    text: root.fiveHourCountdown
                                    visible: text !== ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }

                    // --- 7-Day Usage card ---
                    StyledRect {
                        width: parent.width
                        height: sevenDayContent.implicitHeight + Theme.spacingM * 2
                        color: Theme.surfaceContainerHigh
                        opacity: root.hasSynced ? 1 : 0.5

                        Row {
                            id: sevenDayContent
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            Canvas {
                                id: weeklySmallRing
                                width: 72
                                height: 72
                                anchors.verticalCenter: parent.verticalCenter
                                renderStrategy: Canvas.Cooperative

                                property real percent: root.sevenDayUtil
                                onPercentChanged: requestPaint()
                                property var pace: root.sevenDayPace
                                onPaceChanged: requestPaint()

                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.reset();
                                    root.drawRing(ctx, width / 2, height / 2, 28, 6, percent);
                                    root.drawPaceTick(ctx, width / 2, height / 2, 28, 6, pace);
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    text: root.hasSynced ? Math.round(root.sevenDayUtil) + "%" : "--"
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            Column {
                                width: Math.max(0, parent.width - weeklySmallRing.width - parent.spacing)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                StyledText {
                                    width: parent.width
                                    text: root.tr("7-Day Usage") + (root.hasSynced ? " · " + Math.round(root.sevenDayUtil) + "%" : "")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    text: root.paceLabel(root.sevenDayPace)
                                    visible: root.showPacing && text !== ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: root.paceColor(root.sevenDayPace.status)
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    text: {
                                        var parts = [];
                                        if (root.weekStats.sessions > 0)
                                            parts.push(root.weekStats.sessions + " " + root.tr("sessions"));
                                        if (root.weekStats.messages > 0)
                                            parts.push(root.weekStats.messages + " " + root.tr("msgs"));
                                        return parts.join(" · ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    visible: text !== ""
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    text: root.sevenDayCountdown
                                    visible: text !== ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }

                    // --- All limits reported by /usage ---
                    Card {
                        title: root.tr("Limits")
                        visible: root.limits.length > 0
                        spacing: Theme.spacingM

                        Repeater {
                            model: root.limits
                            delegate: Column {
                                width: parent.width
                                spacing: 4

                                readonly property real pct: modelData.percent || 0

                                Item {
                                    width: parent.width
                                    height: limitName.implicitHeight

                                    StyledText {
                                        id: limitName
                                        text: root.limitLabel(modelData) + (modelData.is_active ? "  ·  " + root.tr("active") : "")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }
                                    StyledText {
                                        anchors.right: parent.right
                                        text: Math.round(pct) + "%"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: root.severityColor(modelData.severity, pct)
                                    }
                                }

                                Bar {
                                    fraction: pct / 100
                                    fill: root.severityColor(modelData.severity, pct)
                                }

                                StyledText {
                                    text: modelData.resets_at ? root.resetText(modelData.resets_at) : root.tr("No reset time")
                                    font.pixelSize: 11
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }

                    // --- Extra usage / credits ---
                    Card {
                        title: root.tr("Extra usage")
                        subtitle: {
                            var s = root.spend, e = root.extraUsage;
                            var on = s ? s.enabled : e && e.is_enabled;
                            var txt = on ? root.tr("Enabled") : root.tr("Disabled");
                            var reason = s && s.disabled_reason || e && e.disabled_reason;
                            return reason ? txt + " · " + reason : txt;
                        }
                        visible: root.spend !== null || root.extraUsage !== null

                        Grid {
                            width: parent.width
                            columns: 3
                            visible: root.spend !== null

                            StatCell {
                                width: parent.width / 3
                                label: root.tr("Used")
                                value: root.spend ? root.formatMoney(root.spend.used) || "—" : "—"
                            }
                            StatCell {
                                width: parent.width / 3
                                label: root.tr("Limit")
                                value: root.spend && root.spend.limit ? root.formatMoney(root.spend.limit) : root.tr("No limit")
                            }
                            StatCell {
                                width: parent.width / 3
                                label: root.tr("Balance")
                                value: root.spend && root.spend.balance ? root.formatMoney(root.spend.balance) : "—"
                            }
                        }

                        Bar {
                            visible: root.spend !== null && root.spend.limit !== null
                            fraction: root.spend ? (root.spend.percent || 0) / 100 : 0
                            fill: root.severityColor(root.spend ? root.spend.severity : "", root.spend ? root.spend.percent : 0)
                        }

                        StyledText {
                            width: parent.width
                            visible: text !== ""
                            text: {
                                var parts = [];
                                if (root.spend && root.spend.auto_reload)
                                    parts.push(root.tr("Auto reload"));
                                if (root.extraUsage && root.extraUsage.spend_limit_reached)
                                    parts.push(root.tr("Spend limit reached"));
                                return parts.join(" · ");
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                // ================= Stats tab (/stats overview) =================
                Column {
                    width: parent.width
                    spacing: Theme.spacingL
                    visible: root.activeTab === 1

                    // --- Heatmap card ---
                    Card {
                        title: root.tr("Activity")
                        subtitle: (root.heatmapMetric === "messages" ? root.heatmap.total.toLocaleString() + " " + root.tr("msgs") : root.formatTokens(root.heatmap.total) + " tokens") + " · " + root.heatmap.activeDays + " " + root.tr("active days")

                        Item {
                            id: heatArea
                            readonly property int labelWidth: 18
                            readonly property int step: root.heatCell + root.heatGap
                            width: parent.width
                            height: monthRow.height + 4 + 7 * step - root.heatGap

                            onWidthChanged: root.heatAvailWidth = width - labelWidth
                            Component.onCompleted: root.heatAvailWidth = width - labelWidth

                            Item {
                                id: monthRow
                                x: heatArea.labelWidth
                                width: parent.width - x
                                height: 14

                                Repeater {
                                    model: root.heatmap.months
                                    delegate: StyledText {
                                        x: modelData.week * heatArea.step
                                        text: modelData.label
                                        font.pixelSize: 10
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            Repeater {
                                model: root.weekStartsSunday ? [1, 3, 5] : [0, 2, 4]
                                delegate: StyledText {
                                    y: monthRow.height + 4 + modelData * heatArea.step + (root.heatCell - height) / 2
                                    text: root.dayLabels[modelData]
                                    font.pixelSize: 9
                                    color: Theme.surfaceVariantText
                                }
                            }

                            Grid {
                                id: heatGrid
                                x: heatArea.labelWidth
                                y: monthRow.height + 4
                                rows: 7
                                flow: Grid.TopToBottom
                                spacing: root.heatGap

                                Repeater {
                                    model: root.heatmap.cells
                                    delegate: Rectangle {
                                        width: root.heatCell
                                        height: root.heatCell
                                        radius: 2
                                        visible: !modelData.future
                                        color: root.heatColor(modelData.level)
                                        border.width: modelData.key === root.todayKey || (root.hoveredCell && root.hoveredCell.key === modelData.key) ? 1 : 0
                                        border.color: Theme.surfaceText
                                    }
                                }
                            }

                            // One hover area for the whole grid: gaps between cells map to the
                            // nearest cell, so moving across the grid never clears the hover.
                            MouseArea {
                                anchors.fill: heatGrid
                                hoverEnabled: true
                                onPositionChanged: mouse => {
                                    var w = Math.floor(mouse.x / heatArea.step), d = Math.floor(mouse.y / heatArea.step);
                                    var c = root.heatmap.cells[Math.max(0, Math.min(root.heatWeeks - 1, w)) * 7 + Math.max(0, Math.min(6, d))];
                                    var next = c && !c.future ? c : null;
                                    if ((next && next.key) !== (root.hoveredCell && root.hoveredCell.key))
                                        root.hoveredCell = next;
                                }
                                onExited: root.hoveredCell = null
                            }
                        }

                        // Fixed-height footer: detail on the left, legend always on the right
                        Item {
                            width: parent.width
                            height: 16

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: heatArea.labelWidth
                                anchors.right: legendRow.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: {
                                    var c = root.hoveredCell;
                                    if (!c)
                                        return root.tr("Hover a day for details");
                                    var head = c.key + " " + root.dayLabels[c.dow];
                                    if (c.tokens <= 0)
                                        return head + " · " + root.tr("No activity");
                                    return head + " · " + root.formatTokens(c.tokens) + " · " + c.messages + " " + root.tr("msgs");
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.hoveredCell ? Theme.surfaceText : Theme.surfaceVariantText
                            }

                            Row {
                                id: legendRow
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 3

                                StyledText {
                                    text: root.tr("Less")
                                    font.pixelSize: 10
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Repeater {
                                    model: 5
                                    delegate: Rectangle {
                                        width: 9
                                        height: 9
                                        radius: 2
                                        color: root.heatColor(index)
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                                StyledText {
                                    text: root.tr("More")
                                    font.pixelSize: 10
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    // --- Overview grid, same figures as /stats ---
                    Card {
                        title: root.tr("Overview")
                        subtitle: root.rangeStats.startKey + " → " + root.todayKey

                        Grid {
                            width: parent.width
                            columns: 2
                            rowSpacing: Theme.spacingM

                            readonly property var rs: root.rangeStats

                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Favorite model")
                                value: parent.rs.models.length ? root.modelName(parent.rs.models[0].id) : root.tr("N/A")
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Total tokens")
                                value: root.formatTokens(parent.rs.tokens)
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Sessions")
                                value: parent.rs.sessions.toLocaleString()
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Longest session")
                                value: parent.rs.longestSession ? root.formatDuration(parent.rs.longestSession.end - parent.rs.longestSession.start) : root.tr("N/A")
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Current streak")
                                value: parent.rs.currentStreak + " " + root.tr("days")
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Longest streak")
                                value: parent.rs.longestStreak + " " + root.tr("days")
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Active days")
                                value: parent.rs.activeDays + " / " + parent.rs.totalDays
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Peak hour")
                                value: parent.rs.peakHour >= 0 ? parent.rs.peakHour + ":00-" + (parent.rs.peakHour + 1) + ":00" : root.tr("N/A")
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Most active day")
                                value: parent.rs.busiest ? parent.rs.busiest.key : root.tr("N/A")
                            }
                            StatCell {
                                width: parent.width / 2
                                label: root.tr("Messages")
                                value: parent.rs.messages.toLocaleString()
                            }
                        }
                    }

                    // --- Messages by hour of day ---
                    Card {
                        title: root.tr("Activity by hour")
                        subtitle: root.hoveredHour >= 0 ? root.hoveredHour + ":00  ·  " + root.rangeStats.hours[root.hoveredHour] + " " + root.tr("msgs") : ""

                        Item {
                            width: parent.width
                            height: 48

                            Row {
                                id: hourRow
                                anchors.fill: parent
                                spacing: 2

                                readonly property real maxHour: Math.max.apply(null, root.rangeStats.hours) || 1

                                Repeater {
                                    model: 24
                                    delegate: Item {
                                        width: (hourRow.width - 23 * 2) / 24
                                        height: hourRow.height

                                        Rectangle {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            height: Math.max(root.rangeStats.hours[index] / hourRow.maxHour * parent.height, root.rangeStats.hours[index] > 0 ? 2 : 0)
                                            radius: 2
                                            color: index === root.rangeStats.peakHour || index === root.hoveredHour ? Theme.primary : Theme.withAlpha(Theme.primary, 0.45)
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onPositionChanged: mouse => root.hoveredHour = Math.max(0, Math.min(23, Math.floor(mouse.x / (width / 24))))
                                onExited: root.hoveredHour = -1
                            }
                        }

                        Item {
                            width: parent.width
                            height: 12

                            Repeater {
                                model: [0, 6, 12, 18, 23]
                                delegate: StyledText {
                                    x: modelData * (hourRow.width + 2) / 24
                                    text: modelData
                                    font.pixelSize: 10
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }

                    // --- Token Consumption card ---
                    Card {
                        title: root.tr("Token Consumption")

                        Row {
                            width: parent.width

                            Repeater {
                                model: [
                                    {
                                        label: root.tr("Today"),
                                        tokens: root.todayStats.tokens,
                                        messages: root.todayStats.messages,
                                        accent: true
                                    },
                                    {
                                        label: root.tr("Week"),
                                        tokens: root.weekStats.tokens,
                                        messages: root.weekStats.messages,
                                        accent: false
                                    },
                                    {
                                        label: root.tr("Month"),
                                        tokens: root.monthStats.tokens,
                                        messages: root.monthStats.messages,
                                        accent: false
                                    }
                                ]
                                delegate: Column {
                                    width: parent.width / 3
                                    spacing: 4

                                    StyledText {
                                        text: modelData.label
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    StyledText {
                                        text: root.formatTokens(modelData.tokens)
                                        font.pixelSize: Theme.fontSizeLarge
                                        font.weight: Font.DemiBold
                                        color: modelData.accent ? Theme.primary : Theme.surfaceText
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    StyledText {
                                        text: modelData.messages.toLocaleString() + " " + root.tr("msgs")
                                        visible: modelData.messages > 0
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }
                        }
                    }

                    // --- Daily activity card (current calendar week) ---
                    Card {
                        title: root.tr("Daily Activity")
                        subtitle: root.hoveredDay >= 0 ? root.dayLabels[root.hoveredDay] + " · " + root.formatTokens(root.weekStats.daily[root.hoveredDay]) + " tokens" : ""

                        Item {
                            width: parent.width
                            height: 70

                            Row {
                                id: chartRow
                                anchors.fill: parent
                                spacing: 4

                                Repeater {
                                    model: 7
                                    delegate: Column {
                                        width: (chartRow.width - 6 * 4) / 7
                                        height: chartRow.height
                                        spacing: 2

                                        readonly property real value: root.weekStats.daily[index]

                                        Item {
                                            width: parent.width
                                            height: parent.height - dayLabel.height - 2

                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                width: Math.max(parent.width - 4, 4)
                                                height: Math.max(value / root.maxDaily * parent.height, value > 0 ? 3 : 0)
                                                radius: 2
                                                color: index === root.todayIndex ? Theme.primary : Theme.surfaceVariant
                                                opacity: root.hoveredDay >= 0 && index !== root.hoveredDay ? 0.4 : 1.0

                                                Behavior on opacity {
                                                    NumberAnimation {
                                                        duration: 120
                                                    }
                                                }
                                            }
                                        }

                                        StyledText {
                                            id: dayLabel
                                            text: root.dayLabels[index]
                                            font.pixelSize: 11
                                            color: index === root.hoveredDay || index === root.todayIndex ? Theme.primary : Theme.surfaceVariantText
                                            anchors.horizontalCenter: parent.horizontalCenter
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onPositionChanged: mouse => {
                                    var i = Math.max(0, Math.min(6, Math.floor(mouse.x / (width / 7))));
                                    root.hoveredDay = root.weekStats.daily[i] > 0 ? i : -1;
                                }
                                onExited: root.hoveredDay = -1
                            }
                        }
                    }
                }

                // ================= Models tab (/stats models) =================
                Column {
                    width: parent.width
                    spacing: Theme.spacingL
                    visible: root.activeTab === 2

                    StyledText {
                        width: parent.width
                        visible: root.rangeStats.models.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        text: root.tr("No model usage in this range")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    // --- Tokens per day, one line per model (like /stats in the terminal) ---
                    Card {
                        title: root.tr("Tokens per day")
                        subtitle: {
                            var i = root.hoveredSeries, s = root.rangeStats.series;
                            if (i < 0 || i >= s.length)
                                return "";
                            return s[i].key + " · " + root.formatTokens(s[i].total);
                        }
                        visible: root.rangeStats.models.length > 0

                        Canvas {
                            id: lineChart
                            width: parent.width
                            height: 130
                            renderStrategy: Canvas.Cooperative

                            readonly property int padL: 40
                            readonly property int padR: 6
                            readonly property int padT: 6
                            readonly property int padB: 16
                            readonly property var series: root.rangeStats.series
                            readonly property var models: root.rangeStats.models
                            readonly property int hover: root.hoveredSeries
                            readonly property real plotW: width - padL - padR
                            readonly property real plotH: height - padT - padB
                            readonly property real maxV: {
                                var m = 0;
                                for (var i = 0; i < series.length; i++)
                                    for (var k in series[i].perModel)
                                        m = Math.max(m, series[i].perModel[k]);
                                return m || 1;
                            }

                            function xAt(i) {
                                return padL + (series.length > 1 ? i * plotW / (series.length - 1) : plotW / 2);
                            }
                            function yAt(v) {
                                return padT + plotH * (1 - v / maxV);
                            }

                            onSeriesChanged: requestPaint()
                            onModelsChanged: requestPaint()
                            onHoverChanged: requestPaint()
                            onWidthChanged: requestPaint()

                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                ctx.font = "10px sans-serif";

                                // Horizontal grid with y labels
                                ctx.lineWidth = 1;
                                for (var g = 0; g <= 2; g++) {
                                    var gy = Math.round(yAt(maxV * g / 2)) + 0.5;
                                    ctx.strokeStyle = Theme.withAlpha(Theme.surfaceText, 0.08);
                                    ctx.beginPath();
                                    ctx.moveTo(padL, gy);
                                    ctx.lineTo(width - padR, gy);
                                    ctx.stroke();
                                    ctx.fillStyle = Theme.surfaceVariantText;
                                    ctx.textAlign = "right";
                                    ctx.fillText(root.formatTokens(maxV * g / 2), padL - 6, gy + 3);
                                }

                                // X labels: first, middle, last day
                                var n = series.length;
                                if (n > 0) {
                                    var idx = n > 2 ? [0, Math.floor((n - 1) / 2), n - 1] : n > 1 ? [0, n - 1] : [0];
                                    for (var li = 0; li < idx.length; li++) {
                                        ctx.textAlign = li === 0 && n > 1 ? "left" : li === idx.length - 1 && n > 1 ? "right" : "center";
                                        ctx.fillText(series[idx[li]].key.substring(5), xAt(idx[li]), height - 3);
                                    }
                                }

                                // Hover guide
                                if (hover >= 0 && hover < n) {
                                    ctx.strokeStyle = Theme.withAlpha(Theme.surfaceText, 0.3);
                                    ctx.beginPath();
                                    ctx.moveTo(Math.round(xAt(hover)) + 0.5, padT);
                                    ctx.lineTo(Math.round(xAt(hover)) + 0.5, padT + plotH);
                                    ctx.stroke();
                                }

                                // One line per model, least used first so the top model is drawn on top
                                ctx.lineWidth = 2;
                                ctx.lineJoin = "round";
                                for (var m = models.length - 1; m >= 0; m--) {
                                    var id = models[m].id;
                                    var color = root.modelPalette[m % root.modelPalette.length];
                                    ctx.strokeStyle = color;
                                    ctx.globalAlpha = root.hoveredModel >= 0 && root.hoveredModel !== m ? 0.25 : 1;
                                    ctx.beginPath();
                                    for (var i = 0; i < n; i++) {
                                        var y = yAt(series[i].perModel[id] || 0);
                                        if (i === 0)
                                            ctx.moveTo(xAt(i), y);
                                        else
                                            ctx.lineTo(xAt(i), y);
                                    }
                                    if (n === 1)
                                        ctx.lineTo(xAt(0) + 1, yAt(series[0].perModel[id] || 0));
                                    ctx.stroke();
                                    if (hover >= 0 && hover < n) {
                                        ctx.fillStyle = color;
                                        ctx.beginPath();
                                        ctx.arc(xAt(hover), yAt(series[hover].perModel[id] || 0), 3, 0, 2 * Math.PI);
                                        ctx.fill();
                                    }
                                }
                                ctx.globalAlpha = 1;
                            }

                            Connections {
                                target: root
                                function onHoveredModelChanged() {
                                    lineChart.requestPaint();
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onPositionChanged: mouse => {
                                    var n = lineChart.series.length;
                                    var i = n > 1 ? Math.round((mouse.x - lineChart.padL) / (lineChart.plotW / (n - 1))) : 0;
                                    root.hoveredSeries = Math.max(0, Math.min(n - 1, i));
                                }
                                onExited: root.hoveredSeries = -1
                            }
                        }
                    }

                    // --- Share: donut + ranked list; hover a model for its details ---
                    Card {
                        title: root.tr("Share")
                        visible: root.rangeStats.models.length > 0

                        Item {
                            width: parent.width
                            height: Math.max(donut.height, modelList.height)

                            Canvas {
                                id: donut
                                width: 110
                                height: 110
                                renderStrategy: Canvas.Cooperative

                                readonly property var models: root.rangeStats.models
                                readonly property int hover: root.hoveredModel
                                onModelsChanged: requestPaint()
                                onHoverChanged: requestPaint()

                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.reset();
                                    var total = root.rangeStats.tokens || 1;
                                    var a = -Math.PI / 2, cx = width / 2, cy = height / 2;
                                    for (var i = 0; i < models.length; i++) {
                                        var sweep = 2 * Math.PI * models[i].total / total;
                                        ctx.beginPath();
                                        ctx.arc(cx, cy, 42, a, a + Math.max(sweep, 0.02));
                                        ctx.lineWidth = hover === i ? 16 : 11;
                                        ctx.strokeStyle = root.modelPalette[i % root.modelPalette.length];
                                        ctx.globalAlpha = hover >= 0 && hover !== i ? 0.35 : 1;
                                        ctx.stroke();
                                        a += sweep;
                                    }
                                }

                                Column {
                                    anchors.centerIn: parent

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: {
                                            var m = root.rangeStats.models[root.hoveredModel];
                                            if (!m)
                                                return root.formatTokens(root.rangeStats.tokens);
                                            return (m.total / (root.rangeStats.tokens || 1) * 100).toFixed(1) + "%";
                                        }
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.hoveredModel >= 0 ? root.formatTokens(root.rangeStats.models[root.hoveredModel].total) : "tokens"
                                        font.pixelSize: 10
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            Column {
                                id: modelList
                                x: donut.width + Theme.spacingM
                                width: parent.width - x
                                anchors.verticalCenter: parent.verticalCenter

                                readonly property int rowH: 24

                                Repeater {
                                    model: root.rangeStats.models
                                    delegate: Item {
                                        width: modelList.width
                                        height: modelList.rowH
                                        opacity: root.hoveredModel >= 0 && root.hoveredModel !== index ? 0.5 : 1

                                        Rectangle {
                                            id: dot
                                            width: 8
                                            height: 8
                                            radius: 4
                                            color: root.modelPalette[index % root.modelPalette.length]
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        StyledText {
                                            anchors.left: dot.right
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.right: pctText.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.modelName(modelData.id)
                                            elide: Text.ElideRight
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                        }
                                        StyledText {
                                            id: pctText
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: (modelData.total / (root.rangeStats.tokens || 1) * 100).toFixed(1) + "%"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceText
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: modelList
                                hoverEnabled: true
                                onPositionChanged: mouse => root.hoveredModel = Math.max(0, Math.min(root.rangeStats.models.length - 1, Math.floor(mouse.y / modelList.rowH)))
                                onExited: root.hoveredModel = -1
                            }
                        }

                        // Details of the hovered model, or all models combined
                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.withAlpha(Theme.surfaceText, 0.08)
                        }

                        Row {
                            width: parent.width

                            readonly property var m: {
                                var list = root.rangeStats.models;
                                if (list[root.hoveredModel])
                                    return list[root.hoveredModel];
                                var sum = {
                                    input: 0,
                                    output: 0,
                                    cacheRead: 0,
                                    cacheWrite: 0,
                                    messages: 0
                                };
                                for (var i = 0; i < list.length; i++)
                                    for (var k in sum)
                                        sum[k] += list[i][k];
                                return sum;
                            }

                            StatCell {
                                width: parent.width / 5
                                label: root.tr("Input")
                                value: root.formatTokens(parent.m.input)
                            }
                            StatCell {
                                width: parent.width / 5
                                label: root.tr("Output")
                                value: root.formatTokens(parent.m.output)
                            }
                            StatCell {
                                width: parent.width / 5
                                label: root.tr("Cache read")
                                value: root.formatTokens(parent.m.cacheRead)
                            }
                            StatCell {
                                width: parent.width / 5
                                label: root.tr("Cache write")
                                value: root.formatTokens(parent.m.cacheWrite)
                            }
                            StatCell {
                                width: parent.width / 5
                                label: root.tr("Messages")
                                value: parent.m.messages.toLocaleString()
                            }
                        }
                    }
                }

                // Bottom padding to match sides (compensates Column spacing)
                Item {
                    width: 1
                    height: 1
                }
            }
        }
    }
}
