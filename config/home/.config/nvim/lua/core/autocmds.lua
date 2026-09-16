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

-- ============================================
-- 自动保存
-- 在离开缓冲区、失去焦点、退出等"告一段落"的时机写盘，免去手动保存。
-- 刻意不用 CursorHold 空闲触发：那会让每次停顿都叠加 format_on_save，
-- 尤其 Java 格式化需起 JVM，开销大。
-- 临时关闭：vim.g.core_autosave = false
-- ============================================
local function autosave_current_buf()
  if vim.g.core_autosave == false then
    return
  end
  -- 仅保存有文件名、可修改、非只读且有改动的普通文件缓冲区
  if vim.bo.buftype ~= "" or not vim.bo.modifiable or vim.bo.readonly then
    return
  end
  if vim.api.nvim_buf_get_name(0) == "" or not vim.bo.modified then
    return
  end
  -- lockmarks 保留跳转列表和列位置，避免自动保存打断光标历史
  vim.cmd("silent! lockmarks write")
end

vim.api.nvim_create_autocmd({ "BufLeave", "FocusLost", "QuitPre", "VimLeavePre" }, {
  group = augroup,
  desc = "自动保存当前普通文件缓冲区",
  callback = autosave_current_buf,
})
