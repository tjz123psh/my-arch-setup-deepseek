-- ============================================
-- 自动命令（Autocmds）
-- 在特定事件发生时自动执行某些操作
-- ============================================

-- 创建自动命令组（方便统一管理）
local augroup = vim.api.nvim_create_augroup("core", { clear = true })

-- Lua 文件跟随 stylua.toml，保持编辑缩进和格式化结果一致
vim.api.nvim_create_autocmd("FileType", {
  group = augroup,
  pattern = "lua",
  callback = function()
    vim.bo.tabstop = 2
    vim.bo.shiftwidth = 2
  end,
})

-- 打开 C/C++/Java/Python 文件时，设置缩进为 4 空格
vim.api.nvim_create_autocmd("FileType", {
  group = augroup,
  pattern = { "cpp", "c", "java", "python" },
  callback = function()
    vim.bo.tabstop = 4
    vim.bo.shiftwidth = 4
  end,
})

-- 进入插入模式时自动清除搜索高亮
-- 这样搜索后按 i 进入编辑，不会看到满屏黄色
vim.api.nvim_create_autocmd("InsertEnter", {
  group = augroup,
  callback = function()
    if vim.o.hlsearch then
      vim.o.hlsearch = false
    end
  end,
})
