import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "shorinScreenrec"

    StyledText {
        width: parent.width
        text: "Shorin 录屏"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "顶栏显示录制状态。空闲时显示相机图标，录制时显示脉冲红点与计时。左键打开菜单，右键强制停止。"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "pollInterval"
        label: "刷新间隔"
        description: "多久查询一次录制状态（秒）。录制计时按此频率更新。"
        defaultValue: 1
        minimum: 1
        maximum: 10
        unit: "秒"
    }
}
