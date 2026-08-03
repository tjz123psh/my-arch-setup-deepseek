-- ============================================
-- 代码格式化：conform.nvim
-- 保存文件时自动格式化代码
-- 依赖 mason 安装对应格式化工具
-- ============================================

return {
  "stevearc/conform.nvim",
  event = { "BufWritePre" },

  opts = {
    -- 保存时自动格式化。Java 半成品代码经常无法被 google-java-format 解析，
    -- 保留手动 <leader>F 格式化，避免保存被格式化器打断或改写。
    format_on_save = function(bufnr)
      if vim.bo[bufnr].filetype == "java" then
        return nil
      end

      return {
        timeout_ms = 2000,
        lsp_format = "fallback", -- 优先用下方明确配置的格式化器，缺失时再走 LSP
      }
    end,

    -- 每种文件类型使用的格式化工具
    -- 需要先通过 :Mason 安装
    formatters_by_ft = {
      lua = { "stylua" },

      java = { "google-java-format" },
      cpp = { "clang-format" },
      c = { "clang-format" },
      rust = { "rustfmt" },
    },

    formatters = {
      ["google-java-format"] = {
        prepend_args = { "--aosp" },
      },
    },
  },

  keys = {
    {
      "<leader>F",
      function()
        require("conform").format({
          async = false,
          timeout_ms = 2000,
          lsp_format = "fallback",
        })
      end,
      desc = "手动格式化当前文件",
    },
  },
}
