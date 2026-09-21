-- 触摸板开关状态 —— 由 niri-touchpad-toggle / hypr-touchpad-toggle（Fn+F10）维护，
-- 一般不用手改。conf/input.lua 启动时用 pcall(dofile) 读取，文件缺失或损坏时回退为「开启」。
-- 取值范围：true（开启，默认）/ false（关闭）。
return { enabled = true }
