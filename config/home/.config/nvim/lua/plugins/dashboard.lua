-- ============================================
-- 启动欢迎页：alpha-nvim
-- Neovim 启动时显示的漂亮界面
-- 有快捷键可以直接打开常用功能
-- ============================================

return {
  "goolord/alpha-nvim",
  -- 有文件参数时不抢占首屏；保留 :Alpha/:A 命令按需加载。
  event = vim.fn.argc() == 0 and "VimEnter" or nil,
  cmd = "Alpha",

  opts = function()
    local dashboard = require("alpha.themes.dashboard")

    -- ASCII 艺术字 Logo（NEovIM）
    local logo = {
      "  ███╗   ██╗███████╗ ██████╗ ██╗   ██╗██╗███╗   ███╗",
      "  ████╗  ██║██╔════╝██╔═══██╗██║   ██║██║████╗ ████║",
      "  ██╔██╗ ██║█████╗  ██║   ██║██║   ██║██║██╔████╔██║",
      "  ██║╚██╗██║██╔══╝  ██║   ██║╚██╗ ██╔╝██║██║╚██╔╝██║",
      "  ██║ ╚████║███████╗╚██████╔╝ ╚████╔╝ ██║██║ ╚═╝ ██║",
      "  ╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚═╝     ╚═╝",
    }
    dashboard.section.header.val = vim.o.columns >= 68 and logo or { "NEOVIM" }

    -- 快捷按钮
    local config_search = "<cmd>Telescope find_files cwd=" .. vim.fn.fnameescape(vim.fn.stdpath("config")) .. "<cr>"
    dashboard.section.buttons.val = {
      dashboard.button("f", "  查找文件", "<cmd>Telescope find_files<cr>"),
      dashboard.button("r", "  最近文件", "<cmd>Telescope oldfiles<cr>"),
      dashboard.button("c", "  Neovim 配置", config_search),
      dashboard.button("p", "  项目列表", "<cmd>Projects<cr>"),
      dashboard.button("n", "  新建文件", "<cmd>ene <bar> startinsert<cr>"),
      dashboard.button("q", "  退出", "<cmd>qa<cr>"),
    }

    -- 页脚
    local version = vim.version()
    local cwd = vim.o.columns >= 80 and vim.fn.getcwd() or vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
    dashboard.section.footer.val = {
      "",
      string.format("  Neovim %d.%d.%d  |  %s  ", version.major, version.minor, version.patch, cwd),
    }
    dashboard.section.footer.opts.hl = "Type"

    -- 设置按钮颜色
    for _, btn in ipairs(dashboard.section.buttons.val) do
      btn.opts.hl = "Label"
      btn.opts.hl_shortcut = "Keyword"
    end

    -- 布局：上边距 3 → Logo → 边距 2 → 按钮 → 边距 1 → 页脚
    dashboard.opts.layout = {
      { type = "padding", val = 3 },
      dashboard.section.header,
      { type = "padding", val = 2 },
      dashboard.section.buttons,
      { type = "padding", val = 1 },
      dashboard.section.footer,
    }

    return dashboard.opts
  end,
}
