.pragma library

var strings = {
    "Tailscale": { zh: "Tailscale" },
    "tailscaled is not reachable": { zh: "无法连接 tailscaled" },
    // Backend state
    "Connected": { zh: "已连接" },
    "Disconnected": { zh: "已断开" },
    "Needs login": { zh: "需要登录" },
    "Starting": { zh: "启动中" },
    "Not configured": { zh: "未配置" },
    // Status card and preference chips
    "Relay": { zh: "中继" },
    "Exit node": { zh: "出口节点" },
    "Offers exit node": { zh: "提供出口节点" },
    "Routes": { zh: "子网路由" },
    "Incoming blocked": { zh: "阻止入站" },
    "Update": { zh: "新版本" },
    "Copied": { zh: "已复制" },
    // Devices
    "Devices": { zh: "设备" },
    "online": { zh: "在线" },
    "offline": { zh: "离线" },
    "direct": { zh: "直连" },
    "relay": { zh: "中继" },
    "No other devices": { zh: "没有其他设备" },
    "No devices online": { zh: "没有在线设备" },
    // Traffic
    "Traffic": { zh: "流量" },
    "received": { zh: "接收" },
    "sent": { zh: "发送" },
    // Network check
    "Relay latency": { zh: "中继延迟" },
    "Checking the network...": { zh: "正在检测网络…" },
    "Not checked yet": { zh: "尚未检测" },
    "Easy NAT": { zh: "简单 NAT" },
    "Port mapping": { zh: "端口映射" },
    "Captive portal": { zh: "门户认证" },
    // Relative time
    "just now": { zh: "刚刚" },
    "min": { zh: "分钟" },
    "hours": { zh: "小时" },
    "days": { zh: "天" },
    "%1 ago": { zh: "%1前" },
    // Settings
    "Read-only Tailscale status: this device, the devices in the tailnet, traffic and the relay latencies.": {
        zh: "只读展示 Tailscale 状态：本机、tailnet 内的设备、流量和中继延迟。"
    },
    "Bar shows": { zh: "状态栏显示" },
    "Peers online": { zh: "在线设备数" },
    "Online / total": { zh: "在线 / 总数" },
    "This device's IP": { zh: "本机 IP" },
    "Icon only": { zh: "仅图标" },
    "Hide offline devices": { zh: "隐藏离线设备" },
    "Check the network when the popout opens": { zh: "打开面板时检测网络" },
    "Runs tailscale netcheck for the relay latency chart, at most once a minute.": {
        zh: "运行 tailscale netcheck 以绘制中继延迟图表，每分钟最多一次。"
    },
    "Admin console URL": { zh: "管理界面地址" },
    "Base URL of the admin console, without /machines. Change it for a self-hosted control server.": {
        zh: "管理界面的基础地址（不含 /machines）。自建控制服务器时可修改。"
    }
};

function tr(key, lang) {
    var entry = strings[key];
    if (entry && entry[lang])
        return entry[lang];
    return key;
}
