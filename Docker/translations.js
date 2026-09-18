.pragma library

var strings = {
    "Docker": { zh: "Docker" },
    "Docker is not reachable": { zh: "无法连接 Docker" },
    "running": { zh: "运行中" },
    "images": { zh: "镜像" },
    // Sections
    "Containers": { zh: "容器" },
    "Images": { zh: "镜像" },
    "Networks": { zh: "网络" },
    "Volumes": { zh: "卷" },
    "No containers": { zh: "没有容器" },
    // Row details
    "in use": { zh: "使用中" },
    "unused": { zh: "未使用" },
    "dangling": { zh: "悬空" },
    "anonymous": { zh: "匿名" },
    "containers": { zh: "个容器" },
    "Image": { zh: "镜像" },
    "Ports": { zh: "端口" },
    "Status": { zh: "状态" },
    "ID": { zh: "ID" },
    "Project dir": { zh: "项目目录" },
    "Mountpoint": { zh: "挂载点" },
    // Actions
    "Start": { zh: "启动" },
    "Stop": { zh: "停止" },
    "Restart": { zh: "重启" },
    "Recreate": { zh: "重建" },
    "Delete": { zh: "删除" },
    "Down": { zh: "删除（compose down）" },
    "Logs": { zh: "实时日志" },
    "Shell": { zh: "在终端中打开 shell" },
    "Prune dangling images": { zh: "清理悬空镜像" },
    "Prune unused networks": { zh: "清理未使用的网络" },
    "Prune unused anonymous volumes": { zh: "清理未使用的匿名卷" },
    "Click again to confirm": { zh: "再次点击确认" },
    "failed": { zh: "失败" },
    "Hover an item for actions": { zh: "悬停在条目上查看可用操作" },
    // Logs
    "Back": { zh: "返回" },
    "Follow": { zh: "跟随最新" },
    "Paused": { zh: "已暂停跟随" },
    "Wrap": { zh: "自动换行" },
    "Clear": { zh: "清空" },
    "Copy all": { zh: "复制全部" },
    "Open in terminal": { zh: "在终端中打开" },
    "Filter": { zh: "过滤" },
    "lines": { zh: "行" },
    "Log stream ended": { zh: "日志流已结束" },
    "Streaming": { zh: "实时输出中" },
    "Close": { zh: "收起" },
    "Terminal": { zh: "终端" },
    "Working...": { zh: "执行中…" },
    // Settings
    "Show Docker containers, compose projects, images, networks and volumes, with actions and live logs.": {
        zh: "展示 Docker 容器、Compose 项目、镜像、网络和卷，支持常用操作和实时日志。"
    },
    "Hide stopped containers": { zh: "隐藏已停止的容器" },
    "Confirm destructive actions": { zh: "危险操作需要确认" },
    "Delete, down and prune need a second click.": { zh: "删除、compose down 和清理需要点两次。" },
    "Terminal command": { zh: "终端命令" },
    "Prefix used to open a shell or logs in a terminal, e.g. kitty, alacritty -e, foot.": {
        zh: "在终端中打开 shell 或日志时使用的命令前缀，例如 kitty、alacritty -e、foot。"
    },
    "Log lines on open": { zh: "打开日志时加载的行数" },
    "Show log timestamps": { zh: "显示日志时间" },
    "Bar shows": { zh: "状态栏显示" },
    "Running containers": { zh: "运行中的容器数" },
    "Running / total": { zh: "运行中 / 总数" },
    "Icon only": { zh: "仅图标" }
};

function tr(key, lang) {
    var entry = strings[key];
    if (entry && entry[lang])
        return entry[lang];
    return key;
}
