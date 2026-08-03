-- ============================================
-- 全局快捷键映射
-- 格式：map("模式", "按键", "命令", { desc = "说明" })
-- 模式：n=普通, i=插入, v=可视, x=选择, t=终端
-- ============================================

-- 自定义快捷键
local map = vim.keymap.set

-- 空格键自身不做任何事，只作为 leader 前缀等待后续按键
map("n", "<Space>", "<Nop>", { desc = "Leader 键" })

-- s、S 由 flash.nvim 接管：跳转到屏幕上任意可见位置
-- 插件自带映射：
--   <leader>e          neo-tree 文件树
--   <leader>tt/th/tv   toggleterm 终端
--   <leader>fp         Telescope 项目列表

-- jk 退出终端模式回到普通模式（:term 打开的终端）
-- 注意：终端内 j 后跟 k 会触发退出，注意误触
map("t", "jk", "<C-\\><C-n>", { desc = "退出终端模式" })

-- 窗口操作
map("n", "<C-h>", "<C-w>h", { desc = "切换到左边窗口" })
map("n", "<C-l>", "<C-w>l", { desc = "切换到右边窗口" })
map("n", "<C-j>", "<C-w>j", { desc = "切换到下边窗口" })
map("n", "<C-k>", "<C-w>k", { desc = "切换到上边窗口" })
map("n", "<leader>sh", "<cmd>split<cr>", { desc = "水平切分窗口" })
map("n", "<leader>sv", "<cmd>vsplit<cr>", { desc = "垂直切分窗口" })

-- 文件操作快捷键
map("n", "<C-s>", "<cmd>write<cr>", { desc = "保存当前文件" })
map("i", "<C-s>", "<C-o>:write<cr>", { desc = "保存当前文件（插入模式）" })
map("i", "<C-CR>", "<Esc>o", { desc = "在下方新建空行，继续编辑" })
map("n", "<leader>fc", function()
  require("telescope.builtin").find_files({ cwd = vim.fn.stdpath("config") })
end, { desc = "搜索 Neovim 配置文件" })
map("n", "<leader>q", "<cmd>q<cr>", { desc = "关闭当前窗口" })
map("n", "<leader>ba", "<cmd>BufferLineCloseOthers<cr>", { desc = "关闭其他缓冲区" })
map("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "关闭当前缓冲区（文件）" })
map("n", "<leader>wq", "<cmd>wq<cr>", { desc = "保存并关闭" })

-- 普通模式下移动当前行：J 下移，K 上移；支持数字前缀，例如 3J
local function move_current_line(direction)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2]
  local steps = vim.v.count1

  for _ = 1, steps do
    local line_count = vim.api.nvim_buf_line_count(0)
    if direction > 0 and row >= line_count then
      break
    end
    if direction < 0 and row <= 1 then
      break
    end

    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, {})

    if direction > 0 then
      vim.api.nvim_buf_set_lines(0, row, row, false, line)
      row = row + 1
    else
      vim.api.nvim_buf_set_lines(0, row - 2, row - 2, false, line)
      row = row - 1
    end
  end

  local moved_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { row, math.min(col, #moved_line) })
end

map("n", "J", function()
  move_current_line(1)
end, { desc = "下移当前行", silent = true })
map("n", "K", function()
  move_current_line(-1)
end, { desc = "上移当前行", silent = true })

-- 可视模式整块移动，使用 Lua 调用避免触发 noice 命令行浮窗
map("x", "J", function()
  vim.cmd("'<,'>move '>+1")
  vim.cmd("normal! gv=gv")
end, { desc = "向下移动选中行", silent = true })
map("x", "K", function()
  vim.cmd("'<,'>move '<-2")
  vim.cmd("normal! gv=gv")
end, { desc = "向上移动选中行", silent = true })

map("n", "<leader>j", "mzJ`z", { desc = "合并下一行", silent = true })

local cheatsheet = require("core.cheatsheet")
map("n", "<leader>hk", cheatsheet.show, { desc = "快捷键速查" })
