-- ============================================
-- LSP（语言服务器协议）配置
-- LSP 提供代码补全、错误检查、跳转定义等功能
-- 这里配置 nvim-lspconfig + mason-lspconfig
-- ============================================

return {
  "neovim/nvim-lspconfig",
  lazy = false,
  dependencies = {
    {
      "williamboman/mason.nvim",
      opts = {
        PATH = "prepend",
      },
    },
    -- 让 mason 自动安装 LSP 服务器（但不自动配置，由下方 config 接管）
    {
      "williamboman/mason-lspconfig.nvim",
      dependencies = { "williamboman/mason.nvim" },
      opts = {
        ensure_installed = {
          "clangd", -- C/C++
          "lua_ls", -- Lua（Neovim 配置用）
          "jdtls", -- Java
          "gopls", -- Go
          "rust_analyzer", -- Rust
          "html", -- HTML
          "cssls", -- CSS
          "jsonls", -- JSON
          "yamlls", -- YAML
          "marksman", -- Markdown
        },
        automatic_enable = false, -- 手动管理，跳过自动启用
      },
      config = function(_, opts)
        require("mason").setup({ PATH = "prepend" })
        require("mason-lspconfig").setup(opts)
      end,
    },
    -- 补全引擎（需要 LSP 的能力信息）
    "saghen/blink.cmp",
  },

  opts = {
    -- 要启用哪些 LSP 服务器
    -- clangd/rust_analyzer 直配，其他用 lang/ 单独管理
    servers = {
      clangd = {},
      rust_analyzer = {},
      lua_ls = {
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            diagnostics = { globals = { "vim", "jit" } },
            workspace = {
              checkThirdParty = false,
              library = vim.api.nvim_get_runtime_file("", true),
            },
            telemetry = { enable = false },
          },
        },
      },
      html = {},
      cssls = {},
      jsonls = {},
      yamlls = {},
      marksman = {},
    },

    -- 当 LSP 附加到某个缓冲区时，注册对应的快捷键
    on_attach = function(client, bufnr)
      local desc = function(d)
        return { buffer = bufnr, silent = true, desc = d }
      end

      -- 代码导航（只在服务器支持时才注册）
      if client.server_capabilities.definitionProvider then
        vim.keymap.set("n", "gd", vim.lsp.buf.definition, desc("跳转到定义"))
      end
      if client.server_capabilities.typeDefinitionProvider then
        vim.keymap.set("n", "gR", vim.lsp.buf.type_definition, desc("跳转到类型定义"))
      end
      if client.server_capabilities.hoverProvider then
        vim.keymap.set("n", "gh", vim.lsp.buf.hover, desc("悬停显示文档"))
      end
      if client.server_capabilities.referencesProvider then
        vim.keymap.set("n", "gr", vim.lsp.buf.references, desc("查找所有引用"))
      end
      if client.server_capabilities.implementationProvider then
        vim.keymap.set("n", "gi", vim.lsp.buf.implementation, desc("跳转到实现"))
      end

      -- 诊断导航（上下一个错误）
      vim.keymap.set("n", "[d", function()
        vim.diagnostic.jump({ count = -1, float = true })
      end, desc("上一个诊断"))
      vim.keymap.set("n", "]d", function()
        vim.diagnostic.jump({ count = 1, float = true })
      end, desc("下一个诊断"))

      -- 代码操作
      if client.server_capabilities.renameProvider then
        vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, desc("重命名符号"))
      end
      if client.server_capabilities.codeActionProvider then
        vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, desc("代码操作"))
      end
      if client.server_capabilities.signatureHelpProvider then
        vim.keymap.set("i", "<C-k>", vim.lsp.buf.signature_help, desc("显示函数签名"))
      end
    end,

    -- 需要跳过的服务器（由专门的插件管理）
    setup = {
      jdtls = function()
        return true
      end, -- Java 由 nvim-jdtls 管理
      rust_analyzer = function()
        if vim.fn.executable("rustc") == 1 and vim.fn.executable("cargo") == 1 then
          return false
        end

        vim.schedule(function()
          vim.notify(
            "Rust 工具链未安装，已跳过 rust-analyzer。安装 rust 后重新打开项目即可。",
            vim.log.levels.WARN
          )
        end)
        return true
      end,
    },
  },

  config = function(_, opts)
    -- nvim-lspconfig 0.12+ 的配置存放在 lsp/ 目录，vim.lsp.config 会自动发现
    -- 无需手动 require 旧版 lspconfig.configs

    -- 从 blink.cmp 获取 LSP 补全能力
    local ok, blink = pcall(require, "blink.cmp")
    local caps = ok and blink.get_lsp_capabilities() or {}

    for server, config in pairs(opts.servers) do
      local setup_fn = opts.setup[server]
      if setup_fn and setup_fn(server, config) then
        -- 跳过特殊管理的服务器（如 jdtls）
      else
        config.capabilities = vim.tbl_deep_extend("force", caps, config.capabilities or {})
        config.on_attach = opts.on_attach
        vim.lsp.config(server, config)
        vim.lsp.enable(server)
      end
    end
  end,
}
