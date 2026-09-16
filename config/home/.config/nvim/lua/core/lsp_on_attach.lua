-- ============================================
-- 共享的 LSP on_attach
-- ============================================
-- 为什么单独放在 core/ 而不是 plugins/ 下：
--   core/lazy.lua 里是 `{ import = "plugins" }`，lazy 会递归把
--   lua/plugins/ 下**每个** .lua 当成插件 spec 加载。
--   本文件返回的是函数而不是 spec 表，放在 plugins/ 下会让 lazy 报错。
--
-- 谁在用这个模块：
--   1. plugins/lsp/init.lua —— nvim-lspconfig 托管的服务器
--   2. plugins/lang/java.lua —— nvim-jdtls 手动 start_or_attach 的 jdtls
--
-- 第 2 点很关键：lsp/init.lua 的 setup.jdtls 里 `return true` 跳过了
-- jdtls 的自动配置，所以 jdtls 不经过 nvim-lspconfig 的 on_attach。
-- 如果 java.lua 不显式传 on_attach，Java 缓冲区里 gd/gr/gh/rename
-- 这些导航键就全部失效（这正是之前缺的）。
-- ============================================

-- 不要用 client.server_capabilities.xxx 做门控：
-- Neovim 0.12 里 jdtls 通过 client/registerCapability 动态注册
-- definition / hover / rename / codeAction，这些键在 initialize 的静态
-- server_capabilities 里是 nil，门控会导致 gd / gh / <leader>ca / <leader>rn
-- 永久不注册（实测就是这样）。直接无条件映射，服务器不支持时调用本身会
-- 提示 "not supported"，不影响其他功能。
return function(_client, bufnr)
  local function map(mode, lhs, rhs, d)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = d })
  end

  -- 代码导航
  map("n", "gd", vim.lsp.buf.definition, "跳转到定义")
  map("n", "gR", vim.lsp.buf.type_definition, "跳转到类型定义")
  map("n", "gh", vim.lsp.buf.hover, "悬停显示文档")
  map("n", "gr", vim.lsp.buf.references, "查找所有引用")
  map("n", "gi", vim.lsp.buf.implementation, "跳转到实现")

  -- 诊断导航
  map("n", "[d", function()
    vim.diagnostic.jump({ count = -1, float = true })
  end, "上一个诊断")
  map("n", "]d", function()
    vim.diagnostic.jump({ count = 1, float = true })
  end, "下一个诊断")

  -- 重命名 / 代码操作 / 签名帮助
  map("n", "<leader>rn", vim.lsp.buf.rename, "重命名符号")
  map("n", "<leader>ca", vim.lsp.buf.code_action, "代码操作")
  map("i", "<C-k>", vim.lsp.buf.signature_help, "显示函数签名")
end
