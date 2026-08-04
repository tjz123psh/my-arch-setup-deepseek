import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.FileBrowser

PluginSettings {
    id: root
    pluginId: "dankmaintenance"

    StyledText {
        width: parent.width
        text: "维护状态"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "顶栏图标点击查看：待更新、磁盘、失败服务、快照、内存、日志错误、孤儿包。数据来自 checkallupdates 缓存与系统只读命令，不执行任何维护操作。"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "pollInterval"
        label: "轮询间隔"
        description: "多久重新收集一次状态（秒）。"
        defaultValue: 300
        minimum: 60
        maximum: 900
        unit: "秒"
    }

    SliderSetting {
        settingKey: "updatesYellow"
        label: "更新黄色阈值"
        description: "待更新数达到该值时图标变黄。"
        defaultValue: 5
        minimum: 1
        maximum: 100
    }

    SliderSetting {
        settingKey: "updatesRed"
        label: "更新红色阈值"
        description: "待更新数达到该值时图标变红。"
        defaultValue: 50
        minimum: 10
        maximum: 300
    }

    SliderSetting {
        settingKey: "diskYellow"
        label: "磁盘黄色阈值"
        description: "使用率超过该百分比时图标变黄。"
        defaultValue: 70
        minimum: 40
        maximum: 95
        unit: "%"
    }

    SliderSetting {
        settingKey: "diskRed"
        label: "磁盘红色阈值"
        description: "使用率超过该百分比时图标变红。"
        defaultValue: 90
        minimum: 60
        maximum: 99
        unit: "%"
    }

    SliderSetting {
        settingKey: "failedRed"
        label: "失败服务红色阈值"
        description: "失败单元数达到该值时图标变红（低于则为黄）。"
        defaultValue: 3
        minimum: 1
        maximum: 10
    }

    SliderSetting {
        settingKey: "snapshotStaleHours"
        label: "快照过期小时数"
        description: "距最近快照超过该小时数时图标变黄。"
        defaultValue: 48
        minimum: 12
        maximum: 168
        unit: "小时"
    }

    SliderSetting {
        settingKey: "memoryYellow"
        label: "内存黄色阈值"
        description: "内存使用率超过该百分比时图标变黄。"
        defaultValue: 70
        minimum: 40
        maximum: 95
        unit: "%"
    }

    SliderSetting {
        settingKey: "memoryRed"
        label: "内存红色阈值"
        description: "内存使用率超过该百分比时图标变红。"
        defaultValue: 90
        minimum: 60
        maximum: 99
        unit: "%"
    }

    SliderSetting {
        settingKey: "journalYellow"
        label: "日志错误黄色阈值"
        description: "24 小时内错误条数达到该值时图标变黄。"
        defaultValue: 5
        minimum: 1
        maximum: 100
        unit: "条"
    }

    SliderSetting {
        settingKey: "journalRed"
        label: "日志错误红色阈值"
        description: "24 小时内错误条数达到该值时图标变红。"
        defaultValue: 50
        minimum: 10
        maximum: 500
        unit: "条"
    }

    SliderSetting {
        settingKey: "orphanYellow"
        label: "孤儿包黄色阈值"
        description: "孤儿包数量达到该值时图标变黄。"
        defaultValue: 1
        minimum: 1
        maximum: 20
        unit: "个"
    }

    SliderSetting {
        settingKey: "orphanRed"
        label: "孤儿包红色阈值"
        description: "孤儿包数量达到该值时图标变红。"
        defaultValue: 20
        minimum: 5
        maximum: 100
        unit: "个"
    }

    StyledText {
        width: parent.width
        text: "胶囊显示"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "showUpdatesChip"
        label: "显示待更新胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showDiskChip"
        label: "显示磁盘胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showFailedChip"
        label: "显示失败服务胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showSnapshotChip"
        label: "显示快照胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showMemoryChip"
        label: "显示内存胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showJournalChip"
        label: "显示日志错误胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

ToggleSetting {
        settingKey: "showOrphanChip"
        label: "显示孤儿包胶囊"
        description: "关闭后该胶囊从弹窗隐藏，也不参与顶栏图标颜色聚合。"
        defaultValue: true
    }

    // ---- 背景图 ----
    StringSetting {
        settingKey: "backgroundImage"
        label: "弹窗背景图路径"
        description: "填写图片绝对路径（如 file:///home/user/图片/bg.png 或 /home/user/图片/bg.png）。留空使用默认冬日雪景图。加载失败会自动回退默认图。"
        placeholder: "file:///home/pang/.config/DankMaterialShell/plugins/dankmaintenance/bg-winter.png"
        defaultValue: "file:///home/pang/.config/DankMaterialShell/plugins/dankmaintenance/bg-winter.png"
    }

    DankButton {
        id: bgBrowseButton
        iconName: "folder_open"
        text: "选择背景图…"
        width: parent.width
        onClicked: bgImageBrowser.open()
    }

    // 文件选择器：独立顶层浮窗（parentModal 空），选完写回 backgroundImage 配置
    FileBrowserModal {
        id: bgImageBrowser
        visible: false
        browserTitle: "选择弹窗背景图"
        browserIcon: "image"
        browserType: "wallpaper"
        showHiddenFiles: false
        fileExtensions: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.gif"]
        onFileSelected: path => {
            const raw = path.startsWith("file://") ? path.slice(7) : path
            bgImageTypeProbe.pendingPath = path
            // 真实类型校验：防止假后缀（内容为 JPEG 却叫 .png）导致 Quickshell 解码失败、弹窗背景黑屏
            bgImageTypeProbe.command = ["file", "-b", "--mime-type", raw]
            bgImageTypeProbe.running = true
        }
    }

    // 后台探测选中文件的真实 MIME 类型（异步，通过后才保存配置并关闭选择器）
    Process {
        id: bgImageTypeProbe
        property string pendingPath: ""
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const mime = text.trim()
                const isImage = mime.startsWith("image/")
                // 扩展名 ↔ mime 一致性校验：JPEG 内容却叫 .png 会被 Quickshell 按扩展名解码失败
                // → 弹窗背景黑屏。mime 是 image/* 且扩展名与 mime 匹配才接受。
                const raw = bgImageTypeProbe.pendingPath.startsWith("file://")
                    ? bgImageTypeProbe.pendingPath.slice(7) : bgImageTypeProbe.pendingPath
                const lower = raw.toLowerCase()
                const extMatch = (mime === "image/png" && lower.endsWith(".png"))
                    || ((mime === "image/jpeg" || mime === "image/jpg") && (lower.endsWith(".jpg") || lower.endsWith(".jpeg")))
                    || (mime === "image/webp" && lower.endsWith(".webp"))
                    || (mime === "image/bmp" && lower.endsWith(".bmp"))
                    || (mime === "image/gif" && lower.endsWith(".gif"))
                if (isImage && extMatch && bgImageTypeProbe.pendingPath !== "") {
                    root.saveValue("backgroundImage", bgImageTypeProbe.pendingPath)
                    bgImageBrowser.close()
                }
                bgImageTypeProbe.pendingPath = ""
                // 非图片或扩展名/内容不符：不落盘，选择器保持打开，用户可重新选
            }
        }
    }
}
