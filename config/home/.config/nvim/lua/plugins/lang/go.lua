-- ============================================
-- Go 语言支持：gopls LSP + delve 调试器
-- LSP 配置扩展 lsp/init.lua 中设置的 gopls
-- DAP 配置 delve 适配器
-- ============================================

return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.gopls = vim.tbl_deep_extend("force", opts.servers.gopls or {}, {
        settings = {
          gopls = {
            gofumpt = true,
            analyses = { unusedparams = true, unreachable = true },
            staticcheck = true,
          },
        },
      })
    end,
  },
  {
    "mfussenegger/nvim-dap",
    opts = {
      adapters = {
        delve = {
          type = "server",
          port = "${port}",
          executable = {
            command = vim.fn.stdpath("data") .. "/mason/bin/dlv",
            args = { "dap", "-l", "127.0.0.1:${port}" },
          },
        },
      },
      configurations = {
        go = {
          {
            name = "启动调试",
            type = "delve",
            request = "launch",
            program = "${workspaceFolder}",
            cwd = "${workspaceFolder}",
          },
        },
      },
    },
  },
}
