-- ============================================
-- 缩进线：indent-blankline.nvim
-- 在缩进位置画一条垂直线，帮助看清代码层级
-- ============================================

return {
  "lukas-reineke/indent-blankline.nvim",
  main = "ibl",
  event = "VeryLazy",

  opts = {
    indent = { char = "│" }, -- 缩进线的样式字符
    scope = { enabled = false }, -- 不显示作用域高亮（避免太花哨）
  },
}
