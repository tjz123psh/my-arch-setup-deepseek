-- ============================================
-- Flash 跳转：闪光标速移动
-- 按 s + 字符 → 屏幕上显示标签 → 按标签字母跳到对应位置
-- 比 f/t 效率更高，手指不用离开主行
-- ============================================

return {
  "folke/flash.nvim",
  event = "VeryLazy",
  opts = {
    modes = {
      search = { enabled = true },
    },
  },
  keys = {
    {
      "s",
      mode = { "n", "x", "o" },
      function()
        require("flash").jump()
      end,
      desc = "Flash 跳转",
    },
    {
      "S",
      mode = { "n", "x", "o" },
      function()
        require("flash").treesitter()
      end,
      desc = "Flash Treesitter 选择",
    },
  },
}
