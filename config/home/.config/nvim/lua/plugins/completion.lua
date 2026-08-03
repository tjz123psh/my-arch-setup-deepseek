-- ============================================
-- 补全引擎：blink.cmp
-- 提供代码补全弹出菜单
-- 支持 LSP、代码片段、缓冲区内容、路径补全
-- ============================================

return {
  "saghen/blink.cmp",
  version = "v1.*",
  lazy = false, -- 立即加载，确保补全始终可用
  dependencies = { "rafamadriz/friendly-snippets" },

  opts = {
    -- 快捷键配置
    keymap = {
      preset = "default",
      -- 双空格触发已移除：导致每次按空格延迟 300ms，补全靠自动触发即可
      ["<CR>"] = { "accept", "fallback" }, -- 回车选中当前项
      ["<Tab>"] = { "accept", "snippet_forward", "fallback" }, -- 选中补全或跳到下一片段占位符
      ["<S-Tab>"] = { "snippet_backward", "fallback" }, -- 跳到上一片段占位符
      ["<C-n>"] = { "select_next", "fallback" }, -- Ctrl+n 选择下一项
      ["<C-p>"] = { "select_prev", "fallback" }, -- Ctrl+p 选择上一项
      ["<C-e>"] = { "hide" }, -- 关闭补全
      ["<C-u>"] = { "scroll_documentation_up" }, -- 文档上翻
      ["<C-d>"] = { "scroll_documentation_down" }, -- 文档下翻
    },

    -- 补全数据来源
    sources = {
      default = { "lsp", "snippets", "buffer", "path" },
    },

    -- 使用 Neovim 原生 vim.snippet；Blink 会自动读取 friendly-snippets。
    snippets = { preset = "default" },

    -- 弹窗外观
    completion = {
      documentation = { auto_show = true, window = { border = "rounded" } },
      menu = {
        border = "rounded",
        draw = {
          columns = {
            { "label", "label_description", gap = 1 },
            { "kind_icon" },
          },
        },
      },
    },

    -- 外观设置
    appearance = {
      nerd_font_variant = "mono",
    },
  },
}
