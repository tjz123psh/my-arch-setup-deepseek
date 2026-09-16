-- ============================================
-- Spring Boot 支持
-- ============================================
-- JavaHello/spring-boot.nvim：application.yml/properties 的 Spring 属性补全、
-- 诊断、跳转和 Code Action，底层使用 Mason 的 vscode-spring-boot-tools。
-- elmcgill/springboot-nvim：保留原有的 Java 类生成、增量编译和项目辅助功能。
-- 两者配合现有 mfussenegger/nvim-jdtls 使用，不替换 Java 启动配置。
-- ============================================

return {
  {
    "JavaHello/spring-boot.nvim",
    lazy = false,
    ft = { "java", "yaml", "jproperties" },
    dependencies = {
      "mfussenegger/nvim-jdtls",
    },
    opts = {},
    config = function(_, opts)
      require("core.spring_wizard").setup()
      require("spring_boot").setup(opts)
    end,
    keys = {
      { "<leader>sp", function() require("core.spring_wizard").create() end, desc = "Spring Boot 项目向导（可搜索选择）" },
      { "<leader>sP", "<cmd>SpringBootNewProject<cr>", desc = "原版向导（不推荐：Boot 4 版本号有 bug）" },
    },
  },

  {
    "elmcgill/springboot-nvim",
    ft = { "java" },
    dependencies = {
      "neovim/nvim-lspconfig",
      "mfussenegger/nvim-jdtls",
    },
    keys = {
      { "<leader>Gc", function() require("springboot-nvim").generate_class() end, desc = "生成: Java Class" },
      { "<leader>Gi", function() require("springboot-nvim").generate_interface() end, desc = "生成: Java Interface" },
      { "<leader>Ge", function() require("springboot-nvim").generate_enum() end, desc = "生成: Java Enum" },
      { "<leader>Gr", function() require("springboot-nvim").generate_record() end, desc = "生成: Java Record" },
    },
    config = function()
      local springboot = require("springboot-nvim")
      springboot.setup({})

      -- 原插件无条件注册增量编译；只在 jdtls 已附加时执行，避免裸 Java 文件刷错。
      local group = vim.api.nvim_create_augroup("JavaAutoCommands", { clear = true })
      vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*.java",
        callback = function(ev)
          if vim.lsp.get_clients({ bufnr = ev.buf, name = "jdtls" })[1] then
            springboot.incremental_compile()
          end
        end,
      })
    end,
  },
}
