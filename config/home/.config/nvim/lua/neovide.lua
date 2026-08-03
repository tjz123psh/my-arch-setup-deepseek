-- ============================================
-- Neovide GUI 专用配置
-- 只有在 Neovide 中启动时才会加载
-- ============================================

if not vim.g.neovide then
  return
end

-- 缩放比例（默认 1.0）
vim.g.neovide_scale_factor = 1.0

-- 窗口不透明度（0.8 = 80% 不透明，20% 透出桌面）
vim.g.neovide_opacity = 0.80

-- 光标特效风格
vim.g.neovide_cursor_vfx_mode = "railgun"

-- 设置字体（Linux 下优先使用 JetBrainsMono Nerd Font）
local font = "JetBrainsMono Nerd Font:h12"
if vim.fn.has("linux") == 1 and vim.fn.executable("fc-match") == 1 then
  local matched = vim.fn.systemlist({ "fc-match", "JetBrainsMono Nerd Font" })[1] or ""
  if not matched:lower():find("jetbrains", 1, true) then
    font = "monospace:h12"
  end
end
vim.o.guifont = font

-- 刷新率（Hz）
vim.g.neovide_refresh_rate = 60

-- 窗口圆角
vim.g.neovide_corner_style = "round"

-- 打字光标动画
vim.g.neovide_cursor_short_animation_length = 0.13

-- ============================================
-- 缩放快捷键（仅 Neovide，终端里的 nvim 由终端负责缩放）
-- 通过动态改写 neovide_scale_factor 实现，步进 10%
-- ============================================
local function change_scale(delta)
  local current = vim.g.neovide_scale_factor or 1.0
  local next_scale = current + delta
  -- 夹在 0.5x ~ 3.0x，避免缩到看不见或放到卡顿
  next_scale = math.min(3.0, math.max(0.5, next_scale))
  vim.g.neovide_scale_factor = next_scale
end

local map = vim.keymap.set
map("n", "<C-=>", function()
  change_scale(0.1)
end, { desc = "Neovide 放大" })
map("n", "<C-->", function()
  change_scale(-0.1)
end, { desc = "Neovide 缩小" })
map("n", "<C-0>", function()
  vim.g.neovide_scale_factor = 1.0
end, { desc = "Neovide 重置缩放" })
