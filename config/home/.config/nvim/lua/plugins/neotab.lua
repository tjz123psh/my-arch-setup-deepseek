-- ============================================
-- Tab 智能跳转：neotab.nvim
-- 在括号/引号内按 Tab 跳到结尾而非插入制表符
-- 比默认行为更智能的 Tab 导航
-- ============================================

return {
  "kawre/neotab.nvim",
  event = "InsertEnter",
  opts = {
    tabkey = "<Tab>",
    reverse_key = "<S-Tab>",
    act_as_tab = true,
    behavior = "nested",
    pairs = {
      { open = "(", close = ")" },
      { open = "[", close = "]" },
      { open = "{", close = "}" },
      { open = "'", close = "'" },
      { open = '"', close = '"' },
      { open = "`", close = "`" },
      { open = "<", close = ">" },
    },
  },
}
