-- ============================================
-- 外部工具安装器：mason.nvim
-- 管理 LSP 服务器、调试器、格式化器等外部工具
-- 配合 mason-tool-installer 自动安装
-- ============================================

return {
  "williamboman/mason.nvim",
  lazy = false,
  dependencies = {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
  },
  opts = {
    PATH = "prepend",
  },
}
