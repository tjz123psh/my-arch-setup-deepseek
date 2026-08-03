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
        Quickshell.execDetached(["shorin-screenrec-menu"].concat(args))
        // 触发操作后稍延迟刷新，让状态文件写入完成
        refreshDebounce.restart()
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
        interval: 700
        repeat: false
        onTriggered: root.refreshStatus()
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
                font.family: "monospace"
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

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // 录制中只显示停止；空闲显示三种模式 + 设置
                Repeater {
                    model: root.isRecording
                        ? [{ icon: "stop_circle", label: "停止录制", args: ["stop"], danger: true }]
                        : [
                            { icon: "fullscreen", label: "全屏录制", args: ["start", "-f"], danger: false },
                            { icon: "crop", label: "区域录制", args: ["start", "-r"], danger: false },
                            { icon: "gif_box", label: "录制 GIF (区域)", args: ["start", "-g"], danger: false },
                            { icon: "settings", label: "设置…", args: ["settings"], danger: false }
                        ]

                    delegate: StyledRect {
                        width: parent.width
                        height: 44
                        radius: Theme.cornerRadius
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
    popoutHeight: root.isRecording ? 160 : 300
}
