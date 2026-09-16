-- ============================================
-- lazy.nvim 插件管理器配置
-- lazy.nvim 是目前最快的 Neovim 插件管理器
-- ============================================

-- 如果 lazy.nvim 还没安装，自动用 git 下载
-- 用入口文件判断是否完整：clone 被中断会留下只有 .git 的空目录，
-- 只检查目录存在会跳过重新克隆，导致 require("lazy") 失败
-- 注意：新版 lazy.nvim 入口是 lua/lazy/init.lua，老版本是 lua/lazy.lua，都检查
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local entry_ok = vim.uv.fs_stat(lazypath .. "/lua/lazy/init.lua")
  or vim.uv.fs_stat(lazypath .. "/lua/lazy.lua")
if not entry_ok then
  if vim.uv.fs_stat(lazypath) then
    vim.fn.system({ "rm", "-rf", lazypath })
  end
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- 配置 lazy.nvim
require("lazy").setup({
  spec = {
    { import = "plugins" },
  },
  rocks = { enabled = false }, -- 不用 rocks 生态插件，清 checkhealth 警告
  defaults = {
    lazy = false, -- 默认不延迟加载（除非插件自己指定）
    version = false, -- 不锁定版本，随时更新
  },
  install = {
    colorscheme = { "catppuccin" }, -- 安装插件时用的临时主题
  },
  checker = {
    enabled = true, -- 定期检查插件更新
    notify = false, -- 但不弹通知（手动用 :Lazy check）
  },
  change_detection = {
    notify = false, -- 配置文件变更时不提示
  },
  performance = {
    reset_packpath = true,
    rtp = {
      reset = true,
      disabled_plugins = { -- 禁用 Neovim 内置的不常用插件
        "gzip",
        "tarPlugin",
        "zipPlugin",
        "tohtml",
        "tutor",
      },
    },
  },
})
