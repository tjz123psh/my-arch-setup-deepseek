-- ============================================
-- 状态栏：lualine.nvim
-- 屏幕底部的信息栏，显示模式、文件名、Git 分支等
-- ============================================

return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "catppuccin/nvim" },
  event = "UIEnter",

  opts = function()
    local ok, theme = pcall(require, "lualine.themes.catppuccin-mocha")
    return {
      options = {
        theme = ok and theme or "auto",
        component_separators = { left = "", right = "" },
        section_separators = { left = "", right = "" },
        globalstatus = true,
        disabled_filetypes = { "neo-tree", "alpha" },
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch" },
        lualine_c = {
          {
            "filename",
            file_status = true,
            path = 1,
            symbols = { modified = " ●", readonly = " " },
          },
        },
        lualine_x = {
          {
            "diagnostics",
            sources = { "nvim_diagnostic" },
            colored = true,
            update_in_insert = false,
            symbols = { error = " 󰅚 ", warn = " 󰀪 ", info = " 󰋽 ", hint = " 󰌶 " },
          },
          "filetype",
        },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
      inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = { "filename" },
        lualine_x = {},
        lualine_y = {},
        lualine_z = { "location" },
      },
      extensions = { "neo-tree" },
    }
  end,
}
