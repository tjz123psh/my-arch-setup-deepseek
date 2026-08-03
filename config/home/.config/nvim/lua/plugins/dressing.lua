-- ============================================
-- UI 美化：dressing.nvim
-- 美化 vim.ui.select（代码操作菜单、查找替换等）和 vim.ui.input
-- 让内置选择/输入弹窗有统一圆角边框风格
-- ============================================

return {
  "stevearc/dressing.nvim",
  event = "VeryLazy",
  opts = {
    input = {
      enabled = true,
      default_prompt = "Input",
      trim_prompt = true,
      title_pos = "left", -- 标题左对齐，与 noice cmdline 一致
      start_mode = "insert",
      border = "rounded", -- 圆角边框
      relative = "editor", -- 相对编辑器居中
      prefer_width = 78,
      max_width = { 78, 0.9 },
      min_width = { 24, 0.4 },
      override = function(conf)
        local width = math.min(conf.width or 78, math.max(20, vim.o.columns - 4))
        conf.width = width
        conf.row = math.floor((vim.o.lines - 3) / 2)
        conf.col = math.max(0, math.floor((vim.o.columns - width) / 2))
        return conf
      end,
      win_options = {
        winblend = 0, -- 不透明
        wrap = false,
        list = true,
        listchars = "precedes:…,extends:…",
        -- 使用与 noice 相同的高亮组
        winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
      },
    },
    select = {
      enabled = true,
      backend = { "builtin", "nui" }, -- 优先使用内置浮动选择器
      builtin = {
        border = "rounded",
        relative = "editor",
        win_options = {
          cursorline = true,
          cursorlineopt = "both",
        },
      },
      nui = {
        position = "50%",
        border = {
          style = "rounded",
        },
        win_options = {
          winblend = 0,
        },
      },
    },
  },
}
