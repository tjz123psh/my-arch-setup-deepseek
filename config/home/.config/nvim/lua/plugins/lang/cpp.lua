-- ============================================
-- C/C++ 语言支持：clangd LSP + codelldb 调试
-- 前置: :Mason 安装 codelldb；g++ -g main.cpp -o main 编译
-- Rust LSP/DAP 配置见 rust.lua
-- ============================================

return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.clangd = vim.tbl_deep_extend("force", opts.servers.clangd or {}, {
        cmd = {
          "clangd",
          "--background-index",
          "--clang-tidy",
          "--completion-style=detailed",
          "--header-insertion=iwyu",
        },
        -- lspconfig 默认包含 c.doxygen/cpp.doxygen；当前 Neovim 健康检查会提示未知 filetype。
        -- 这里保留日常 C/C++ 相关类型，避免无意义的 checkhealth warning。
        filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto" },
        root_dir = function(bufnr, on_dir)
          local fname = vim.api.nvim_buf_get_name(bufnr)
          if fname and #fname > 0 then
            on_dir(
              vim.fs.root(fname, { ".clangd", "compile_commands.json", "build/compile_commands.json", ".git" })
                or vim.fn.getcwd()
            )
          end
        end,
      })
    end,
  },
  {
    "mfussenegger/nvim-dap",
    opts = {
      adapters = {
        codelldb = {
          type = "server",
          port = "${port}",
          executable = {
            command = vim.fn.stdpath("data") .. "/mason/bin/codelldb",
            args = { "--port", "${port}" },
          },
        },
      },
      configurations = {
        cpp = {
          {
            name = "启动调试（输路径）",
            type = "codelldb",
            request = "launch",
            program = function()
              return vim.fn.input("可执行文件路径: ", vim.fn.getcwd() .. "/", "file")
            end,
            cwd = "${workspaceFolder}",
            stopOnEntry = false,
          },
          {
            name = "启动调试（取当前文件名）",
            type = "codelldb",
            request = "launch",
            program = function()
              local file = vim.fn.expand("%:t:r") -- 去掉目录和扩展名
              return vim.fn.getcwd() .. "/" .. file
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
        },
        c = {
          {
            name = "启动调试（输路径）",
            type = "codelldb",
            request = "launch",
            program = function()
              return vim.fn.input("可执行文件路径: ", vim.fn.getcwd() .. "/", "file")
            end,
            cwd = "${workspaceFolder}",
            stopOnEntry = false,
          },
          {
            name = "启动调试（取当前文件名）",
            type = "codelldb",
            request = "launch",
            program = function()
              local file = vim.fn.expand("%:t:r")
              return vim.fn.getcwd() .. "/" .. file
            end,
            cwd = "${workspaceFolder}",
            stopOnEntry = false,
          },
        },
        -- Rust DAP 配置已移至 lang/rust.lua
      },
      -- 注意: 多配置后, F5 会让 nvim-dap 弹出 picker 选配置, 不再是直接输路径
    },
  },
}
