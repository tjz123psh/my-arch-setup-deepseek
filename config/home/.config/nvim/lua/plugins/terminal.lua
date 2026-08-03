-- ============================================
-- 浮动/分屏终端：toggleterm.nvim
-- 替代 :term，支持多终端实例、浮动窗口、快速切换
-- ============================================

return {
  "akinsho/toggleterm.nvim",
  version = "*",
  cmd = "ToggleTerm",
  keys = {
    { "<leader>tt", desc = "切换浮动终端" },
    { "<leader>th", desc = "水平分割终端" },
    { "<leader>tv", desc = "垂直分割终端" },
  },
  config = function()
    local toggleterm = require("toggleterm")

    toggleterm.setup({
      size = 20, -- 水平/垂直终端高度
      open_mapping = nil, -- 不用默认映射，用下方自定义
      shading_factor = 2, -- 终端背景暗化程度
      direction = "float", -- 默认浮动
      float_opts = {
        border = "rounded",
        winblend = 0, -- 匹配 kitty background_opacity 0.8
      },
    })

    local map = vim.keymap.set

    -- 切换终端（浮动，默认创建 1 号终端）
    map("n", "<leader>tt", "<cmd>ToggleTerm<cr>", { desc = "切换浮动终端" })

    -- 水平分割终端
    map("n", "<leader>th", "<cmd>ToggleTerm direction=horizontal<cr>", { desc = "水平分割终端" })

    -- 垂直分割终端
    map("n", "<leader>tv", "<cmd>ToggleTerm direction=vertical<cr>", { desc = "垂直分割终端" })
  end,
}
