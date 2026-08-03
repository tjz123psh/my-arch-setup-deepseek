-- 个人快捷键速查浮动窗口
-- 新增快捷键时顺手在对应分类加一行即可
-- 格式：{ "按键", "说明（模式）" }

local M = {}
local ns = vim.api.nvim_create_namespace("core_cheatsheet")

local state = {
  win = nil,
}

local sections = {
  {
    "行操作",
    {
      { "J", "下移当前行" },
      { "K", "上移当前行" },
      { "数字前缀 + J/K", "移动多行距离" },
      { "J / K", "下移/上移选中行（x）" },
      { "<leader>j", "合并下一行" },
    },
  },
  {
    "基础操作",
    {
      { "jk", "退出插入模式（i）" },
      { "jk", "退出终端模式（t）" },
      { "<C-s>", "保存文件（n,i）" },
      { "<C-CR>", "下方新建空行（i）" },
      { "s", "Flash 跳转（n,x,o）" },
      { "S", "Flash Treesitter 选择（n,x,o）" },
    },
  },
  {
    "窗口操作",
    {
      { "<C-h/j/k/l>", "切换窗口" },
      { "<leader>sh", "水平分割" },
      { "<leader>sv", "垂直分割" },
      { "<leader>q", "关闭窗口" },
      { "<leader>wq", "保存并关闭" },
    },
  },
  {
    "缓冲区",
    {
      { "<S-h>", "上一个缓冲区" },
      { "<S-l>", "下一个缓冲区" },
      { "<leader>ba", "关闭其他缓冲区" },
      { "<leader>bd", "关闭当前缓冲区" },
    },
  },
  { "文件树", {
    { "<leader>e", "打开/关闭文件树" },
  } },
  {
    "搜索（Telescope）",
    {
      { "<leader>ff", "搜索文件名" },
      { "<leader>fg", "搜索文件内容" },
      { "<leader>fb", "切换缓冲区" },
      { "<leader>fh", "搜索帮助" },
      { "<leader>fp", "搜索项目" },
      { "<leader>fc", "搜索 Neovim 配置" },
    },
  },
  {
    "代码导航（LSP）",
    {
      { "gd", "跳转到定义" },
      { "gR", "跳转到类型定义" },
      { "gr", "查找引用" },
      { "gi", "跳转到实现" },
      { "gh", "悬停文档" },
      { "[d / ]d", "上一个/下一个诊断" },
    },
  },
  {
    "代码操作",
    {
      { "<leader>rn", "重命名符号" },
      { "<leader>ca", "代码操作" },
      { "<leader>F", "格式化代码" },
      { "<C-k>", "函数签名提示（i）" },
    },
  },
  {
    "补全（blink.cmp）",
    {
      { "Enter / Tab", "选中当前项" },
      { "Tab / Shift-Tab", "前后跳转片段占位符" },
      { "<C-n> / <C-p>", "选择下一项/上一项" },
      { "<C-e>", "关闭补全菜单" },
      { "<C-u> / <C-d>", "文档翻页" },
    },
  },
  {
    "注释",
    {
      { "gcc", "注释/取消注释当前行（n）" },
      { "gc", "注释/取消注释选中（x）" },
    },
  },
  {
    "调试（DAP）",
    {
      { "<leader>dl", "重跑上次调试" },
      { "<leader>db", "断点列表（telescope）" },
      { "<leader>dB", "条件断点" },
      { "<leader>dL", "日志断点" },
      { "<leader>dC", "清除所有断点" },
      { "<F5>", "开始调试 / 继续" },
      { "<F9>", "切换断点" },
      { "<F10>", "单步跳过" },
      { "<F11>", "单步进入" },
      { "<F12>", "单步跳出" },
    },
  },
  {
    "终端（toggleterm）",
    {
      { "<leader>tt", "切换浮动终端" },
      { "<leader>th", "水平分割终端" },
      { "<leader>tv", "垂直分割终端" },
    },
  },
  {
    "Java",
    {
      { "<leader>co", "Java 代码操作" },
      { "<leader>ot", "整理 import" },
      { "<F5>", "Java 调试（输入主类名）" },
    },
  },
  {
    "Neovide（仅 GUI）",
    {
      { "<C-=>", "放大（+10%）" },
      { "<C-->", "缩小（-10%）" },
      { "<C-0>", "重置缩放" },
    },
  },
  {
    "自定义命令",
    {
      { ":R", "重载当前 Lua 配置文件" },
      { ":A", "打开欢迎页" },
      { ":Projects", "打开项目列表" },
      { ":LspInfo", "查看 LSP 客户端状态" },
      { ":LspLog", "打开 LSP 日志" },
      { ":JavaRun", "运行当前 Java 单文件" },
    },
  },
}

local function define_highlights()
  vim.api.nvim_set_hl(0, "CheatSheetTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "CheatSheetHint", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CheatSheetSection", { link = "Function", default = true })
  vim.api.nvim_set_hl(0, "CheatSheetSeparator", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "CheatSheetKey", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "CheatSheetText", { link = "NormalFloat", default = true })
end

local function pad_right(text, width)
  local padding = width - vim.fn.strdisplaywidth(text)
  if padding <= 0 then
    return text
  end
  return text .. string.rep(" ", padding)
end

local function close_existing()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    return true
  end
  return false
end

function M.show()
  if close_existing() then
    return
  end

  define_highlights()

  local lines = {}
  local marks = {}
  local key_marks = {}

  local available_width = math.max(1, vim.o.columns - 4)
  local width = math.min(84, available_width)
  local body_width = math.max(1, width - 4)
  local key_width = math.min(24, math.max(12, math.floor(body_width * 0.4)))

  local function add(line, hl)
    table.insert(lines, line)
    if hl then
      marks[#lines - 1] = hl
    end
  end

  add("  " .. pad_right("常用快捷键", body_width - 12) .. "q / Esc 关闭", "CheatSheetTitle")
  add("  " .. string.rep("─", body_width), "CheatSheetSeparator")

  for _, sec in ipairs(sections) do
    add("")
    add("  ▍ " .. sec[1], "CheatSheetSection")
    for _, item in ipairs(sec[2]) do
      local key = item[1]
      local line = "    " .. pad_right(key, key_width) .. item[2]
      add(line, "CheatSheetText")
      table.insert(key_marks, { row = #lines - 1, start_col = 4, end_col = 4 + #key })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local available_height = math.max(1, vim.o.lines - 4)
  local height = math.min(#lines, available_height)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local title = width >= 32 and " 快捷键速查  <leader>hk " or " 快捷键 "
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = row,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  state.win = win

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for row_idx, hl in pairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, row_idx, 0, {
      end_col = #lines[row_idx + 1],
      hl_group = hl,
    })
  end
  for _, mark in ipairs(key_marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.start_col, {
      end_col = mark.end_col,
      hl_group = "CheatSheetKey",
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "cheatsheet"
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, silent = true })
end

return M
