import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ---- 运行时状态 ----
    property bool isRecording: false
    property string elapsed: ""
    property string tooltipText: ""
    // 防连点：1.5s 内忽略重复点击（双击会重复 execDetached / 重复拉起 slurp）
    property bool actionPending: false
    // 模式菜单项：无论状态都显示（录制中前置"停止录制"，模式项置灰防误触）
    property var modeItems: [
        { icon: "fullscreen", label: "全屏录制", args: ["start", "-f"], danger: false },
        { icon: "crop", label: "区域录制", args: ["start", "-r"], danger: false },
        { icon: "gif_box", label: "录制 GIF (区域)", args: ["start", "-g"], danger: false },
        { icon: "settings", label: "设置…", args: ["settings"], danger: false }
    ]
    // 轮询间隔（毫秒），可在设置里调整
    property int pollInterval: (pluginData.pollInterval || 1) * 1000

    layerNamespacePlugin: "shorin-screenrec"

    // 解析 status-json 输出
    function refreshStatus() {
        Proc.runCommand("shorinScreenrec.status", ["shorin-screenrec-menu", "status-json"], (stdout, exitCode) => {
            if (exitCode !== 0 || !stdout || stdout.trim().length === 0)
                return
            try {
                const obj = JSON.parse(stdout.trim())
                root.isRecording = (obj.class === "recording")
                // text 形如 "⏺00:12"，剥离非数字/冒号字符得到时长
                root.elapsed = (obj.text || "").replace(/[^0-9:]/g, "")
                root.tooltipText = obj.tooltip || ""
            } catch (e) {
                console.warn("shorinScreenrec: JSON 解析失败:", e, stdout)
            }
        }, 0)
    }

    function runRec(args) {
        if (root.actionPending) return
        root.actionPending = true
        Quickshell.execDetached(["shorin-screenrec-menu"].concat(args))
        // 触发操作后稍延迟刷新，让状态文件写入完成
        refreshDebounce.restart()
        actionPendingReset.restart()
    }

    Component.onCompleted: refreshStatus()

    Timer {
        interval: root.pollInterval
        running: true
        repeat: true
        onTriggered: root.refreshStatus()
    }

    // 用户执行开始/停止后短延迟再刷新
    Timer {
        id: refreshDebounce
        interval: 350
        repeat: false
        onTriggered: root.refreshStatus()
    }

    Timer {
        id: actionPendingReset
        interval: 1500
        repeat: false
        onTriggered: root.actionPending = false
    }

    // 右键强制停止
    pillRightClickAction: () => {
        root.runRec(["stop"])
    }

    // ---- 水平栏（顶/底部）药丸 ----
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined

            // 录制中：脉冲红点；空闲：录制图标
            Item {
                width: root.iconSize
                height: root.iconSize
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    visible: !root.isRecording
                    name: "screen_record"
                    size: root.iconSize
                    color: Theme.surfaceText
                }

                Rectangle {
                    id: recDot
                    anchors.centerIn: parent
                    visible: root.isRecording
                    width: root.iconSize * 0.6
                    height: width
                    radius: width / 2
                    color: Theme.error

                    SequentialAnimation on opacity {
                        running: root.isRecording
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
            }

            StyledText {
                visible: root.isRecording && root.elapsed.length > 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.elapsed
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
                font.family: "Fira Code"
            }
        }
    }

    // ---- 垂直栏（左/右侧）药丸 ----
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined

            Item {
                width: root.iconSize
                height: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    anchors.centerIn: parent
                    visible: !root.isRecording
                    name: "screen_record"
                    size: root.iconSize
                    color: Theme.surfaceText
                }

                Rectangle {
                    anchors.centerIn: parent
                    visible: root.isRecording
                    width: root.iconSize * 0.6
                    height: width
                    radius: width / 2
                    color: Theme.error

                    SequentialAnimation on opacity {
                        running: root.isRecording
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
            }
        }
    }

    // ---- 点击弹出菜单 ----
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: root.isRecording ? "正在录制" : "屏幕录制"
            detailsText: root.isRecording ? (root.elapsed.length ? ("已用时 " + root.elapsed) : "录制进行中") : "选择录制模式"
            showCloseButton: true
            // 弹出瞬间立即刷新状态，消除轮询滞后（≤1s）导致的旧状态显示
            Component.onCompleted: root.refreshStatus()

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // 无论状态都显示完整菜单（全屏/区域/GIF/设置）；
                // 录制中额外在顶部加"停止录制"，模式项置灰防误触
                Repeater {
                    model: root.isRecording
                        ? [{ icon: "stop_circle", label: "停止录制", args: ["stop"], danger: true }].concat(root.modeItems)
                        : root.modeItems

                    delegate: StyledRect {
                        width: parent.width
                        height: 44
                        radius: Theme.cornerRadius
                        opacity: root.isRecording && !modelData.danger ? 0.45 : 1.0
                        color: rowMouse.containsMouse
                            ? (modelData.danger ? Theme.errorHover : Theme.surfaceContainerHighest)
                            : Theme.surfaceContainerHigh

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingM

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: modelData.icon
                                size: Theme.iconSize
                                color: modelData.danger ? Theme.error : Theme.surfaceText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: modelData.danger ? Theme.error : Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // 录制中模式项置灰不可点（防误触），"停止录制"始终可点
                            enabled: modelData.danger || !root.isRecording
                            onClicked: {
                                root.runRec(modelData.args)
                                popout.closePopout()
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 320
    popoutHeight: root.isRecording ? 360 : 300
}
