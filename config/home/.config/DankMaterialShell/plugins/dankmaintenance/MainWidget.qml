import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "dankmaintenance"

    // 收集器绝对路径（插件目录固定不变）
    readonly property string collectorPath: "/home/pang/.config/DankMaterialShell/plugins/dankmaintenance/collect-status"

    // ---- 设置 ----
    property int pollInterval: (pluginData.pollInterval || 300) * 1000
    property int updatesYellow: pluginData.updatesYellow || 5
    property int updatesRed: pluginData.updatesRed || 50
    property int diskYellow: pluginData.diskYellow || 70
    property int diskRed: pluginData.diskRed || 90
    property int failedRed: pluginData.failedRed || 3
    property int snapshotStaleHours: pluginData.snapshotStaleHours || 48
    property int memoryYellow: pluginData.memoryYellow || 70
    property int memoryRed: pluginData.memoryRed || 90
    property int journalYellow: pluginData.journalYellow || 5
    property int journalRed: pluginData.journalRed || 50
    property int orphanYellow: pluginData.orphanYellow || 1
    property int orphanRed: pluginData.orphanRed || 20

    // ---- 阈值 clamp：yellow 必须 <= red，否则 red 分支先判时 warn 状态被永久吞掉 ----
    // 用户可能在设置面板把 yellow 调到 > red（如 yellow=90, red=10），
    // 这里保证 warn 区间始终存在：yellow = min(原始值, red)
    readonly property int updatesYellowClamped: Math.min(root.updatesYellowClamped, root.updatesRed)
    readonly property int diskYellowClamped: Math.min(root.diskYellowClamped, root.diskRed)
    readonly property int memoryYellowClamped: Math.min(root.memoryYellowClamped, root.memoryRed)
    readonly property int journalYellowClamped: Math.min(root.journalYellowClamped, root.journalRed)
    readonly property int orphanYellowClamped: Math.min(root.orphanYellowClamped, root.orphanRed)

    // 胶囊显示开关（隐藏的胶囊排除出 pill 颜色与文本聚合）
    property bool showUpdatesChip: pluginData.showUpdatesChip !== false
    property bool showDiskChip: pluginData.showDiskChip !== false
    property bool showFailedChip: pluginData.showFailedChip !== false
    property bool showSnapshotChip: pluginData.showSnapshotChip !== false
    property bool showMemoryChip: pluginData.showMemoryChip !== false
    property bool showJournalChip: pluginData.showJournalChip !== false
    property bool showOrphanChip: pluginData.showOrphanChip !== false

    // ---- 运行时状态 ----
    property var status: null
    property string lastError: ""
    // 采集失败但保留上次成功数据时为 true（数据可能过期）
    property bool stale: false

    // ---- 派生状态 ----
    readonly property int updateTotal: root.status?.updates?.total ?? -1
    readonly property int maxDiskPct: {
        if (!root.status?.disk) return -1
        const rootPct = root.status.disk.root?.used_pct ?? -1
        const homePct = root.status.disk.home?.used_pct ?? -1
        return Math.max(rootPct, homePct)
    }
    readonly property int failedCount: root.status?.failed_units?.length ?? 0
    readonly property var snapshotAgeHours: {
        if (!root.status?.snapshots) return null
        const now = Date.now() / 1000
        let minTs = null
        for (const key of ["root", "home"]) {
            const ts = root.status.snapshots[key]?.newest_ts
            if (ts) minTs = minTs === null ? ts : Math.min(minTs, ts)
        }
        if (minTs === null) return null
        return Math.max(0, Math.round((now - minTs) / 3600))
    }
    readonly property bool snapshotError: {
        if (!root.status?.snapshots) return false
        return !!(root.status.snapshots.root?.error || root.status.snapshots.home?.error)
    }
    readonly property int memoryUsedPct: root.status?.memory?.used_pct ?? -1
    readonly property int journalErrors24h: root.status?.journal_errors?.total ?? -1
    readonly property int orphanCount: root.status?.orphans?.count ?? -1

    // 字体：中文小字 MiSans（现代优雅、字形亲和），大数字/数值 Inter Display（几何显示气质）
    readonly property string fontSmall: "MiSans"
    readonly property string fontDisplay: "Inter Display"

    // 顶栏图标健康度色：最高异常级别优先（隐藏的胶囊不参与聚合）
    readonly property color capsuleColor: {
        if (root.showUpdatesChip && root.updateTotal >= root.updatesRed) return Theme.error
        if (root.showDiskChip && root.maxDiskPct >= root.diskRed) return Theme.error
        if (root.showFailedChip && root.failedCount >= root.failedRed) return Theme.error
        if (root.showMemoryChip && root.memoryUsedPct >= root.memoryRed) return Theme.error
        if (root.showJournalChip && root.journalErrors24h >= root.journalRed) return Theme.error
        if (root.showOrphanChip && root.orphanCount >= root.orphanRed) return Theme.error
        if (root.showUpdatesChip && root.updateTotal >= root.updatesYellowClamped) return Theme.warning
        if (root.showDiskChip && root.maxDiskPct >= root.diskYellowClamped) return Theme.warning
        if (root.showFailedChip && root.failedCount > 0) return Theme.warning
        if (root.showMemoryChip && root.memoryUsedPct >= root.memoryYellowClamped) return Theme.warning
        if (root.showJournalChip && root.journalErrors24h >= root.journalYellowClamped) return Theme.warning
        if (root.showOrphanChip && root.orphanCount >= root.orphanYellowClamped) return Theme.warning
        if (root.showSnapshotChip && root.snapshotAgeHours !== null && root.snapshotAgeHours > root.snapshotStaleHours) return Theme.warning
        if (root.showSnapshotChip && root.snapshotError) return Theme.info
        return Theme.widgetIconColor
    }

    // 胶囊专属色盘：正常态各胶囊不同色，异常时升级为 warning/error 语义色
    // （顺序与 chips 数组一致：updates/disk/failed/snapshots/memory/journal/orphans）
    readonly property var chipPalette: [
        "#5B8DEF", // 待更新：主蓝
        "#43C59E", // 磁盘：青绿
        "#E86A6A", // 失败服务：红
        "#7C5CBF", // 快照：紫
        "#E5A94B", // 内存：琥珀黄
        "#E85C9D", // 日志错误：玫红（区别于待更新蓝）
        "#B57EDC"  // 孤儿包：淡紫
    ]

    // 各胶囊自己的颜色（正常显示专属色，异常升级为告警/错误语义色）
    readonly property color updatesColor: root.updateTotal >= root.updatesRed ? Theme.error
        : (root.updateTotal >= root.updatesYellowClamped ? Theme.warning : root.chipPalette[0])
    readonly property color diskColor: root.maxDiskPct >= root.diskRed ? Theme.error
        : (root.maxDiskPct >= root.diskYellowClamped ? Theme.warning : root.chipPalette[1])
    readonly property color failedColor: root.failedCount >= root.failedRed ? Theme.error
        : (root.failedCount > 0 ? Theme.warning : root.chipPalette[2])
    readonly property color snapshotColor: root.snapshotError ? Theme.info
        : (root.snapshotAgeHours !== null && root.snapshotAgeHours > root.snapshotStaleHours ? Theme.warning : root.chipPalette[3])
    readonly property color memoryColor: root.memoryUsedPct >= root.memoryRed ? Theme.error
        : (root.memoryUsedPct >= root.memoryYellowClamped ? Theme.warning : root.chipPalette[4])
    readonly property color journalColor: root.journalErrors24h >= root.journalRed ? Theme.error
        : (root.journalErrors24h >= root.journalYellowClamped ? Theme.warning : root.chipPalette[5])
    readonly property color orphanColor: root.orphanCount >= root.orphanRed ? Theme.error
        : (root.orphanCount >= root.orphanYellowClamped ? Theme.warning : root.chipPalette[6])

    // 状态徽章（ok/warn/err/info → 文字 + 色）
    readonly property var stateMeta: {
        function metaFor(state) {
            if (state === "err") return { text: "异常", color: Theme.error }
            if (state === "warn") return { text: "注意", color: Theme.warning }
            if (state === "info") return { text: "未知", color: Theme.info }
            return { text: "正常", color: Theme.success }
        }
        return { metaFor }
    }

    // ---- 弹窗胶囊模型：图标 + 标题 + 大数值（受显示开关过滤）----
    readonly property var chips: {
        const all = [
            { key: "updates", icon: "update", title: "待更新", value: root.updateTotal >= 0 ? String(root.updateTotal) : "—", color: root.updatesColor, show: root.showUpdatesChip },
            { key: "disk", icon: "hard_disk", title: "磁盘", value: root.maxDiskPct >= 0 ? root.maxDiskPct + "%" : "—", color: root.diskColor, show: root.showDiskChip },
            { key: "failed", icon: "error", title: "失败服务", value: String(root.failedCount), color: root.failedColor, show: root.showFailedChip },
            { key: "snapshots", icon: "history", title: "快照", value: root.snapshotError ? "—" : (root.snapshotAgeHours !== null ? root.snapshotAgeHours + "h" : "—"), color: root.snapshotColor, show: root.showSnapshotChip },
            { key: "memory", icon: "memory", title: "内存", value: root.memoryUsedPct >= 0 ? root.memoryUsedPct + "%" : "—", color: root.memoryColor, show: root.showMemoryChip },
            { key: "journal", icon: "report", title: "日志错误", value: root.journalErrors24h >= 0 ? String(root.journalErrors24h) : "—", color: root.journalColor, show: root.showJournalChip },
            { key: "orphans", icon: "package", title: "孤儿包", value: root.orphanCount >= 0 ? String(root.orphanCount) : "—", color: root.orphanColor, show: root.showOrphanChip }
        ]
        return all.filter(c => c.show)
    }

    // 无限循环滚动模型：原列表重复 3 份（首|中|尾），滚动窗口始终锚定中间份，
    // 越过边界时瞬移回中间份对应位置（内容相同，视觉无缝）
    readonly property var chipsLoop: root.chips.concat(root.chips).concat(root.chips)

    // ---- 顶栏 pill 摘要（仅图标 + 最严重告警数值；无告警时数字隐藏保持干净）----

    // 当前选中的胶囊下标（默认第一个：待更新）
    property int currentIndex: 0

    // pill 数字：取最严重告警（与 capsuleColor 同序）对应的数值；全绿或无状态时不显示
    // （隐藏的胶囊不参与聚合）
    readonly property bool pillBadgeVisible: root.pillBadgeText !== ""
    readonly property string pillBadgeText: {
        if (!root.status) return ""
        if (root.showUpdatesChip && root.updateTotal >= root.updatesRed) return String(root.updateTotal)
        if (root.showDiskChip && root.maxDiskPct >= root.diskRed) return String(root.maxDiskPct)
        if (root.showFailedChip && root.failedCount >= root.failedRed) return String(root.failedCount)
        if (root.showMemoryChip && root.memoryUsedPct >= root.memoryRed) return String(root.memoryUsedPct)
        if (root.showJournalChip && root.journalErrors24h >= root.journalRed) return String(root.journalErrors24h)
        if (root.showOrphanChip && root.orphanCount >= root.orphanRed) return String(root.orphanCount)
        if (root.showUpdatesChip && root.updateTotal >= root.updatesYellowClamped) return String(root.updateTotal)
        if (root.showDiskChip && root.maxDiskPct >= root.diskYellowClamped) return String(root.maxDiskPct)
        if (root.showFailedChip && root.failedCount > 0) return String(root.failedCount)
        if (root.showMemoryChip && root.memoryUsedPct >= root.memoryYellowClamped) return String(root.memoryUsedPct)
        if (root.showJournalChip && root.journalErrors24h >= root.journalYellowClamped) return String(root.journalErrors24h)
        if (root.showOrphanChip && root.orphanCount >= root.orphanYellowClamped) return String(root.orphanCount)
        // 快照过期显示小时数（与数字风格一致）；读取失败显示 "!"（与 info 色呼应）
        if (root.showSnapshotChip && root.snapshotAgeHours !== null && root.snapshotAgeHours > root.snapshotStaleHours) return String(root.snapshotAgeHours)
        if (root.showSnapshotChip && root.snapshotError) return "!"
        return ""
    }

    // 背景图路径（可配置：设置面板 backgroundImage 覆盖默认冬日图）
    // 归一化：用户可能填裸绝对路径（无 file:// 前缀），QML Image 需要 file:// 才能加载
    readonly property string bgImageSource: {
        const cfg = pluginData.backgroundImage
        if (typeof cfg === "string" && cfg.trim().length > 0) {
            let p = cfg.trim()
            if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(p)) p = "file://" + p
            return p
        }
        return "file:///home/pang/.config/DankMaterialShell/plugins/dankmaintenance/bg-winter.png"
    }

    // 全空健康态：所有胶囊指标都处于正常区间（无 warn/err），用于 KPI 面板的「一切正常 ✓」轻量呈现
    // 注意：数据源读取失败（snapshot/journal/orphans 的 error 标志）不算健康——
    // 缺失的数据会让指标回落为 null/0，若被 ok() 放行会掩盖故障并显示「一切正常」
    readonly property bool allHealthy: {
        if (!root.status) return false
        // 任一数据源显式报错 → 不健康
        if (root.snapshotError) return false
        if (root.status.journal_errors?.error) return false
        if (root.status.orphans?.error) return false
        const ok = v => (v === undefined || v === null || v < 0)
        const below = (v, y) => ok(v) || v <= y
        const eq0 = v => ok(v) || v === 0
        return below(root.updateTotal, root.updatesYellowClamped)
            && below(root.maxDiskPct, root.diskYellowClamped)
            && eq0(root.failedCount)
            && below(root.memoryUsedPct, root.memoryYellowClamped)
            && below(root.journalErrors24h, root.journalYellowClamped)
            && eq0(root.orphanCount)
            && (ok(root.snapshotAgeHours) || root.snapshotAgeHours <= root.snapshotStaleHours)
    }

    // 明细列表最大显示高度（超出内部滚动，弹窗高度封顶）
    readonly property real maxLinesHeight: 216

    // ---- 数据收集 ----
    // 刷新反馈 toast 状态（root 级，供 contentCol 内组件读取）
    property string refreshToastText: ""
    property string refreshToastKind: "ok"
    property bool refreshToastActive: false

    // 弹窗打开时显示轻提示；自动/轮询刷新不打扰，仅在用户主动重试时反馈
    function showRefreshToast(kind, text) {
        root.refreshToastKind = kind
        root.refreshToastText = text
        root.refreshToastActive = true
        toastAutoHideTimer.restart()
    }

    Timer {
        id: toastAutoHideTimer
        interval: 2600
        repeat: false
        onTriggered: root.refreshToastActive = false
    }

    // 数据收集进行中标志：防止轮询与手动重试并发重入（collect 最坏可跑 ~70s）
    property bool collecting: false

    function refreshStatus() {
        if (root.collecting) return
        root.collecting = true
        // 第 4 参 debounceMs=0 立即执行；第 5 参 timeoutMs=90000
        // collect-status 内部各数据源超时 10-20s、串行最坏约 70s，必须大于外部超时
        // （默认 10s 会在 journal/pacman 卡顿时提前杀进程导致 status 永远不更新）
        Proc.runCommand("dankmaintenance.collect", [root.collectorPath], (stdout, exitCode) => {
            root.collecting = false
            if (exitCode !== 0 || !stdout || stdout.trim().length === 0) {
                root.lastError = "collector exit " + exitCode
                // 保留上次成功数据，标记过期（状态灯不熄灭，过期感可见）
                if (root.status) root.stale = true
                root.showRefreshToast("warn", "刷新失败")
                return
            }
            try {
                const obj = JSON.parse(stdout.trim())
                // collect-status 顶层兜底输出 collector_error：脚本内部异常（磁盘满/权限等），
                // 不能把缺失字段当成"全部正常"——保留旧数据并标记过期
                if (obj.collector_error) {
                    root.lastError = obj.collector_error
                    if (root.status) root.stale = true
                    root.updateFooterTimeText()
                    root.showRefreshToast("warn", "刷新失败")
                    return
                }
                root.status = obj
                root.stale = false
                root.lastError = ""
                root.updateFooterTimeText()
                root.showRefreshToast("ok", "状态已刷新")
            } catch (e) {
                console.warn("dankmaintenance: JSON 解析失败:", e, stdout.slice(0, 200))
                root.lastError = "JSON parse error"
                if (root.status) root.stale = true
                root.updateFooterTimeText()
                root.showRefreshToast("warn", "刷新失败")
            }
        }, 0, 90000)
    }

    Component.onCompleted: {
        refreshStatus()
    }

    Timer {
        interval: root.pollInterval
        running: true
        repeat: true
        // 轮询刷新静默：不弹 toast 打扰；只有 retry 手动刷新才有反馈
        // collecting 标志防重入：上一次 collect 未结束（数据源卡顿）时跳过本次
        onTriggered: {
            if (root.collecting) return
            root.collecting = true
            Proc.runCommand("dankmaintenance.collect", [root.collectorPath], (stdout, exitCode) => {
                root.collecting = false
                if (exitCode === 0 && stdout && stdout.trim().length > 0) {
                    try {
                        const obj = JSON.parse(stdout.trim())
                        // collect-status 顶层兜底输出 collector_error：视为失败，保留旧数据标过期
                        if (obj.collector_error) {
                            root.lastError = obj.collector_error
                            if (root.status) root.stale = true
                            root.updateFooterTimeText()
                            return
                        }
                        root.status = obj
                        root.stale = false
                        root.lastError = ""
                        root.updateFooterTimeText()
                    } catch (e) {}
                } else {
                    if (root.status) root.stale = true
                    root.updateFooterTimeText()
                }
            }, 0, 90000)
        }
    }

    // ---- 顶栏入口：状态图标 + 最严重告警数值（无告警时仅图标，保持干净）----
    horizontalBarPill: Component {
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "monitor_heart"
                size: root.iconSize
                color: root.capsuleColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.pillBadgeVisible
                text: root.pillBadgeText
                font.family: root.fontDisplay
                font.pixelSize: 9
                font.weight: Font.DemiBold
                font.letterSpacing: 0.3
                font.features: [{ tag: "tnum" }]
                color: root.capsuleColor
            }
        }
    }

    verticalBarPill: Component {
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "monitor_heart"
                size: root.iconSize
                color: root.capsuleColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.pillBadgeVisible
                text: root.pillBadgeText
                font.family: root.fontDisplay
                font.pixelSize: 9
                font.weight: Font.DemiBold
                font.letterSpacing: 0.3
                font.features: [{ tag: "tnum" }]
                color: root.capsuleColor
            }
        }
    }

    // 体积格式化：>=100G 用整数 G（大数值省空间），<100G 保留 1 位小数
    function fmtGb(gb) {
        if (gb === undefined || gb === null || isNaN(gb)) return "—"
        if (gb >= 100) return Math.round(gb) + " G"
        return (Math.round(gb * 10) / 10) + " G"
    }

    // Qt 的 toLocaleString() 在 zh_CN 下时间格式异常（"2000:09"），自绘统一格式
    function fmtTime(ts) {
        const d = new Date(ts * 1000)
        const pad = n => String(n).padStart(2, "0")
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
            + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
    }

    // 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前（>30 天回退精确时间）
    function fmtRelative(ts) {
        if (!ts) return "未知"
        const diffSec = Math.max(0, (Date.now() / 1000) - ts)
        if (diffSec < 60) return "刚刚"
        if (diffSec < 3600) return Math.floor(diffSec / 60) + " 分钟前"
        if (diffSec < 86400) return Math.floor(diffSec / 3600) + " 小时前"
        if (diffSec < 2592000) return Math.floor(diffSec / 86400) + " 天前"
        return root.fmtTime(ts)
    }

    // 底部状态时间文案（相对时间，需随流逝自动刷新，用属性 + Timer 驱动）
    property string footerTimeText: ""
    function updateFooterTimeText() {
        if (root.status && root.status.generated_at) {
            if (root.stale) {
                root.footerTimeText = "数据可能过期 · 上次成功 " + root.fmtTime(root.status.generated_at)
            } else {
                root.footerTimeText = "更新于 " + root.fmtRelative(root.status.generated_at)
            }
        } else {
            root.footerTimeText = root.lastError ? "状态读取失败: " + root.lastError : "正在收集状态…"
        }
    }

    // 包名样例截断：单 token 无法断行，超长会溢出弹窗
    function truncateSamples(samples) {
        if (!samples || samples.length === 0) return ""
        const joined = samples.join(", ")
        if (joined.length <= 48) return joined
        let t = ""
        for (const p of samples) {
            const next = t ? t + ", " + p : p
            if (next.length > 48) break
            t = next
        }
        return t ? t + "…" : samples[0].slice(0, 47) + "…"
    }

    // ---- 弹窗详情模型：结构化 KPI（大字数值 + 可视化 + 明细行）----
    readonly property var detailSections: {
        const s = root.status
        const secs = []
        if (!s) return secs

        // 待更新：堆叠条（各源占比）+ 包名样例 + 缓存年龄
        if (s.updates) {
            const total = s.updates.total
            const srcKeys = ["repo", "aur", "flatpak"]
            const srcs = []
            for (const k of srcKeys) {
                const p = s.updates.per_source?.[k]
                if (!p || p.count <= 0) continue
                srcs.push({ key: k, count: p.count, status: p.status, samples: p.samples ?? [] })
            }
            const srcBars = srcs.map(x => ({
                label: x.key === "repo" ? "仓库" : x.key === "aur" ? "AUR" : "Flatpak",
                count: x.count,
                pct: total > 0 ? x.count / total : 0,
                color: x.key === "repo" ? Theme.primary
                    : (x.key === "aur" ? Theme.secondary : Theme.surfaceVariant)
            }))
            const srcLines = srcs.map(x => {
                const label = x.key === "repo" ? "仓库" : x.key === "aur" ? "AUR" : "Flatpak"
                // 源状态映射中文：ok 正常 / missing 缓存缺失 / 其他原样（罕见）
                const statusTxt = x.status === "ok" ? "正常"
                    : (x.status === "missing" ? "缓存缺失" : x.status)
                return {
                    label: label,
                    value: x.count + " 项 · " + statusTxt,
                    samples: root.truncateSamples(x.samples)
                }
            })
            if (s.updates.cache_age !== undefined && s.updates.cache_age !== null)
                srcLines.push({ label: "缓存", value: s.updates.cache_age + " 分钟前刷新" })
            secs.push({
                key: "updates", icon: "update", title: "待更新",
                value: String(total), unit: "个",
                valueColor: root.stateMeta.metaFor(total >= root.updatesRed ? "err" : (total >= root.updatesYellowClamped ? "warn" : "ok")).color,
                state: total >= root.updatesRed ? "err" : (total >= root.updatesYellowClamped ? "warn" : "ok"),
                barTitle: "更新来源", linesTitle: "仓库明细", lineIcon: "storage",
                bars: srcBars, lines: srcLines
            })
        }

        // 磁盘：环形进度 + / 与 /home 明细
        if (s.disk) {
            const maxPct = root.maxDiskPct
            const state = maxPct >= root.diskRed ? "err" : (maxPct >= root.diskYellowClamped ? "warn" : "ok")
            const rows = []
            let availMin = Infinity
            for (const key of ["root", "home"]) {
                const d = s.disk[key]
                if (!d) continue
                if (d.avail_gb !== undefined && d.avail_gb < availMin) availMin = d.avail_gb
                const label = key === "root" ? "/" : "/home"
                // 已用 = 总量 - 可用；有 total_gb 时给出完整三段信息
                let text
                if (d.total_gb !== undefined)
                    text = "已用 " + root.fmtGb(d.total_gb - (d.avail_gb ?? 0)) + " / 可用 " + root.fmtGb(d.avail_gb) + " · 共 " + root.fmtGb(d.total_gb)
                else
                    text = d.used_pct + "% · 可用 " + d.avail_gb + "G"
                rows.push({ label: label, pct: (d.used_pct ?? 0) / 100, text: text })
            }
            // 大数字 = 可用空间（与环心已用%互补，不重复；健康感知第一）
            const availTxt = isFinite(availMin) ? String(Math.round(availMin * 10) / 10) : "—"
            secs.push({
                key: "disk", icon: "hard_disk", title: "磁盘",
                value: availTxt, unit: "G",
                valueColor: root.stateMeta.metaFor(state).color,
                state: state,
                donut: {
                    pct: Math.min(1, Math.max(0, maxPct / 100)),
                    color: root.diskColor,
                    centerText: maxPct >= 0 ? String(maxPct) : "—",
                    centerUnit: "%",
                    centerCaption: "已用"
                },
                bars: rows, lines: [], lineIcon: "hard_disk"
            })
        }

        // 失败服务
        if (s.failed_units) {
            const units = s.failed_units
            const rows = units.length ? units.slice(0, 8).map(u => ({ label: "单元", value: u })) : [{ label: "状态", value: "全部服务正常" }]
            if (units.length > 8) rows.push({ label: "其他", value: "… 共 " + units.length + " 个失败单元" })
            secs.push({
                key: "failed", icon: "error", title: "失败服务",
                value: String(units.length), unit: "个",
                valueColor: root.stateMeta.metaFor(units.length === 0 ? "ok" : (units.length >= root.failedRed ? "err" : "warn")).color,
                state: units.length === 0 ? "ok" : (units.length >= root.failedRed ? "err" : "warn"),
                linesTitle: "失败单元", lineIcon: "error",
                bars: [], lines: rows
            })
        }

        // 快照
        if (s.snapshots) {
            const rows = []
            for (const key of ["root", "home"]) {
                const sn = s.snapshots[key]
                if (!sn) continue
                if (sn.error) {
                    rows.push({ label: key, value: "读取失败（" + sn.error + "）" })
                } else if (sn.newest_ts) {
                    rows.push({ label: key, value: sn.count + " 个 · 最近 " + root.fmtTime(sn.newest_ts)
                        + (sn.newest_desc ? " · " + sn.newest_desc : "") })
                } else {
                    rows.push({ label: key, value: "无快照" })
                }
            }
            const snapState = root.snapshotError ? "info"
                : (root.snapshotAgeHours !== null && root.snapshotAgeHours > root.snapshotStaleHours ? "warn" : "ok")
            secs.push({
                key: "snapshots", icon: "history", title: "快照",
                value: root.snapshotError ? "—" : (root.snapshotAgeHours !== null ? String(root.snapshotAgeHours) : "—"),
                unit: root.snapshotError ? "" : "h",
                valueColor: root.stateMeta.metaFor(snapState).color,
                state: snapState,
                linesTitle: "快照明细", lineIcon: "history",
                bars: [], lines: rows
            })
        }

        // 内存：环形进度（同磁盘视觉）+ 大数字可用 + 明细（内存/交换）
        if (s.memory) {
            const m = s.memory
            const state = m.used_pct >= root.memoryRed ? "err" : (m.used_pct >= root.memoryYellowClamped ? "warn" : "ok")
            const rows = []
            rows.push({ label: "内存", pct: (m.used_pct ?? 0) / 100, text: m.used_pct + "% · 可用 " + m.avail_gb + "G" })
            if (m.swap)
                rows.push({ label: "交换", pct: (m.swap.used_pct ?? 0) / 100, text: m.swap.used_pct + "% · 已用 " + m.swap.used_gb + "G" })
            secs.push({
                key: "memory", icon: "memory", title: "内存",
                value: m.avail_gb !== undefined ? String(m.avail_gb) : "—", unit: "G",
                valueColor: root.stateMeta.metaFor(state).color,
                state: state,
                donut: {
                    pct: Math.min(1, Math.max(0, (m.used_pct ?? 0) / 100)),
                    color: root.memoryColor,
                    centerText: m.used_pct !== undefined ? String(m.used_pct) : "—",
                    centerUnit: "%",
                    centerCaption: "已用"
                },
                bars: rows, lines: [], lineIcon: "memory"
            })
        }

        // 日志错误：24h 错误数 + 按服务聚合 top5 + 空状态
        if (s.journal_errors) {
            const je = s.journal_errors
            const total = je.total ?? 0
            const state = je.error ? "info" : (total >= root.journalRed ? "err" : (total >= root.journalYellowClamped ? "warn" : "ok"))
            const lines = []
            if (je.error) {
                lines.push({ label: "状态", value: "journal 读取失败" })
            } else if (total === 0) {
                lines.push({ label: "状态", value: "24 小时内无错误" })
            } else {
                for (const t of (je.top ?? []).slice(0, 5))
                    lines.push({ label: t.service, value: t.count + " 条" })
                if (total > 0) lines.push({ label: "合计", value: total + " 条（24 小时）" })
            }
            secs.push({
                key: "journal", icon: "report", title: "日志错误",
                value: je.error ? "—" : String(total), unit: je.error ? "" : "条",
                valueColor: root.stateMeta.metaFor(state).color,
                state: state,
                linesTitle: "错误来源 TOP5", lineIcon: "report",
                bars: [], lines: lines
            })
        }

        // 孤儿包：数量 + 包名 top8 + 空状态
        if (s.orphans) {
            const o = s.orphans
            const n = o.count ?? 0
            const state = o.error ? "info" : (n >= root.orphanRed ? "err" : (n >= root.orphanYellowClamped ? "warn" : "ok"))
            const lines = []
            if (o.error) {
                lines.push({ label: "状态", value: "pacman 查询失败" })
            } else if (n === 0) {
                lines.push({ label: "状态", value: "无孤儿包" })
            } else {
                for (const p of (o.packages ?? []).slice(0, 8))
                    lines.push({ label: "包", value: p })
                if (n > 8) lines.push({ label: "其他", value: "… 共 " + n + " 个" })
            }
            secs.push({
                key: "orphans", icon: "package", title: "孤儿包",
                value: String(n), unit: "个",
                valueColor: root.stateMeta.metaFor(state).color,
                state: state,
                linesTitle: "包列表", lineIcon: "package",
                bars: [], lines: lines
            })
        }

        return secs
    }

    // 环形进度（Canvas 画弧）：渐变发光弧（环心文字由 QML 叠层负责，抗锯齿更佳）
    component DonutRing: Canvas {
        id: ring
        property real pct: 0
        property color ringColor: Theme.primary
        property real lineWidth: 9

        // 画布需比弧大出发光余量（shadowBlur），否则光晕在矩形边缘被裁剪成"方形轮廓"
        readonly property real radius: (Math.min(width, height) - ring.lineWidth - 12) / 2

        // 分段弧颜色插值：起点亮色 → 状态色
        function lerpColor(c1, c2, t) {
            return Qt.rgba(
                c1.r + (c2.r - c1.r) * t,
                c1.g + (c2.g - c1.g) * t,
                c1.b + (c2.b - c1.b) * t,
                c1.a + (c2.a - c1.a) * t
            )
        }

        onPaint: {
            const ctx = ring.getContext("2d")
            ctx.clearRect(0, 0, ring.width, ring.height)
            const cx = ring.width / 2
            const cy = ring.height / 2

            ctx.lineWidth = ring.lineWidth
            ctx.lineCap = "round"

            // 轨道（细内侧高光：先画暗轨再画亮细环）
            ctx.strokeStyle = Theme.surfaceContainerHighest
            ctx.beginPath()
            ctx.arc(cx, cy, ring.radius, 0, Math.PI * 2)
            ctx.stroke()
            ctx.strokeStyle = Qt.alpha(Theme.surfaceText, 0.05)
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.arc(cx, cy, ring.radius, 0, Math.PI * 2)
            ctx.stroke()
            ctx.lineWidth = ring.lineWidth

            // 数值弧：从 12 点方向顺时针，分段渐变（起点亮 → 终点状态色）+ 柔和发光
            if (ring.pct > 0) {
                const bright = Qt.lighter(ring.ringColor, 1.35)
                const totalAngle = Math.PI * 2 * ring.pct
                const segs = Math.max(8, Math.round(totalAngle / (Math.PI / 36)))
                ctx.shadowColor = Qt.alpha(ring.ringColor, 0.55)
                // 6 = 余量上限：弧外缘距画布边 6px，光晕在边缘前衰减完，不会被裁剪成方形轮廓
                ctx.shadowBlur = 6
                for (let i = 0; i < segs; i++) {
                    const a0 = -Math.PI / 2 + totalAngle * i / segs
                    const a1 = -Math.PI / 2 + totalAngle * (i + 1) / segs
                    ctx.strokeStyle = ring.lerpColor(bright, ring.ringColor, i / (segs - 1))
                    ctx.beginPath()
                    ctx.arc(cx, cy, ring.radius, a0, a1)
                    ctx.stroke()
                }
                ctx.shadowBlur = 0
            }
        }

        onPctChanged: ring.requestPaint()
        onRingColorChanged: ring.requestPaint()
        onWidthChanged: ring.requestPaint()
        onHeightChanged: ring.requestPaint()
    }

    // 状态呼吸点（异常时脉冲，正常静止）
    component StatusDot: Rectangle {
        id: dot
        property color dotColor: Theme.success
        property bool pulsing: false

        width: 8
        height: 8
        radius: 4
        color: dot.dotColor

        SequentialAnimation {
            running: dot.pulsing && dot.visible
            loops: Animation.Infinite

            NumberAnimation { target: dot; property: "opacity"; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { target: dot; property: "opacity"; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
        }
    }

    // ---- 弹窗：大胶囊选择 + KPI 面板 + 主色动作 ----
    popoutContent: Component {
        // 根容器 Item：背景氛围层(z:0) + 内容层(z:1)
        // 背景层不能放进 PopoutComponent(Column) 内部——Positioner 子项禁止 anchors.fill，
        // 会破坏 implicitHeight 计算，导致弹窗只剩一个黑条
        Item {
            id: popoutRoot

            // PluginPopout 会注入 closePopout/parentPopout（onLoaded 检查 "closePopout" in item）
            property var closePopout: null
            property var parentPopout: null

            // 内容层高度（PluginPopout 用它计算弹窗高度）
            implicitHeight: popout.implicitHeight
            // 显式宽度：Loader 不会自动把宽度赋给 item，缺了它背景层 anchors.fill 全失效
            width: parent.width

            // ---- 内容层 ----
            PopoutComponent {
                id: popout
                width: parent.width
                z: 1
                closePopout: popoutRoot.closePopout
                parentPopout: popoutRoot.parentPopout
                // 标题栏自绘（并入图片背景层，系统 header 关闭避免顶部黑条）
                headerText: ""
                showCloseButton: false

                // 入场动画：淡入 + 上移 + 缩放（0.93→1，明显的"弹入浮现"感）
                opacity: 0
                transform: [
                    Translate { id: popoutShift; y: 16 },
                    Scale { id: popoutScale; xScale: 0.93; yScale: 0.93 }
                ]

                ParallelAnimation {
                    id: popoutAnim
                    NumberAnimation {
                        target: popout
                        property: "opacity"
                        to: 1
                        duration: 260
                        easing.type: Easing.OutCubic
                    }
                    NumberAnimation {
                        target: popoutShift
                        property: "y"
                        to: 0
                        duration: 300
                        easing.type: Easing.OutBack
                    }
                    NumberAnimation {
                        target: popoutScale
                        property: "xScale"
                        to: 1
                        duration: 340
                        easing.type: Easing.OutBack
                    }
                    NumberAnimation {
                        target: popoutScale
                        property: "yScale"
                        to: 1
                        duration: 340
                        easing.type: Easing.OutBack
                    }
                }

                // 背景图错峰淡入：内容先出现，图片随后浮现，层次更分明
                NumberAnimation {
                    id: bgImgFadeIn
                    target: bgImg
                    property: "opacity"
                    to: 0.5
                    duration: 420
                    easing.type: Easing.OutCubic
                }

                // 退出动画：淡出 + 微缩 + 下移（与入场呼应的"收回"感），结束后真正关闭弹窗
                SequentialAnimation {
                    id: popoutExitAnim
                    ParallelAnimation {
                        NumberAnimation {
                            target: popout
                            property: "opacity"
                            to: 0
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: popoutShift
                            property: "y"
                            to: 8
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: popoutScale
                            property: "xScale"
                            to: 0.95
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: popoutScale
                            property: "yScale"
                            to: 0.95
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                    }
                    onFinished: {
                        if (popoutRoot.closePopout) {
                            popoutRoot.closePopout()
                        }
                    }
                }

                Component.onCompleted: {
                    popoutAnim.start()
                    bgImgFadeIn.start()
                }

                // 弹窗内容组件只实例化一次（PluginPopout 的 Loader 复用），
                // onCompleted 只跑一次；退出动画把 opacity 归 0 后，再次打开
                // 时组件不重建、入场动画不重放 → 内容永远不可见（只剩容器深色）。
                // 因此每次弹窗变为可见时重放入场动画，把 opacity/位移/缩放拉回初态。
                Connections {
                    target: popoutRoot.parentPopout
                    function onShouldBeVisibleChanged() {
                        if (popoutRoot.parentPopout && popoutRoot.parentPopout.shouldBeVisible) {
                            popoutAnim.restart()
                            bgImgFadeIn.restart()
                        }
                    }
                }

                Column {
                width: parent.width
                spacing: Theme.spacingL
                z: 1

                // ---- 图片背景宿主：整窗背景图 + 暗色遮罩 + 内容浮层 ----
                // Rectangle 提供圆角裁剪（图片不溢出弹窗圆角），高度跟随内容
                Rectangle {
                    id: bgHost
                    width: parent.width
                    // 宿主高度跟随内容隐式高度，Positioner 布局正常
                    implicitHeight: contentCol.implicitHeight
                    height: contentCol.implicitHeight
                    radius: Theme.cornerRadius
                    clip: true
                    color: "transparent"

                    // 背景图：裁剪铺满，半透明（冷灰蓝冬日插画；可在设置面板换图）
                    Image {
id: bgImg
                         anchors.fill: parent
                         source: root.bgImageSource
                         // 配置图加载失败后回退默认图（避免空背景）
                         property bool fallbackActive: false
                         fillMode: Image.PreserveAspectCrop
                         smooth: true
                         // 初始 0：由入场动画 bgImgFadeIn 淡入到 0.5（错峰浮现）
                         opacity: 0
                         z: 0
                         // 图片加载失败（路径不存在、假后缀解码失败等）→ 回退默认冬日图。
                         // 只需检测到失败就回退；成功后保持 fallbackActive=false，
                         // 这样 later 配置改回无效也不再回退（避免 Fallback→成功→再次失败循环）。
                         onStatusChanged: {
                             if (bgImg.status === Image.Error) {
                                 if (bgImg.fallbackActive) return
                                 bgImg.fallbackActive = true
                                 bgImg.source = "file:///home/pang/.config/DankMaterialShell/plugins/dankmaintenance/bg-winter.png"
                             } else if (bgImg.status === Image.Ready) {
                                 bgImg.fallbackActive = false
                             }
                         }
                        // Ken Burns 效果：缩放 + 平移漂移循环（24s 一个往返），背景明显在"呼吸+流动"
                        transform: [
                            Translate { id: kbShiftX; x: -10 },
                            Translate { id: kbShiftY; y: -6 }
                        ]
                        SequentialAnimation on scale {
                            // 弹窗关闭（不可见）时停动画，避免空转浪费 GPU
                            running: popout.visible
                            loops: Animation.Infinite
                            NumberAnimation {
                                to: 1.0
                                duration: 12000
                                easing.type: Easing.InOutSine
                            }
                            NumberAnimation {
                                to: 1.15
                                duration: 12000
                                easing.type: Easing.InOutSine
                            }
                        }
                        SequentialAnimation {
                            running: popout.visible
                            loops: Animation.Infinite
                            NumberAnimation { target: kbShiftX; property: "x"; to: 10; duration: 12000; easing.type: Easing.InOutSine }
                            NumberAnimation { target: kbShiftX; property: "x"; to: -10; duration: 12000; easing.type: Easing.InOutSine }
                        }
                        SequentialAnimation {
                            running: popout.visible
                            loops: Animation.Infinite
                            NumberAnimation { target: kbShiftY; property: "y"; to: 6; duration: 12000; easing.type: Easing.InOutSine }
                            NumberAnimation { target: kbShiftY; property: "y"; to: -6; duration: 12000; easing.type: Easing.InOutSine }
                        }
                    }

                    // 暗角渐晕：四边轻微压暗，让内容区更聚焦（叠加在图片之上、内容之下）
                    Canvas {
                        anchors.fill: parent
                        antialiasing: true
                        z: 1
                        // 官方最佳实践：协获取绘制只按需重绘，降低静态背景的持续渲染负担
                        renderStrategy: Canvas.Cooperative
                        onPaint: {
                            const ctx = getContext("2d")
                            const w = width, h = height
                            const cx = w / 2, cy = h / 2
                            const r0 = Math.min(w, h) * 0.35
                            const r1 = Math.max(w, h) * 0.60
                            const g = ctx.createRadialGradient(cx, cy, r0, cx, cy, r1)
                            g.addColorStop(0, Qt.rgba(0, 0, 0, 0))
                            g.addColorStop(1, Qt.rgba(0, 0, 0, 0.6))
                            ctx.fillStyle = g
                            ctx.fillRect(0, 0, w, h)
                        }
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                    }

                    // 暗色遮罩：压低背景保证内容可读性
                    Rectangle {
                        anchors.fill: parent
                        visible: true
                        color: Qt.rgba(0, 0, 0, 0.42)
                        z: 1
                    }

                    // 内容浮层（原 Column 内容整体移入）
                    Column {
                        id: contentCol
                        width: parent.width
                        spacing: Theme.spacingL
                        z: 2

                        // ---- 标题栏：自绘（图片背景之上，替代系统 header 黑条）----
                        Item {
                            width: parent.width
                            height: 40

                            StyledText {
                                anchors.left: parent.left
                                // 避开弹窗圆角（cornerRadius 较大），标题不被裁剪
                                anchors.leftMargin: Theme.spacingL + 4
                                anchors.verticalCenter: parent.verticalCenter
                                text: "维护状态"
                                font.pixelSize: Theme.fontSizeLarge + 4
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                            }

                            Rectangle {
                                id: popCloseBtn
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingL
                                anchors.verticalCenter: parent.verticalCenter
                                width: 32
                                height: 32
                                radius: 16
                                color: popCloseArea.containsMouse ? Theme.errorHover : Qt.alpha(Theme.errorHover, 0)
                                scale: popCloseArea.pressed ? 0.86 : 1

                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.shorterDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }

                                Behavior on scale {
                                    SpringAnimation {
                                        spring: 4
                                        damping: 0.35
                                        mass: 1
                                    }
                                }

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "close"
                                    size: Theme.iconSize - 4
                                    color: popCloseArea.containsMouse ? Theme.error : Theme.surfaceText
                                }

                                MouseArea {
                                    id: popCloseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: {
                                        popoutExitAnim.start()
                                    }
                                }
                            }
                        }

// 胶囊切换时 KPI 内容淡入 + 轻微上移（解释内容刷新）
                ParallelAnimation {
                    id: kpiAnim
                    NumberAnimation { target: kpiRect; property: "opacity"; to: 1; duration: 180; easing.type: Easing.OutCubic }
                    NumberAnimation { target: kpiShift; property: "y"; to: 0; duration: 180; easing.type: Easing.OutCubic }
                }

                // 大数字微动画：切换胶囊时数字先缩小再弹回（轻盈的"落定"感）
                SequentialAnimation {
                    id: valuePop
                    NumberAnimation { target: valueText; property: "scale"; to: 0.86; duration: 90; easing.type: Easing.OutQuad }
                    NumberAnimation { target: valueText; property: "scale"; to: 1.0; duration: 220; easing.type: Easing.OutBack }
                }

                // ---- 大胶囊（单行横向滚动选择条：7 项横排，超出横向滚动）----
                Item {
                    width: parent.width
                    height: 46

                    ListView {
                        id: chipList
                        // 左右留边：胶囊不被弹窗圆角裁剪
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        height: 46
                        orientation: ListView.Horizontal
                        spacing: Theme.spacingS
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: root.chipsLoop
                        interactive: false

                        // 无限循环：初始定位到「中间份第一项」，弹窗打开始终从「待更新」对齐开始
                        // callLater 确保 delegate 布局完成后再定位
                        Component.onCompleted: {
                            Qt.callLater(() => chipList.positionViewAtIndex(root.chips.length, ListView.Beginning))
                        }

                        // 滚轮平滑滚动动画（流畅不干脆）
                        NumberAnimation {
                            id: chipScrollAnim
                            target: chipList
                            property: "contentX"
                            duration: 300
                            easing.type: Easing.OutCubic

                            // 动画自然结束 → 拉回中间份，保证下次滚动空间充足（无限循环）
                            onStopped: {
                                const u = chipList.contentWidth / 3
                                if (u <= 0) return
                                if (chipList.contentX < u) {
                                    chipList.contentX = chipList.contentX + u
                                } else if (chipList.contentX > 2 * u) {
                                    chipList.contentX = chipList.contentX - u
                                }
                            }
                        }

                        // 鼠标滚轮 → 平滑横向滚动
                        MouseArea {
                            id: chipWheelArea
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            // 胶囊行整行可点：让手型光标在整个胶囊条上生效
                            // （无此设置时上层 MouseArea 会拦截 hover，胶囊自身的手型不显示）
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onWheel: wheel => {
                                if (wheel.angleDelta.y !== 0) {
                                    // 先拉回中间份，保证 from/to 都在有效区间
                                    const u = chipList.contentWidth / 3
                                    if (u > 0) {
                                        if (chipList.contentX < u) {
                                            chipList.contentX = chipList.contentX + u
                                        } else if (chipList.contentX > 2 * u) {
                                            chipList.contentX = chipList.contentX - u
                                        }
                                    }
                                    chipScrollAnim.stop()
                                    chipScrollAnim.from = chipList.contentX
                                    chipScrollAnim.to = chipList.contentX - wheel.angleDelta.y
                                    chipScrollAnim.start()
                                    wheel.accepted = true
                                }
                            }
                        }

                        delegate: Rectangle {
                            id: chip
                            required property var modelData
                            required property int index

                            // 无限循环模型 3 份：真实序号 = index % 原列表长度
                            // 防御：chips 全被隐藏（长度 0）时除零产生 NaN，回退 0
                            readonly property int realIndex: root.chips.length > 0 ? (chip.index % root.chips.length) : 0
                            property bool selected: chip.realIndex === root.currentIndex
                            property bool hovered: chipMouse.containsMouse
                            property bool pressed: chipMouse.pressed

                            width: chipRow.implicitWidth + Theme.spacingL * 2 + Theme.spacingS
                            height: 46
                            radius: height / 2
                            // 选中实色主色强调；未选中半透明让图片背景透出
                            color: selected ? Theme.primary : Qt.alpha(Theme.surfaceVariant, 0.78)
                            // 选中描边：主色白微光，提升「选中」精致感
                            border.color: selected ? Qt.alpha(Theme.primaryText, 0.35) : "transparent"
                            border.width: 1

                            // 灵动反馈：按压缩小、松开弹簧回弹、切换时弹性脉冲
                            scale: (pressed && !chipPop.running) ? 0.90 : 1
                            Behavior on scale {
                                enabled: !chipPop.running
                                SpringAnimation {
                                    spring: 4.5
                                    damping: 0.28
                                    mass: 1
                                }
                            }

                            SequentialAnimation {
                                id: chipPop
                                NumberAnimation { target: chip; property: "scale"; to: 0.90; duration: 70; easing.type: Easing.OutQuad }
                                NumberAnimation { target: chip; property: "scale"; to: 1.05; duration: 160; easing.type: Easing.InOutQuad }
                                NumberAnimation { target: chip; property: "scale"; to: 1.0; duration: 200; easing.type: Easing.OutBack }
                            }

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Theme.standardEasing
                                }
                            }

                            // hover/pressed 覆盖层：按下明显加深（比 hover 更实），形成"压下去"的触感
                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: pressed
                                    ? (chip.selected ? Qt.alpha(Theme.primaryPressed, 0.85) : Qt.alpha(Theme.surfaceTextHover, 0.55))
                                    : (chip.hovered ? (chip.selected ? Theme.primaryHover : Qt.alpha(Theme.surfaceTextHover, 0.28)) : "transparent")

                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.shorterDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }
                            }

                            DankRipple {
                                id: chipRipple
                                cornerRadius: chip.radius
                                rippleColor: chip.selected ? Theme.primaryText : Theme.surfaceVariantText
                            }

                            Row {
                                id: chipRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingS

                                // 图标底块：活跃胶囊的图标有 Material 式圆底，非活跃透明
                                Rectangle {
                                    width: 30
                                    height: 30
                                    radius: 15
                                    color: chip.selected ? Qt.alpha(Theme.primaryText, 0.14) : "transparent"

                                    Behavior on color {
                                        ColorAnimation {
                                            duration: Theme.shorterDuration
                                            easing.type: Theme.standardEasing
                                        }
                                    }

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: chip.modelData.icon
                                        size: 17
                                        color: chip.selected ? Theme.primaryText : chip.modelData.color
                                    }
                                }

                                Column {
                                    spacing: 0

                                    StyledText {
                                        text: chip.modelData.title
                                        font.family: root.fontSmall
                                        font.pixelSize: 11
                                        font.weight: Font.Medium
                                        font.letterSpacing: 0.5
                                        color: chip.selected ? Theme.primaryText : Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        text: chip.modelData.value
                                        font.family: root.fontDisplay
                                        font.pixelSize: 22
                                        font.weight: Font.ExtraBold
                                        font.letterSpacing: -0.3
                                        font.features: [{ tag: "tnum" }]
                                        color: chip.selected ? Theme.primaryText : chip.modelData.color
                                    }
                                }
                            }

                            MouseArea {
                                id: chipMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: mouse => {
                                    chipRipple.trigger(mouse.x, mouse.y)
                                }
                                onClicked: {
                                    if (root.currentIndex !== chip.realIndex) {
                                        chipPop.start()
                                        root.currentIndex = chip.realIndex
                                        // 点击后滚回「中间份」对应位置，保证两侧都有可滚空间
                                        chipList.positionViewAtIndex(root.chips.length + chip.realIndex, ListView.Contain)
                                        kpiRect.opacity = 0
                                        kpiShift.y = 8
                                        kpiAnim.restart()
                                        valuePop.restart()
                                    } else {
                                        // 重复点击当前胶囊：轻弹一下，保留"有反应"的手感
                                        chipPop.start()
                                    }
                                }
                            }
                        }
                    }

                    // 两端渐隐已移除：胶囊全部完整可见（早前版本加过左右暗色渐隐带，
                    // 视觉上像"阴影"被用户否决，直接去掉保持干净）
                }

                // ---- 全空健康态：所有指标正常时轻量呈现「一切正常 ✓」 ----
                // 弹窗胶囊行下方一条绿色横幅，一眼确认无待办/无异常；任一指标越黄即隐藏
                Rectangle {
                    id: healthyBanner
                    width: parent.width
                    height: 30
                    radius: 15
                    visible: root.allHealthy
                    color: Qt.alpha(Theme.success, 0.14)
                    border.color: Qt.alpha(Theme.success, 0.35)
                    border.width: 1

                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check_circle"
                            size: 14
                            color: Theme.success
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "一切正常 — 待更新、磁盘、内存、日志、服务、孤儿包均在安全区间"
                            font.family: root.fontSmall
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.3
                            color: Theme.success
                        }
                    }
                }

                // ---- 当前胶囊的 KPI 面板 ----
                Rectangle {
                    id: kpiRect
                    width: parent.width
                    // Rectangle 无隐式高度：显式绑定内容高度（否则在 Column 中占 0 高不可见）
                    height: panel.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    // 半透明：让深空极光背景透出（可读性由深色玻璃质感保证）
                    color: Qt.alpha(Theme.surfaceContainerHigh, 0.5)
                    border.color: Theme.withAlpha(Theme.surfaceText, 0.06)
                    border.width: 1
                    // 顶部状态色极淡渐变：面板从平铺变有光源层次，单调感消解
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: Qt.alpha(root.stateMeta.metaFor(panel.section?.state ?? "info").color, 0.09)
                        }
                        GradientStop {
                            position: 1.0
                            color: Qt.alpha(root.stateMeta.metaFor(panel.section?.state ?? "info").color, 0.01)
                        }
                    }

                    transform: Translate { id: kpiShift }

                    Column {
                        id: panel
                        width: parent.width
                        padding: Theme.spacingL
                        spacing: Theme.spacingL

                        // 当前 section（随选中胶囊动态变化，绑定自动更新）
                        // 按 key 查找：与 chips 的 show 过滤下标解耦，避免胶囊与详情面板错位
                        // 找不到（该数据源当前缺失、detailSections 无对应段）时回退到空→面板显示占位
                        readonly property var section: root.chips[root.currentIndex] ? (root.detailSections.find(s => s.key === root.chips[root.currentIndex].key) ?? null) : (root.detailSections[root.currentIndex] ?? null)

                        // 顶部：大数字（tabular 等宽 + 单位拆分）+ 标题 + 状态强调条 + 状态徽章
                        Column {
                            // parent 有 padding，width 需扣除左右 padding 否则右缘溢出
                            width: parent.width - parent.padding * 2
                            spacing: Theme.spacingXS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                Column {
                                    spacing: 0

                                    // 数字行：52px 状态色大数字 + 小单位
                                    Row {
                                        spacing: Theme.spacingS

                                        StyledText {
                                            id: valueText
                                            text: panel.section ? panel.section.value : "—"
                                            font.family: root.fontDisplay
                                            font.pixelSize: 52
                                            font.weight: Font.ExtraBold
                                            font.letterSpacing: -1
                                            font.features: [{ tag: "tnum" }]
                                            color: panel.section ? panel.section.valueColor : Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            anchors.baseline: valueText.baseline
                                            text: panel.section ? (panel.section.unit || "") : ""
                                            font.family: root.fontSmall
                                            font.pixelSize: 15
                                            font.weight: Font.DemiBold
                                            font.letterSpacing: 0.3
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    // 标题：紧凑 + 字距
                                    StyledText {
                                        text: panel.section ? panel.section.title : "加载中"
                                        font.family: root.fontSmall
                                        font.pixelSize: 13
                                        font.weight: Font.Medium
                                        font.letterSpacing: 0.4
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                Item { width: 1; height: 1 }

                                // 状态徽章：状态色胶囊（alpha 底 + 呼吸点 + 字距文字）
                                Rectangle {
                                    height: 22
                                    radius: 11
                                    width: badgeRow.implicitWidth + Theme.spacingL
                                    color: Qt.alpha(root.stateMeta.metaFor(panel.section?.state ?? "info").color, 0.22)

                                    Row {
                                        id: badgeRow
                                        anchors.centerIn: parent
                                        leftPadding: Theme.spacingM
                                        rightPadding: Theme.spacingM
                                        spacing: Theme.spacingXS

                                        StatusDot {
                                            anchors.verticalCenter: parent.verticalCenter
                                            dotColor: root.stateMeta.metaFor(panel.section?.state ?? "info").color
                                            pulsing: panel.section ? panel.section.state !== "ok" : false
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.stateMeta.metaFor(panel.section?.state ?? "info").text
                                            font.family: root.fontSmall
                                            font.pixelSize: 10
                                            font.weight: Font.DemiBold
                                            font.letterSpacing: 0.8
                                            color: root.stateMeta.metaFor(panel.section?.state ?? "info").color
                                        }
                                    }
                                }
                            }

                            // 状态强调条：3px 状态色短条，一眼健康度的视觉锚点
                            Rectangle {
                                width: 28
                                height: 3
                                radius: 1.5
                                color: panel.section ? root.stateMeta.metaFor(panel.section.state).color : Theme.surfaceContainerHighest
                            }
                        }

                        // 可视化 A：环形进度（磁盘）
                        Row {
                            width: parent.width
                            spacing: Theme.spacingXL
                            visible: !!panel.section?.donut

                            // 环 + 环心 QML 文字叠层（Canvas fillText 像素化，改 QML Text 抗锯齿佳）
                            // 104 = 92 弧 + 发光余量，弧外缘距画布边 10.5px ≥ shadowBlur 10，光晕不被裁剪
                            Item {
                                width: 104
                                height: 104

                                // 环外圈刻度：12 个极淡圆点，表盘刻度感（丰富视觉层次）
                                Repeater {
                                    model: 12

                                    Rectangle {
                                        readonly property real a: (index * 30 - 90) * Math.PI / 180
                                        x: parent.width / 2 + Math.cos(a) * 47 - 1
                                        y: parent.height / 2 + Math.sin(a) * 47 - 1
                                        width: 2
                                        height: 2
                                        radius: 1
                                        color: Qt.alpha(Theme.surfaceVariantText, 0.22)
                                    }
                                }

                                DonutRing {
                                    anchors.fill: parent
                                    pct: panel.section?.donut?.pct ?? 0
                                    ringColor: panel.section?.donut?.color ?? Theme.primary
                                }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 0

                                    Row {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        spacing: Theme.spacingXS

                                        StyledText {
                                            id: ringValueText
                                            text: panel.section?.donut?.centerText ?? ""
                                            font.family: root.fontDisplay
                                            font.pixelSize: 24
                                            font.weight: Font.ExtraBold
                                            font.letterSpacing: -0.5
                                            font.features: [{ tag: "tnum" }]
                                            color: panel.section?.valueColor ?? Theme.surfaceText
                                        }

                                        StyledText {
                                            anchors.baseline: ringValueText.baseline
                                            text: panel.section?.donut?.centerUnit ?? ""
                                            font.family: root.fontSmall
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: panel.section?.donut?.centerCaption ?? ""
                                        font.family: root.fontSmall
                                        font.pixelSize: 10
                                        font.weight: Font.Medium
                                        font.letterSpacing: 0.3
                                        color: Qt.alpha(Theme.surfaceVariantText, 0.8)
                                    }
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                Repeater {
                                    model: panel.section?.bars ?? []

                                    delegate: Row {
                                        width: 190
                                        spacing: Theme.spacingS

                                        StyledText {
                                            width: 44
                                            text: modelData.label
                                            font.family: root.fontSmall
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 70
                                            height: 5
                                            radius: 2.5
                                            color: Theme.surfaceContainerHighest

                                            Rectangle {
                                                width: parent.width * modelData.pct
                                                height: parent.height
                                                radius: parent.radius
                                                color: panel.section.valueColor
                                            }
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.text
                                            font.family: root.fontSmall
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.features: [{ tag: "tnum" }]
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        // 可视化 B：比例堆叠条（待更新各源占比）
                        Column {
                            // parent 有 padding，width 需扣除左右 padding 否则右缘溢出
                            width: parent.width - parent.padding * 2
                            spacing: Theme.spacingS
                            visible: !panel.section?.donut && (panel.section?.bars?.length ?? 0) > 0

                            // 区块微标题：分区感（小字 + 字距 + 半透明）
                            StyledText {
                                text: panel.section?.barTitle ?? "使用分布"
                                font.family: root.fontSmall
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                font.letterSpacing: 1.2
                                color: Qt.alpha(Theme.surfaceVariantText, 0.7)
                            }

                            Rectangle {
                                width: parent.width
                                height: 10
                                radius: 5
                                color: Theme.surfaceContainerHighest
                                clip: true

                                Row {
                                    width: parent.width
                                    height: parent.height

                                    Repeater {
                                        model: panel.section?.bars ?? []

                                        delegate: Rectangle {
                                            // 分段外包：左右留 1.5px 间距形成分段感
                                            width: parent.width * modelData.pct
                                            height: parent.height
                                            color: "transparent"

                                            Behavior on width {
                                                NumberAnimation {
                                                    duration: Theme.shortDuration
                                                    easing.type: Theme.standardEasing
                                                }
                                            }

                                            Rectangle {
                                                anchors.fill: parent
                                                anchors.leftMargin: 1.5
                                                anchors.rightMargin: 1.5
                                                color: modelData.color
                                            }
                                        }
                                    }
                                }
                            }

                            Row {
                                width: parent.width
                                spacing: Theme.spacingL

                                Repeater {
                                    model: panel.section?.bars ?? []

                                    delegate: Row {
                                        width: 118
                                        spacing: Theme.spacingXS

                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 6
                                            height: 6
                                            radius: 3
                                            color: modelData.color
                                        }

                                        StyledText {
                                            text: modelData.label
                                            font.family: root.fontSmall
                                            font.pixelSize: 11
                                            font.letterSpacing: 0.3
                                            color: Theme.surfaceVariantText
                                        }

                                        Item { width: 1; height: 1 }

                                        StyledText {
                                            text: String(modelData.count)
                                            font.family: root.fontDisplay
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                            font.features: [{ tag: "tnum" }]
                                            color: Theme.surfaceText
                                        }
                                    }
                                }
                            }
                        }

                        // 明细行（结构化：label 列 + 值；超长时面板内部滚动，弹窗高度封顶）
                        Column {
                            width: parent.width - parent.padding * 2
                            spacing: Theme.spacingS
                            visible: (panel.section?.lines?.length ?? 0) > 0

                            // 区块微标题
                            StyledText {
                                text: panel.section?.linesTitle ?? "详情"
                                font.family: root.fontSmall
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                font.letterSpacing: 1.2
                                color: Qt.alpha(Theme.surfaceVariantText, 0.7)
                            }

                            Flickable {
                                width: parent.width
                                height: Math.min(linesColumn.implicitHeight, root.maxLinesHeight)
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                interactive: linesColumn.implicitHeight > root.maxLinesHeight
                                contentHeight: linesColumn.implicitHeight

                                Column {
                                    id: linesColumn
                                    width: parent.width
                                    spacing: 0

                                    Repeater {
                                        model: panel.section?.lines ?? []

                                        delegate: Column {
                                            width: parent.width
                                            spacing: 0

                                            Row {
                                                width: parent.width
                                                spacing: Theme.spacingS

                                                // 行图标：打破纯文字行，区分数据族
                                                DankIcon {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    name: panel.section?.lineIcon ?? "info"
                                                    size: 13
                                                    color: Qt.alpha(Theme.surfaceVariantText, 0.55)
                                                }

                                                // StyledText 默认 WordWrap 会吞掉 elide，长服务名需显式 NoWrap
                                                StyledText {
                                                    width: 108
                                                    text: modelData.label || ""
                                                    font.family: root.fontSmall
                                                    font.pixelSize: 11
                                                    font.weight: Font.Medium
                                                    font.letterSpacing: 0.4
                                                    color: Theme.surfaceText
                                                    wrapMode: Text.NoWrap
                                                    elide: Text.ElideRight
                                                    // 复杂插画背景下保证可读：轻描边（QtRendering 下 style 才生效）
                                                }

                                                StyledText {
                                                    width: parent.width - 108 - Theme.spacingS * 2 - 13
                                                    text: modelData.value || ""
                                                    font.family: root.fontSmall
                                                    font.pixelSize: 11
                                                    font.letterSpacing: 0.2
                                                    lineHeight: 1.5
                                                    color: Theme.surfaceVariantText
                                                    wrapMode: Text.WordWrap
                                                    font.features: [{ tag: "tnum" }]
                                                }
                                            }

                                            // 包名样例：等宽小字缩进，次要的次要
                                            StyledText {
                                                width: parent.width
                                                visible: !!modelData.samples
                                                text: modelData.samples || ""
                                                leftPadding: 13 + Theme.spacingS + 108 + Theme.spacingS
                                                isMonospace: true
                                                font.pixelSize: 10
                                                font.letterSpacing: 0.2
                                                lineHeight: 1.4
                                                color: Qt.alpha(Theme.surfaceVariantText, 0.75)
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

// ---- 底部：细分隔线 + 状态时间 + 主色动作 ----
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.surfaceContainerHighest
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS
                    anchors.horizontalCenter: parent.horizontalCenter

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - actionButton.width - (retryButton.visible ? retryButton.width + Theme.spacingS : 0) - Theme.spacingS
                        spacing: Theme.spacingXS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "schedule"
                            size: 11
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            id: footerTime
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 11 - Theme.spacingXS
                            text: root.footerTimeText
                            isMonospace: true
                            font.family: root.fontSmall
                            font.pixelSize: Theme.fontSizeTiny
                            font.letterSpacing: 0.4
                            color: root.stale ? Theme.warning : Theme.surfaceVariantText
                            elide: Text.ElideRight
                            // 时间刷新时闪一下，让自动更新肉眼可见
                            opacity: 1
                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }

                        // 相对时间随流逝刷新：每分钟重算一次 + 状态更新后立即重算
                        Timer {
                            id: footerTimeRefresh
                            interval: 60000
                            repeat: true
                            running: popout.visible
                            triggeredOnStart: true
                            onTriggered: {
                                root.updateFooterTimeText()
                                // 闪烁提示：压暗再恢复
                                footerTimeFlicker.start()
                            }
                        }

                        SequentialAnimation {
                            id: footerTimeFlicker
                            running: false
                            NumberAnimation {
                                target: footerTime
                                property: "opacity"
                                to: 0.4
                                duration: 120
                            }
                            NumberAnimation {
                                target: footerTime
                                property: "opacity"
                                to: 1
                                duration: 180
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    // 采集失败重试（stale 或失败状态下出现）
                    Rectangle {
                        id: retryButton
                        width: retryRow.implicitWidth + Theme.spacingL
                        height: 24
                        radius: height / 2
                        visible: root.stale || !!root.lastError
                        color: retryMouse.containsMouse ? Theme.surfaceContainerHighest : "transparent"
                        scale: retryMouse.pressed ? 0.92 : 1

                        Behavior on scale {
                            SpringAnimation {
                                spring: 4
                                damping: 0.32
                                mass: 1
                            }
                        }

                        Row {
                            id: retryRow
                            anchors.centerIn: parent
                            spacing: 4

                            DankIcon {
                                id: retryIcon
                                anchors.verticalCenter: parent.verticalCenter
                                name: "refresh"
                                size: 12
                                color: Theme.surfaceVariantText
                                // hover 时图标旋转 90°，暗示"重新加载"（再 hover 继续转，带方向感）
                                transform: Rotation {
                                    id: retryIconRot
                                    angle: 0
                                    Behavior on angle {
                                        NumberAnimation {
                                            duration: 260
                                            easing.type: Easing.OutCubic
                                        }
                                    }
                                }
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "重试"
                                font.family: root.fontSmall
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                font.letterSpacing: 0.3
                                color: Theme.surfaceVariantText
                            }
                        }

                        MouseArea {
                            id: retryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: retryIconRot.angle += 90
                            onClicked: root.refreshStatus()
                        }
                    }

                    // 唯一动作：打开维护菜单（纯导航入口，执行权留在 term-menu）
                    Rectangle {
                        id: actionButton
                        width: actionRow.implicitWidth + Theme.spacingL * 2
                        height: 38
                        radius: height / 2
                        // 半透明玻璃质感：让图片背景透出，hover 增亮，比纯色块更融于背景
                        color: actionMouse.containsMouse
                            ? Qt.alpha(Theme.primaryHover, 0.9)
                            : Qt.alpha(Theme.primary, 0.72)
                        border.color: Qt.alpha(Theme.primaryText, 0.28)
                        border.width: 1
                        scale: actionMouse.pressed ? 0.94 : 1

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.shorterDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Behavior on scale {
                            SpringAnimation {
                                spring: 4
                                damping: 0.32
                                mass: 1
                            }
                        }

                        Row {
                            id: actionRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            DankIcon {
                                id: actionIcon
                                anchors.verticalCenter: parent.verticalCenter
                                name: "terminal"
                                size: 16
                                color: Theme.primaryText
                                // hover 时图标轻微放大，配合按钮上浮，点击前奏感更强
                                scale: actionMouse.containsMouse ? 1.12 : 1
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: Theme.shorterDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "维护菜单"
                                color: Theme.primaryText
                                font.family: root.fontSmall
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                                font.letterSpacing: 0.4
                            }
                        }

                        MouseArea {
                            id: actionMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
onClicked: {
                                    // 与 niri keybind Mod+Shift+C 相同的启动命令
                                    Quickshell.execDetached([
                                        "kitty", "--class=term-menu",
                                        "--override", "initial_window_width=1600",
                                        "--override", "initial_window_height=1000",
                                        "-e", "/home/pang/scripts/maintenance/term-menu"
])
                                    popoutExitAnim.start()
                                }
                        }
}
                    }
                    } // contentCol

                    // ---- 刷新反馈 toast：重试/自动刷新后轻提示，几秒自动消失 ----
                    // 注意：放在 bgHost（Rectangle，非 Positioner）内、contentCol 之外，
                    // anchors 在此层合法，不会破坏 implicitHeight 计算
                    Rectangle {
                        id: refreshToast
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Theme.spacingS
                        height: 26
                        radius: 13
                        width: toastRow.implicitWidth + Theme.spacingXL
                        visible: root.refreshToastActive
                        opacity: root.refreshToastActive ? 1 : 0
                        // 半透明深色底：与暗角背景融合，不抢内容
                        color: Qt.alpha(Theme.surfaceContainer, 0.85)
                        border.color: Qt.alpha(Theme.surfaceText, 0.12)
                        border.width: 1
                        z: 10

                        Behavior on opacity {
                            NumberAnimation { duration: 180; easing.type: Theme.standardEasing }
                        }

                        Row {
                            id: toastRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS
                            leftPadding: Theme.spacingS
                            rightPadding: Theme.spacingS

                            DankIcon {
                                id: toastIcon
                                anchors.verticalCenter: parent.verticalCenter
                                name: refreshToastKind === "ok" ? "check" : (refreshToastKind === "warn" ? "warning" : "sync")
                                size: 12
                                color: refreshToastKind === "ok" ? Theme.success
                                    : (refreshToastKind === "warn" ? Theme.warning : Theme.surfaceVariantText)
                            }

                            StyledText {
                                id: toastText
                                anchors.verticalCenter: parent.verticalCenter
                                text: refreshToastText
                                font.family: root.fontSmall
                                font.pixelSize: 10
                                font.weight: Font.Medium
                                font.letterSpacing: 0.3
                                color: Theme.surfaceText
                            }
                        }
                    }
                } // bgHost
                } // Column
            } // PopoutComponent
        } // popoutRoot Item
    } // Component

    popoutWidth: 560
    popoutHeight: 460
}
