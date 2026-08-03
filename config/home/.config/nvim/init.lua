-- ============================================
-- Neovim 配置入口文件
-- 这是整个配置的启动点，Neovim 会先读取这个文件
-- ============================================

-- 设置 leader 键为空格键（快捷键前缀）
-- 例如 <leader>e 就是先按空格再按 e
vim.g.mapleader = " "

-- 设置 localleader 键为反斜杠（缓冲区局部快捷键前缀）
vim.g.maplocalleader = "\\"

-- 加载核心配置（选项、快捷键、自动命令）
require("core")

-- 加载插件管理器 lazy.nvim，它会自动加载 lua/plugins/ 下所有配置
require("core.lazy")

-- 如果当前正在使用 Neovide GUI，加载专用配置
if vim.g.neovide then
  require("neovide")
end
