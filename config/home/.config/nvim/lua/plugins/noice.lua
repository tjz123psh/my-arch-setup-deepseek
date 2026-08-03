-- ============================================
-- UI 增强：noice.nvim
-- 将命令行、消息通知、弹出菜单替换为浮动窗口
-- 搭配 dressing.nvim 统一界面风格
-- ============================================

return {
  "folke/noice.nvim",
  lazy = false,
  dependencies = {
    "MunifTanjim/nui.nvim",
    {
      "rcarriga/nvim-notify",
      opts = {
        timeout = 2500,
        stages = "fade_in_slide_out",
        background_colour = "#000000",
      },
      config = function(_, opts)
        local notify = require("notify")
        notify.setup(opts)
        vim.notify = notify
      end,
    },
  },

  opts = {
    -- 命令行输入弹窗（居中圆角浮动窗口，窄终端自动收缩）
    views = {
      cmdline_popup = {
        position = { row = "50%", col = "50%" },
        size = { width = 78 },
        border = { style = "rounded" },
      },
      cmdline_input = {
        position = { row = "50%", col = "50%" },
        size = { width = 78 },
        border = { style = "rounded" },
      },
    },

    -- 命令模式（: 开头的命令）
    cmdline = {
      enabled = true,
      view = "cmdline_popup",
    },

    -- 普通消息通知
    messages = {
      enabled = true,
      view = "notify",
      view_error = "notify",
      view_warn = "notify",
    },

    -- 弹出菜单（如代码操作列表）
    popupmenu = {
      enabled = true,
      backend = "nui",
    },

    -- 通知区域（右下角 mini 风格）
    notify = {
      enabled = true,
      view = "mini",
    },

    -- LSP 进度提示
    lsp = {
      progress = {
        enabled = true,
        view = "notify",
        format = "lsp",
      },
      override = {
        ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
        ["vim.lsp.util.stylize_markdown"] = true,
      },
    },

    -- 路由规则：过滤不需要弹窗的通知
    routes = {
      { filter = { event = "msg_show", kind = "search_count" }, opts = { skip = true } },
      { filter = { event = "lsp", kind = "progress", find = "jdtls" }, opts = { skip = true } },
    },
  },
}
