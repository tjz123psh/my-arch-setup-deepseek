-- ============================================
-- 快捷退出插入模式：better-escape
-- 按 jk 代替 <Esc> 退出插入模式，手不离主行
-- ============================================

return {
  "nvim-zh/better-escape.vim",
  event = "InsertEnter",
  config = function()
    vim.g.better_escape_shortcut = "jk"
    vim.g.better_escape_interval = 200
  end,
}
