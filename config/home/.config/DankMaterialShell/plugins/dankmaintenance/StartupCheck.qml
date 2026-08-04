import QtQuick
import qs.Common

// 启动自检：非可视化 QtObject。失败则插件不加载并提示。
QtObject {
    function check(done) {
        Proc.runCommand("dankmaintenance.startup", [
            "bash", "-c",
            "test -x /home/pang/.config/DankMaterialShell/plugins/dankmaintenance/collect-status && "
            + "test -d /home/pang/.cache/checkallupdates && "
            + "test -r /.snapshots && test -r /home/.snapshots"
        ], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null)
            } else {
                done({
                    title: "依赖检查未通过",
                    details: "需要：collect-status 可执行、~/.cache/checkallupdates 存在、/.snapshots 与 /home/.snapshots 可读。"
                })
            }
        })
    }
}
