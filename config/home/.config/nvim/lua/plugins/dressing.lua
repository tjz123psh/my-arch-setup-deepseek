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
        -- 与 Spring 向导 / noice 通知同款：实底 #1E1E2E + 粉圆角边
        -- （Wiz* 组由 core/spring_wizard.lua 在启动时定义，ColorScheme 自动重建）
        winhighlight = "Normal:WizBg,FloatBorder:WizBorder,FloatTitle:WizTitle",
      },
    },
    select = {
      enabled = true,
      -- nui 观感更现代（居中、圆角、无编号），builtin 兜底（若 nui 报错）
      backend = { "nui", "builtin" },
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
        relative = "editor",
        border = {
          style = "rounded",
        },
        -- 注意：dressing 读的是这一层的 min_width/min_height（不是 renderer 子表）。
        -- 高度算法是 max(#lines, min_height)：默认 min_height=10 会让 2 个选项
        -- 撑出 10 行空框；但压到 1 又太挤。取 6 是「两三个选项也不显局促、
        -- 选项多时又不会留大片空白」的折中。
        min_width = 56,
        max_width = 84,
        min_height = 6,
        max_height = 18,
        win_options = {
          winblend = 0,
          -- 与向导/noice 统一：透明底 + 粉边；选中行只用文字色
          -- （WizCursorLine 的底色条+下划线是给 picker 设计的，菜单里显脏）
          winhighlight = "Normal:WizBg,FloatBorder:WizBorder,CursorLine:WizMenuSel,FloatTitle:WizTitle",
        },
      },
    },
  },
}
