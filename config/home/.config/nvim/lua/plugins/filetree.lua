-- ============================================
-- 文件树：neo-tree.nvim
-- 左侧显示项目文件结构
-- 按 <leader>e 打开/关闭
-- ============================================

return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  cmd = "Neotree",
  keys = {
    { "<leader>e", "<cmd>Neotree toggle<cr>", desc = "打开/关闭文件树" },
  },
  opts = {
    popup_border_style = "rounded",
    use_popups_for_input = false, -- 使用 vim.ui.input，由 dressing.nvim 接管统一风格
    window = {
      position = "left",
      width = 35,
      mappings = {
        ["<cr>"] = "open",
        ["o"] = "open",
      },
    },
    filesystem = {
      follow_current_file = { enabled = true },
      use_libuv_file_watcher = true,
      bind_to_cwd = true,
      window = {
        mappings = {
          ["h"] = "navigate_up",
          ["l"] = "set_root",
          ["r"] = "rename",
          ["m"] = "move",
          ["p"] = "toggle_hidden",
          ["."] = false,
        },
      },
    },
    default_component_configs = {
      indent = {
        with_markers = true,
        with_expanders = true,
        padding = 1,
      },
      icon = {
        folder_closed = "",
        folder_open = "",
        padding = " ",
      },
      git_status = {
        symbols = {
          added = "✚",
          modified = "",
          deleted = "✖",
        },
      },
    },
  },
}
