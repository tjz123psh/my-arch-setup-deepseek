-- ============================================
-- Rust 语言支持：rust-analyzer LSP + codelldb 调试
-- 前置: :Mason 安装 codelldb；cargo build 编译
-- ============================================

return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.rust_analyzer = vim.tbl_deep_extend("force", opts.servers.rust_analyzer or {}, {
        settings = {
          ["rust-analyzer"] = {
            check = { command = "clippy" },
            procMacro = { enable = true },
          },
        },
      })
    end,
  },
  {
    "mfussenegger/nvim-dap",
    opts = function(_, opts)
      -- 复用 codelldb（在 cpp.lua 中定义适配器）
      opts.configurations = opts.configurations or {}
      opts.configurations.rust = {
        {
          name = "启动调试（cargo 项目）",
          type = "codelldb",
          request = "launch",
          program = function()
            return vim.fn.input("可执行文件路径: ", vim.fn.getcwd() .. "/target/debug/", "file")
          end,
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
        },
        {
          name = "附加到进程",
          type = "codelldb",
          request = "attach",
          pid = function()
            return tonumber(vim.fn.input("进程 PID: "))
          end,
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
        },
      }
    end,
  },
}
