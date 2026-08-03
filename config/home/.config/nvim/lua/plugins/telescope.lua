-- ============================================
-- 模糊搜索：telescope.nvim
-- 查找文件、搜索文本、浏览缓冲区等
-- 是目前最强大的 Neovim 搜索工具
-- ============================================

return {
  "nvim-telescope/telescope.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "ahmedkhalf/project.nvim",
  },

  cmd = "Telescope",

  config = function(_, opts)
    require("telescope").setup(opts)
    pcall(require("telescope").load_extension, "projects")
  end,

  -- 快捷键：<leader>f 开头的一系列搜索
  keys = {
    { "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "搜索文件名" },
    { "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "搜索文件内容" },
    { "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "切换已打开的缓冲区" },
    { "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "搜索帮助文档" },
    { "<leader>fp", "<cmd>Projects<cr>", desc = "搜索项目" },
  },

  opts = {
    defaults = {
      border = true,
      borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
      dynamic_preview_title = true,
      layout_strategy = "horizontal",
      layout_config = {
        width = 0.9,
        height = 0.85,
        preview_cutoff = 100,
        horizontal = {
          prompt_position = "top",
          preview_width = 0.55,
        },
      },
      path_display = { "smart" },
      prompt_prefix = "   ",
      selection_caret = "  ",
      sorting_strategy = "ascending",
      results_title = false,
      mappings = {
        i = {
          ["<C-j>"] = "move_selection_next", -- 向下翻
          ["<C-k>"] = "move_selection_previous", -- 向上翻
        },
      },
    },
  },
}
