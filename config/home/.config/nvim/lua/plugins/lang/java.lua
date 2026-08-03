-- ============================================
-- Java 语言支持：jdtls LSP + DAP 调试
-- 前置: :Mason 安装 jdtls + java-debug-adapter
-- ============================================
--
-- 调试流程:
--   F5 → 输入主类名（字符串）→ dap.run()
--   → jdtls.startDebugSession → 返回端口
--   → nvim-dap 连接 → 调试开始
--
-- 注意:
--   - mainClass 必须是字符串（JSON 不支持函数），所以先 input 求值
--   - java-debug-adapter 必须作为 bundles 由 jdtls 加载，不能独立运行
--   - 先 F9 设断点，否则程序直接跑完退出

return {
  {
    "mfussenegger/nvim-jdtls",
    ft = { "java" },
    opts = {
      cmd = { vim.fn.stdpath("data") .. "/mason/bin/jdtls" },
      -- root_dir 不用在 opts 里设函数——vim.lsp.start 不解析函数式 root_dir
      -- 在 config 里预先求值为字符串再传
      settings = {
        java = {
          inlayHints = { parameterNames = { enabled = "all" } },
        },
      },
      init_options = {
        bundles = {},
      },
    },

    config = function(_, opts)
      local ok, blink = pcall(require, "blink.cmp")
      if ok then
        opts.capabilities = blink.get_lsp_capabilities()
      end

      -- 将 java-debug/java-test JAR 作为 bundles 传给 jdtls（必须, 不能独立 java -jar 启动）
      local bundle_patterns = {
        vim.fn.stdpath("data")
          .. "/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar",
        vim.fn.stdpath("data") .. "/mason/packages/java-test/extension/server/*.jar",
      }
      for _, pattern in ipairs(bundle_patterns) do
        local jars = vim.fn.glob(pattern, false, true)
        if #jars > 0 then
          vim.list_extend(opts.init_options.bundles, jars)
        end
      end

      -- 保存基础 cmd（不含 -data），后续每次 start_or_attach 时重新拼装
      local cmd_base = opts.cmd or { vim.fn.stdpath("data") .. "/mason/bin/jdtls" }

      local function build_cmd(dir)
        local project_name = vim.fn.fnamemodify(dir or vim.fn.getcwd(), ":t")
        local project_hash = vim.fn.sha256(vim.fs.normalize(dir or vim.fn.getcwd())):sub(1, 10)
        local workspace_dir = vim.fn.stdpath("data") .. "/site/jdtls-workspace/" .. project_name .. "-" .. project_hash
        local cmd = vim.deepcopy(cmd_base)
        vim.list_extend(cmd, { "-data", workspace_dir })
        return cmd
      end

      local jdtls = require("jdtls")
      local dap = require("dap")

      -- 解析 root_dir 为字符串（vim.lsp.start 直接传值，不支持函数）
      local resolve_root = function(bufnr)
        local fname = vim.api.nvim_buf_get_name(bufnr)
        if fname and #fname > 0 then
          return vim.fs.root(fname, { "pom.xml", "build.gradle", "build.gradle.kts", ".git", "src" }) or vim.fn.getcwd()
        end
        return vim.fn.getcwd()
      end
      opts.root_dir = resolve_root(0)

      -- 注册适配器: 找 jdtls client → startDebugSession → port（只执行一次）
      jdtls.setup_dap({ hotcodereplace = "auto" })

      -- F5: 先求值 mainClass 为字符串再 dap.run()（函数无法 JSON 序列化）
      local dap_run_with_input = function()
        local main_class = vim.fn.input("主类名: ", vim.fn.expand("%:t:r"))
        if main_class and #main_class > 0 then
          dap.run({
            type = "java",
            name = "Java 调试",
            request = "launch",
            mainClass = main_class,
          })
        end
      end

      -- 设当前缓冲区的快捷键（懒加载导致错过 FileType 事件）
      local setup_java_keys = function(bufnr)
        vim.keymap.set("n", "<F5>", dap_run_with_input, { buffer = bufnr, silent = true, desc = "调试 Java" })
        vim.keymap.set(
          "n",
          "<leader>co",
          vim.lsp.buf.code_action,
          { buffer = bufnr, silent = true, desc = "Java 代码操作" }
        )
        vim.keymap.set("n", "<leader>ot", function()
          require("jdtls").organize_imports()
        end, { buffer = bufnr, silent = true, desc = "整理 import" })
      end

      -- 每次启动/附加时重新解析 root_dir 和 cmd（-data workspace_dir 按项目切换）
      local function start_jdtls(bufnr)
        local root_dir = resolve_root(bufnr)
        local config = vim.deepcopy(opts)
        config.root_dir = root_dir
        config.cmd = build_cmd(root_dir)
        jdtls.start_or_attach(config)
        setup_java_keys(bufnr)
      end

      -- 后续打开的 Java 文件
      local group = vim.api.nvim_create_augroup("java_jdtls", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "java",
        callback = function()
          start_jdtls(0)
        end,
      })

      -- 当前已有 Java 文件
      if vim.bo.filetype == "java" then
        vim.schedule(function()
          start_jdtls(0)
        end)
      end
    end,
  },
}
