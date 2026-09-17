-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- HYPRLAND CONFIG（Lua）——模块化入口                     --
-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
--
-- 本文件只做「装配」：按顺序加载 conf/ 下各功能模块，具体配置见对应文件。
-- 所有模块共享全局 `hl`（Hyprland 注入），不通过 require 返回值传参。
-- 各模块职责与加载顺序见下方说明。
--
-- 加载顺序（有依赖关系，勿随意调换）：
--   1. dms.colors      —— DMS Matugen 自动生成的边框主题色，须最先加载，
--                         之后 appearance 里的 general 段不再覆盖 col。
--   2. conf.monitors   —— 显示器（scale 对齐 niri）
--   3. conf.autostart  —— hyprland.start 自启动钩子 + 环境变量
--   4. conf.appearance —— LOOK AND FEEL / 动画 / 布局 / MISC / CURSOR
--   5. conf.input      —— 键鼠手感 / 手势 / 外接鼠标 device
--   6. conf.keybinds   —— 全部快捷键（含本文件用到的 terminal/menu 等局部变量）
--   7. conf.windowrules—— 窗口规则（浮动/无边框/尺寸，对齐 niri）
--
-- 说明：dms/layout.lua、dms/outputs.lua 由 DMS 生成但当前未加载（其取值
--   已被 conf/monitors、conf/appearance 里对齐 niri 的手调值取代），保留备查。

-- DMS 主题色（Material，跟 niri 一致；由 Matugen 钩子自动更新，见 dms/colors.lua）。
require("dms.colors")

-- 功能模块（顺序见上方说明）。
require("conf.monitors")
require("conf.autostart")
require("conf.appearance")
require("conf.input")
require("conf.keybinds")
require("conf.windowrules")

-- >>> VM 测试模式开关 >>>
-- Win+Shift+D：进入 VM 测试模式（host 快捷键全关，只留此键退出），同 niri 的 Mod+Shift+D。
-- 本块由 hypr-vmtest-gen 管理：生成 hyprland.lua.vmtest 时会整块剥离，并换成调用
-- `hypr-vmtest-toggle leave` 的返回键；下面的标记行格式不要改动。
hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd("$HOME/scripts/desktop/hypr-vmtest-toggle enter"))
-- <<< VM 测试模式开关 <<<
