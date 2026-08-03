-- ============================================
-- Mason 工具自动安装器
-- 在 :Mason 安装完成后自动安装预配置的工具列表
-- ============================================

return {
  "WhoIsSethDaniel/mason-tool-installer.nvim",
  event = "VeryLazy",
  dependencies = {
    "williamboman/mason.nvim",
  },
  opts = {
    ensure_installed = {
      "codelldb", -- C/C++/Rust 调试器（DAP 用）
      "java-debug-adapter", -- Java 调试器（DAP 用）
      "java-test", -- Java 测试运行器（DAP 用）
      "delve", -- Go 调试器（DAP 用）
      "stylua", -- Lua 格式化器
      "google-java-format", -- Java 格式化器
      "clang-format", -- C/C++ 格式化器
      "tree-sitter-cli", -- Treesitter 解析器安装器依赖
      -- rustfmt 由 rustup component add rustfmt 提供，无需 mason 安装
    },
  },
}
