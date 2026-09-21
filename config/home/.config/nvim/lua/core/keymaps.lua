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

-- 判断当前缓冲区是否有真正的缩进计算来源。
-- 没有来源时 = 会把缩进清成 0（Markdown、纯文本的缩进本身就是内容，会被改坏），
-- 有 equalprg 时 = 会调用外部程序，这两种情况都跳过重缩进。
local function can_reindent()
  return vim.o.equalprg == "" and (vim.bo.indentexpr ~= "" or vim.bo.cindent or vim.o.lisp)
end

-- 可视模式整块移动：支持数字前缀，例如 3J / 3K
-- 不能用 '< '> 取范围：这两个标记要等离开可视模式后才写入，可视模式内读到的是
-- 未设定（E20 报错）或上一次的可视范围（会静默移动错误的行）。这里改用 line("v")
-- 与 line(".") 直接算出行号，再以数字范围调用 :move
local function move_visual_lines(direction)
  if not vim.bo.modifiable then
    return
  end

  local first = vim.fn.line("v")
  local last = vim.fn.line(".")
  if first > last then
    first, last = last, first
  end

  local steps = vim.v.count1
  -- :move {地址} 把范围移到该地址的下一行，所以地址要取在范围之外，并夹在缓冲区范围内
  local target
  local delta
  if direction > 0 then
    target = math.min(last + steps, vim.api.nvim_buf_line_count(0))
    delta = target - last
  else
    target = math.max(first - steps - 1, 0)
    delta = target + 1 - first
  end

  -- 已到缓冲区首/尾，什么都不做，避免 :move 报错
  if delta == 0 then
    return
  end

  vim.cmd(("silent keepjumps %d,%dmove %d"):format(first, last, target))

  local new_first = first + delta
  local new_last = last + delta

  -- 按行号重缩进，让移过去的行贴合新位置；不用可视选区，避免 = 结束时退出可视模式
  if can_reindent() then
    vim.cmd(("silent keepjumps %d,%dnormal! =="):format(new_first, new_last))
  end

  -- 重建选区。必须先退出可视模式：在可视模式内执行 gv 只会在 行块/字符 之间切换，
  -- 不会按标记恢复，行块选区会退化成字符选区。退出后 '< '> 也会被正确写入，再 gv 恢复原类型。
  vim.cmd("normal! \27")
  vim.fn.setpos("'<", { 0, new_first, 1, 0 })
  vim.fn.setpos("'>", { 0, new_last, 1, 0 })
  vim.api.nvim_win_set_cursor(0, { new_last, 0 })
  vim.cmd("normal! gv")
end

map("x", "J", function()
  move_visual_lines(1)
end, { desc = "下移选中行", silent = true })
map("x", "K", function()
  move_visual_lines(-1)
end, { desc = "上移选中行", silent = true })
-- select 模式（可视模式内按 <C-g>）不继承 x 映射，单独绑定，否则 J/K 会被当作输入插入
map("s", "J", function()
  move_visual_lines(1)
end, { desc = "下移选中行", silent = true })
map("s", "K", function()
  move_visual_lines(-1)
end, { desc = "上移选中行", silent = true })

map("n", "<leader>j", "mzJ`z", { desc = "合并下一行", silent = true })

local cheatsheet = require("core.cheatsheet")
map("n", "<leader>hk", cheatsheet.show, { desc = "快捷键速查" })
