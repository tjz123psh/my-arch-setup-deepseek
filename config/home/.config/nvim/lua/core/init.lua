-- ============================================
-- 核心配置加载器
-- 按顺序加载各项基础配置
-- ============================================

require("core.options") -- 编辑器全局设置（行号、缩进、搜索等）
require("core.filetypes") -- 自定义文件类型识别
require("core.keymaps") -- 全局快捷键映射
require("core.commands") -- 自定义命令（:R、:A、:Projects、:JavaRun、:LspInfo、:LspLog）
require("core.autocmds") -- 自动命令（特定操作的自动触发）
