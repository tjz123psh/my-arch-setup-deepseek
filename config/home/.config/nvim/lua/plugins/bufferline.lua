-- =============================================================================
-- 标签栏（缓冲区列表）：bufferline.nvim
-- =============================================================================
-- 在窗口顶部显示标签栏，展示所有打开的缓冲区。
-- 支持图标、诊断信息、neo-tree 文件树偏移等。
-- 快捷键：<S-h> 切换到上一个标签，<S-l> 切换到下一个标签。
-- =============================================================================

return {
  "akinsho/bufferline.nvim",
  version = "*",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
    "catppuccin/nvim",
  },
  event = "VeryLazy",
  keys = {
    { "<S-h>", "<cmd>BufferLineCyclePrev<cr>", desc = "切换到上一个缓冲区" },
    { "<S-l>", "<cmd>BufferLineCycleNext<cr>", desc = "切换到下一个缓冲区" },
  },
  opts = function()
    local highlights
    local ok, bufferline_theme = pcall(require, "catppuccin.special.bufferline")
    if ok then
      highlights = bufferline_theme.get_theme()
    end

    return {
      highlights = highlights,
      options = {
        mode = "buffers",
        numbers = "none",
        close_command = "bdelete %d",
        right_mouse_command = "bdelete %d",
        indicator = {
          style = "icon",
          icon = "▎",
        },
        buffer_close_icon = "󰅖",
        modified_icon = "●",
        left_trunc_marker = "",
        right_trunc_marker = "",
        separator_style = "thin",
        diagnostics = "nvim_lsp",
        diagnostics_indicator = function(_, _, diagnostics)
          local parts = {}
          for _, item in ipairs({
            { "error", "󰅚" },
            { "warning", "󰀪" },
            { "info", "󰋽" },
            { "hint", "󰌶" },
          }) do
            local count = diagnostics[item[1]] or 0
            if count > 0 then
              table.insert(parts, item[2] .. " " .. count)
            end
          end
          return #parts > 0 and " " .. table.concat(parts, " ") or ""
        end,
        offsets = {
          {
            filetype = "neo-tree",
            text = "文件树",
            highlight = "Directory",
            text_align = "left",
          },
        },
      },
    }
  end,
}
