import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("shorinScreenrec.depCheck", ["sh", "-c", "command -v shorin-screenrec-menu"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null)
                return
            }
            done({
                title: I18n.tr("shorin-screenrec-menu 未安装"),
                details: I18n.tr("未在 PATH 中找到 'shorin-screenrec-menu'。\n\n请先把脚本安装到 ~/.local/bin（或其他 PATH 目录）并确保可执行，然后重新启用此插件。\n\n项目地址：https://github.com/SHORiN-KiWATA/screenrec-menu")
            })
        })
    }
}
