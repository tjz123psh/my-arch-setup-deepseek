-- ============================================================================
-- Spring Boot 项目向导（v6 单卡片 · noice 粉系）
-- ============================================================================
-- 与 IDEA New Project 对话框对齐的 11 步向导：
--   snacks.picker  全部选择步骤（自绘自适应单卡片：input + list + 底部说明行）
--   dressing.nvim  文本输入（LSP 重命名等共用同款粉卡，组定义见 SNACKS_HL）
--
-- v6 变更（相对 v5，按用户 noice 截图推倒重构）：
--   1. 弃用 default/select 预设，自绘 vertical box 布局：
--      边框画在 box 层；winhighlight 走 snacks 链接链的基座组
--      （SnacksPickerBorder/Title/…），启动时定义实色即可全程截胡
--   2. 右侧预览 → 底部 3 行说明区（preview 窗逐字换行 + 分段着色）
--   3. 单选步行只显示 id，hint 挪到底部行；确认步底部行 = 摘要 → 路径
--   4. 配色直写 catppuccin-mocha；v6.1 面板透明（bg=NONE、无 backdrop），同其它浮窗
--
-- 放在 core/ 而非 plugins/：core/lazy.lua 用 { import = "plugins" }，
-- lazy 会把 plugins/ 下每个 .lua 当 spec 递归加载，本文件返回的是模块。
-- ============================================================================

local M = {}

----------------------------------------------------------------------------
-- 1. 主题与共享文案（改样式只动这里）
----------------------------------------------------------------------------
-- （v3 时代的 UI 常量表 / QUICK_TIPS / TOTAL_STEPS 全部零引用，v6.4 清理）

-- 前向声明：load_meta（异步版）在文件后段才定义的 bridge 之前，
-- Lua local 作用域不到 → 直接跑会把 bridge 当 nil 全局，flow 静默死掉
local bridge

local meta_cache = nil
local meta_cached_at = 0
local META_TTL = 600  -- 秒；跨天会话不吃过期依赖表

----------------------------------------------------------------------------
-- 2. start.spring.io 元数据
----------------------------------------------------------------------------
-- 异步版：旧实现 vim.system():wait() 同步等待，弱网时整个 Neovim 冻结最长
-- 25 秒。现在走 bridge（flow 本来就在协程里），UI 保持响应；超时降到 8 秒。
local function load_meta()
  return bridge(function(done)
    if meta_cache and (vim.uv.now() / 1000 - meta_cached_at) < META_TTL then
      done(meta_cache)
      return
    end
    local oksys = pcall(vim.system, {
      "curl", "-s", "--max-time", "8", "https://start.spring.io/metadata/client",
    }, { text = true }, function(res)
      vim.schedule(function()
        if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
          done(nil, "取不到 start.spring.io 元数据（网络或代理问题）")
          return
        end
        local okd, decoded = pcall(vim.fn.json_decode, res.stdout)
        if okd and type(decoded) == "table" and decoded.bootVersion then
          meta_cache = decoded
          meta_cached_at = vim.uv.now() / 1000
          done(decoded)
        else
          done(nil, "元数据解析失败")
        end
      end)
    end)
    if not oksys then
      done(nil, "找不到 curl 命令")
    end
  end)
end

-- start.spring.io 的 bootVersion id 带 .RELEASE 后缀，但仓库里只有去后缀的版本
-- （实测 4.1.1.RELEASE → 404，4.1.1 → 200，阿里云/central 一致），必须剥掉
local function normalize_boot(id)
  return (id:gsub("%.RELEASE$", ""))
end

-- 预发布形态实测有 4.2.0.M1 / 4.2.0.BUILD-SNAPSHOT / 4.1.1.RELEASE，
-- Maven 风格连字符（4.3.0-RC1、4.3.0-M5）也要判住，否则会被标成"最新正式版"
local function is_prerelease(id)
  return id:find("SNAPSHOT") ~= nil
    or id:match("[%-._][MR][%d]+$") ~= nil
    or id:match("[%-._]BUILD$") ~= nil
end

local function vcmp(a, b)
  local pa, pb = {}, {}
  for x in a:gmatch("%d+") do pa[#pa + 1] = tonumber(x) end
  for x in b:gmatch("%d+") do pb[#pb + 1] = tonumber(x) end
  for i = 1, math.max(#pa, #pb) do
    local diff = (pa[i] or 0) - (pb[i] or 0)
    if diff ~= 0 then return diff end
  end
  return 0
end

-- 组名太长会被列宽截成 "VMware Tanzu Sp~"，给啰嗦的组起短名
local GROUP_SHORT = {
  ['VMware Tanzu Spring Enterprise Extensions'] = 'Tanzu Ent',
  ['VMware Tanzu Application Service'] = 'Tanzu AppSvc',
  ['VMware Tanzu Spring SDK'] = 'Tanzu SDK',
  ['Spring Cloud Circuit Breaker'] = 'Cloud Breaker',
  ['Spring Cloud Discovery'] = 'Cloud Discovery',
  ['Spring Cloud Config'] = 'Cloud Config',
  ['Spring Cloud Messaging'] = 'Cloud Messaging',
  ['Spring Cloud'] = 'Cloud',
  ['Developer Tools'] = 'Dev Tools',
  ['Template Engines'] = 'Templates',
  ['Observability'] = 'Observe',
}

local function short_group(name)
  return GROUP_SHORT[name] or name
end

local function boot_options(meta)
  local out = {}
  for _, v in ipairs(meta.bootVersion.values or {}) do
    if type(v.id) == "string" then
      local real = normalize_boot(v.id)
      local pre = is_prerelease(v.id)
      out[#out + 1] = { id = v.id, real = real, pre = pre }
    end
  end
  table.sort(out, function(a, b)
    if a.pre ~= b.pre then return not a.pre end
    return vcmp(a.real, b.real) > 0
  end)
  return out
end

local function simple_options(node)
  local out = {}
  for _, v in ipairs(node and node.values or {}) do
    if type(v.id) == "string" then
      out[#out + 1] = { id = v.id }
    end
  end
  return out
end

-- 元数据本身就是两层：分组 → 依赖。保留 group / description 供列表与预览用。
local function dependency_options(meta)
  local out, seen = {}, {}
  local function try_add(node, group)
    if type(node) ~= "table" then return end
    -- 分组节点只有 name 没有 id，这个判断只会收进真正的依赖
    if type(node.id) == "string" and type(node.name) == "string" and not seen[node.id] then
      seen[node.id] = true
      out[#out + 1] = {
        id = node.id,
        name = node.name,
        group = short_group(group or "Other"),
        description = type(node.description) == "string" and node.description or "",
      }
    end
  end
  local function walk(node, group)
    if type(node) ~= "table" then return end
    local g = group
    if type(node.name) == "string" and type(node.values) == "table" then
      g = node.name
    end
    try_add(node, group)
    for _, v in pairs(node) do
      if type(v) == "table" then walk(v, g) end
    end
  end
  walk(meta.dependencies, nil)
  table.sort(out, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    return a.id < b.id
  end)
  return out
end

----------------------------------------------------------------------------
-- 3. 文本工具
----------------------------------------------------------------------------
-- 按显示宽度截断/补齐。这几个字段都是 ASCII，字节长度够用。
local function cut(text, width)
  text = text or ""
  if #text <= width then
    return text .. string.rep(" ", width - #text)
  end
  if width <= 1 then return string.sub(text, 1, width) end
  return string.sub(text, 1, width - 1) .. "\226\128\166"
end

-- 仅用于最后一列的截断：… 占 3 字节 1 列，telescope 算列位置用的是字节长度，
-- 放在中间列会让后面的分隔线错位，所以只在末列用它。
local function cut_last(text, width)
  text = text or ""
  if #text <= width then return text end
  if width <= 1 then return string.sub(text, 1, width) end
  return string.sub(text, 1, width - 1) .. "\226\128\166"
end

-- 包名里非法字符替换为下划线（实测 hyphen 会被 CLI 自动转 _，这里再兜底）
local function sanitize_package(s)
  local out = (s:gsub("[^%w%.]", "_"))
  out = out:gsub("^%d", "_")
  return out
end

-- group/artifact/name 的合法性：字母数字点横线下划线，禁路径分隔、禁 - 开头
-- （- 开头会被 spring CLI 当选项解析，实测 'offline is not a recognized option'；
--  含 / 或 .. 会把项目写到 parent 之外——CLI 照建不误 exit 0，静默目录逃逸）
local function valid_segment(s)
  if type(s) ~= "string" or s == "" or s == "." or s == ".." then return false end
  if s:sub(1, 1) == "-" then return false end
  return s:match("^[%w%._%-]+$") ~= nil
end
-- 4. UI 桥与视觉主题
-- ----------------------------------------------------------------------------

-- ===== noice 同款粉系主题（catppuccin-mocha v5）=====
-- 设计基准：底 #1E1E2E、边框 #F38BA8、选中 #F5C2E7、徽章 #FAB387。
-- 终端物理限制（没有透明/发光渲染），用深色面板、下划线、字重近似 noice。
-- 边框通过 timer 在粉色阶之间缓慢呼吸；圆角用 ╭╮╰╯ 字符。
-- v5：改用 noice 通知弹框那一套（catppuccin-mocha 粉系），和编辑器主题同族
local NEON = {
  bg      = "#1E1E2E",  -- catppuccin base：noice 弹框同款底
  border  = "#F38BA8",  -- noice 粉
  borderB = "#F5A0B8",
  borderC = "#E893AC",
  sun     = "#F5C2E7",  -- 选中行文字（catppuccin pink）
  white   = "#CDD6F4",  -- 主文字（text）
  grey    = "#A6ADC8",  -- 次文字（subtext1）
  dim     = "#585B70",  -- 未选中 □ / 空态（overlay0）
  magenta = "#CBA6F7",  -- 过滤匹配词 / 计数器（catppuccin mauve）
  amber   = "#FAB387",  -- 分组徽章 / 行内 hint（peach）
  green   = "#A6E3A1",  -- ❯ 提示符（catppuccin green）
  rowbg   = "#313244",  -- （弃用）旧选中行底
}

local HL_DEFS = {
  { "WizBg",        { bg = "NONE" } },  -- 透明底：和编辑器其它浮窗同风格（kitty 全局透明度）
  { "WizBorder",    { fg = NEON.border } },
  { "WizTitle",     { fg = NEON.border, bold = true } },
  { "WizCursorLine",{ bg = NEON.rowbg, fg = NEON.sun, bold = true, underline = true, sp = NEON.border } },
  { "WizKey",       { fg = NEON.white } },
  { "WizSel",       { fg = NEON.sun, bold = true } },
  { "WizBadge",     { fg = NEON.amber, bold = true } },
  { "WizHint",      { fg = NEON.grey } },
  { "WizDim",       { fg = NEON.dim } },
  { "WizMagenta",   { fg = NEON.magenta, bold = true } },
  { "WizMarker",    { fg = NEON.border, bold = true } },  -- 行首 ▸ 指针
  { "WizPeach",     { fg = NEON.amber } },                -- 行内 hint（不加粗）
  { "WizMenuSel",   { fg = NEON.sun, bold = true } },     -- dressing 菜单当前行（纯文字色）
}

-- 根治「边框一直是主题蓝」：snacks 的 winhighlight 不用我们给的字符串
-- （init_layout 会 force 覆盖），而是用 winhl() 给每个窗口生成链接组：
--   FloatBorder → SnacksPickerListBorder → SnacksPickerBorder → FloatBorder
-- 这些链接全部以 default=true 注册。所以只要启动时先把「基座组」定义成
-- 非 default 的实色，snacks 的默认注册就永远盖不掉我们，整条链变色。
local SNACKS_HL = {
  { "SnacksPicker",           { bg = "NONE", fg = NEON.white } },   -- NormalFloat 基座：透明底
  { "SnacksPickerBorder",     { fg = NEON.border } },               -- 所有窗口边框
  { "SnacksPickerTitle",      { fg = NEON.border, bold = true } }, -- 窗口标题
  -- ⚠ SnacksPicker*CursorLine 不在此列：它们是全局基座（snacks 所有 picker
  -- 的当前行都链过来），常驻覆盖会杀掉其它 picker 的选中行高亮。
  -- 向导会话内的临时压制见 TRANSIENT_HL（随 start/stop_pulse 应用与还原）。
  { "SnacksPickerFooter",     { fg = NEON.dim } },
  { "SnacksTitle",            { fg = NEON.border, bold = true } }, -- box 边框窗标题
  { "SnacksNormal",           { bg = "NONE", fg = NEON.white } },  -- box 边框窗：透明底
  { "SnacksNormalNC",         { bg = "NONE", fg = NEON.white } },
  { "SnacksPickerTotals",     { fg = NEON.magenta, bold = true } }, -- 计数器 mauve
  { "SnacksPickerPrompt",     { fg = NEON.green, bold = true } },    -- ❯ 提示符 green
  { "SnacksPickerMatch",      { fg = NEON.magenta, bold = true } },-- 过滤匹配词
  { "SnacksPickerSelected",   { fg = NEON.border, bold = true } }, -- ● 已选
  { "SnacksPickerUnselected", { fg = NEON.dim } },                  -- ○ 未选
}

local function define_highlights()
  for _, d in ipairs(HL_DEFS) do
    vim.api.nvim_set_hl(0, d[1], d[2])
  end
  for _, s in ipairs(SNACKS_HL) do
    vim.api.nvim_set_hl(0, s[1], s[2])
  end
end

-- 边框呼吸：WizBorder 在三个粉色之间缓慢过渡（1.2s 一步）
local border_timer = nil
local border_step = 0
-- generation 守卫：stop 后 schedule 里排队的最后一发改色不能晚于 reset 落地
-- （声明必须在使用它的 stop/start 之前——local 作用域坑，上一版就栽过）
local pulse_gen = 0

-- 向导会话专属的高亮压制：我们的当前行标注是行首 ▸ + 文字色（format 里画），
-- 不需要底色条；但 SnacksPicker*CursorLine 是全局基座，常驻改会误伤其它
-- picker。所以只在向导开着的窗口期内压成 NONE，关掉就还原原 link。
local TRANSIENT_HL = {
  { "SnacksPickerCursorLine",     { bg = "NONE" } },
  { "SnacksPickerListCursorLine", { bg = "NONE" } },
}
local transient_saved = {}
local function apply_transient_hl()
  for _, d in ipairs(TRANSIENT_HL) do
    if transient_saved[d[1]] == nil then
      transient_saved[d[1]] = vim.api.nvim_get_hl(0, { name = d[1], link = true })
    end
    vim.api.nvim_set_hl(0, d[1], d[2])
  end
end
local function restore_transient_hl()
  for _, d in ipairs(TRANSIENT_HL) do
    local saved = transient_saved[d[1]]
    if saved and next(saved) ~= nil then
      pcall(vim.api.nvim_set_hl, 0, d[1], saved)
    end
    transient_saved[d[1]] = nil
  end
end

local function stop_pulse()
  pulse_gen = pulse_gen + 1
  if border_timer then
    pcall(vim.uv.timer_stop, border_timer)
    pcall(vim.uv.timer_close, border_timer)
    border_timer = nil
  end
  pcall(vim.api.nvim_set_hl, 0, "WizBorder", { fg = NEON.border })
  restore_transient_hl()
end
local function start_pulse()
  stop_pulse()
  apply_transient_hl()
  pulse_gen = pulse_gen + 1
  local my_gen = pulse_gen
  border_step = 0
  border_timer = vim.uv.new_timer()
  border_timer:start(0, 1200, function()
    border_step = border_step + 1
    local c = ({ NEON.border, NEON.borderB, NEON.borderC })[(border_step % 3) + 1]
    vim.schedule(function()
      if my_gen ~= pulse_gen then return end
      pcall(vim.api.nvim_set_hl, 0, "WizBorder", { fg = c })
    end)
  end)
end

-- ===== 单卡片布局（v6 推倒重构）=====
-- 结构（一个圆角卡片，无右侧预览）：
--   ╭───────── 标题（粉色加粗，居中）─────────╮
--   ❯ 过滤输入…                        204/204 │
--   ──────────────────────────────────────────
--   ○ id                     名称              │
--   ──────────────────────────────────────────
--   名称 · [分组] · 完整描述（当前项，一行截断）│
--   ╰──────────────────────────────────────────╯
-- 边框粉色的真实来源（子代理对照 snacks 源码验证过）：box 表顶层的
-- winhighlight 字符串是死配置（Snacks.win 只消费 wo.winhighlight），
-- 生效的是 picker.lua 给 box 窗合并的 winhl("SnacksPickerBox") 链接链
-- → SnacksPickerBoxBorder → SnacksPickerBorder，被我们启动时定义的非
-- default 实色截胡。所以配色只写在 SNACKS_HL 一处，这里不放死配置。
-- 卡片宽度自适应：目标 104 列，终端窄就让到 columns-2（snacks 也会钳制）。
-- id 列必须完整不截断（主键），最长的 AI id 有 42 字符，所以 90 列不够。
local function card_w() return math.min(104, vim.o.columns - 2) end
local FOOT_LINES = 3   -- 底部说明区行数（卡片高度恒定）
local CARD_BORDER = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
local FOOT_NS = vim.api.nvim_create_namespace("wiz_footer")

-- footer_on=false 时隐藏 preview 窗（短 hint 直接排行内，卡片更矮）
local function card_layout(list_h, footer_on)
  footer_on = footer_on ~= false
  return {
    -- ⚠ Lua 坑：x and nil or y 恒等于 y（and nil 永远短路到 or），
    -- 之前这样写导致详情区自 v6.2 起永远被隐藏。必须先判 not 再选表。
    hidden = (not footer_on) and { "preview" } or nil,
    layout = {
      box = "vertical",
      backdrop = false,
      width = card_w(),
      -- input 1 + list + footer(3|0) + 上下边框 2
      height = list_h + (footer_on and FOOT_LINES or 0) + 3,
      border = CARD_BORDER,
      title = "{title}",
      title_pos = "center",
      { win = "input", height = 1, border = "bottom" },
      { win = "list", border = "none" },
      { win = "preview", height = FOOT_LINES, border = "top" },
    },
  }
end

-- win.Config 只接受 input / list / preview 三个键；backdrop 只能放单个窗口里
-- （config/init.lua 的 fix_keys 会对 opts.win 做 pairs 取 win.keys，数字会炸）。
-- 注意：这里的 winhighlight 写了也没用（init_layout 用 winhl() 生成的覆盖），
-- 变色全走上面 SNACKS_HL 的基座组。win 配置只管 backdrop / wo / minimal。
local function win_config()
  -- keys 必须放 win.input / win.list——snacks 只消费这两处（顶层 Config 没有
  -- keys 字段，写 pick{keys=...} 是死配置）。C-s 完成 = 文档承诺的行为。
  -- 必须显式给 mode：snacks 的字符串 spec 默认只注册 normal（win.lua:288），
  -- 而输入框常态是 insert——只绑 n 的话 insert 下按 C-s 没反应
  local ks = { ["<c-s>"] = { "confirm", mode = { "n", "i" } } }
  return {
    input = {
      keys = ks,
      wo = { winblend = 0, number = false, signcolumn = "no", wrap = false },
    },
    list = {
      keys = ks,
      -- 不设 backdrop：透明底后压暗反而成了一块死黑，和「跟其他地方一样」矛盾
      wo = { winblend = 0, number = false, relativenumber = false, signcolumn = "no", wrap = false },
    },
    preview = {
      minimal = true, -- preview.lua: number = minimal ~= true，不开这个底部行会有行号
      wo = { winblend = 0, wrap = false },
    },
  }
end

-- 底部说明区：固定 FOOT_LINES 行（卡片高度恒定），逐字换行 + 分段着色
-- 左右边框各占 1 列（preview 窗内容宽 = 卡片宽 - 2）
local function footer_width() return card_w() - 2 end

-- UTF-8 逐字符展平；宽度按显示列算：ASCII=1，其余（CJK 等）=2
local function flatten_chunks(chunks)
  local out = {}
  for _, c in ipairs(chunks) do
    local text, hl = c[1] or "", c[2]
    local i = 1
    while i <= #text do
      local b = text:byte(i)
      local clen = (b < 0x80) and 1 or ((b < 0xE0) and 2 or ((b < 0xF0) and 3 or 4))
      local s = text:sub(i, i + clen - 1)
      out[#out + 1] = { s = s, hl = hl, w = (clen > 1) and 2 or 1 }
      i = i + clen
    end
  end
  return out
end

-- 排成最多 max_lines 行；每行返回 { text=整行文本, segs={ {s=字节起,e=字节止,hl} } }
local function layout_footer(chunks, width, max_lines)
  local flat = flatten_chunks(chunks)
  local lines = { { text = "", segs = {} } }
  local cur, w = lines[1], 0
  local seg_s, seg_hl = 0, nil
  local function flush()
    if seg_hl and #cur.text > seg_s then
      cur.segs[#cur.segs + 1] = { s = seg_s, e = #cur.text, hl = seg_hl }
    end
  end
  for _, ch in ipairs(flat) do
    if w + ch.w > width then
      if #lines >= max_lines then break end -- 装不下就截尾，不加省略号（3*86 列足够描述）
      flush()
      lines[#lines + 1] = { text = "", segs = {} }
      cur, w, seg_s, seg_hl = lines[#lines], 0, 0, nil
    end
    if seg_hl ~= ch.hl then
      flush()
      seg_s, seg_hl = #cur.text, ch.hl
    end
    cur.text = cur.text .. ch.s
    w = w + ch.w
  end
  flush()
  return lines
end

local function footer_preview(preview_of)
  return function(ctx)
    local it = ctx.item and ctx.item.item
    if not it then return false end
    pcall(function() vim.bo[ctx.buf].modifiable = true end)
    local ok, chunks = pcall(preview_of, it)
    if not ok then chunks = { { tostring(chunks), "WizHint" } } end
    local lines = layout_footer(chunks or {}, footer_width(), FOOT_LINES)
    local text = {}
    for _, l in ipairs(lines) do text[#text + 1] = l.text end
    while #text < FOOT_LINES do text[#text + 1] = "" end
    vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, text)
    pcall(vim.api.nvim_buf_clear_namespace, ctx.buf, FOOT_NS, 0, -1)
    for li, l in ipairs(lines) do
      for _, sg in ipairs(l.segs) do
        pcall(vim.api.nvim_buf_add_highlight, ctx.buf, FOOT_NS, sg.hl or "WizHint", li - 1, sg.s, sg.e)
      end
    end
    return true
  end
end

-- dressing 的回调可能同步也可能异步触发，两种顺序都要接住，否则流程卡死
bridge = function(caller)
  local co = coroutine.running()
  local arrived, data = false, nil
  local function deliver(...)
    if coroutine.status(co) == "suspended" then
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        vim.notify("向导内部错误：" .. tostring(err), vim.log.levels.ERROR)
      end
    else
      arrived, data = true, { ... }
    end
  end
  caller(deliver)
  if arrived then return unpack(data) end
  local ret = { coroutine.yield() }
  return unpack(ret)
end

-- 文本输入仍走 dressing（snacks.input 已关闭，避免抢 noice/dressing 的活）
-- 注意：不能用 vim.ui.input 的 default 参数——dressing 会把默认值预填进输入框，
-- 用户直接打字会追加到预填文本后面（tmux 实测：路径拼错→目录不存在→静默退出）。
-- 改成：默认值只写进提示里，空输入 = 采用默认值。
local function ask(prompt, default)
  return bridge(function(done)
    local shown = default and (prompt .. " [" .. default .. "]") or prompt
    vim.ui.input({ prompt = shown }, function(text)
      if text == nil then
        done(nil)
      elseif text == "" then
        done(default)
      else
        done(text)
      end
    end)
  end)
end

local function cancel()
  vim.notify("已取消，未改动任何文件", vim.log.levels.INFO)
end



----------------------------------------------------------------------------
-- 5. 单选与多选（snacks.picker）
----------------------------------------------------------------------------
-- 为什么从 dressing+nui / telescope 换成 snacks：
--   1. dressing+nui 只能整行一个颜色，做不出「主键亮 + 说明暗 + 勾选列」
--   2. 你装的这个 nui 版本没有 preview、没有模糊搜索（menu/init.lua 仅 377 行）
--   3. telescope 有原生多选但风格与 nui 割裂，且要手写 borderchars 才勉强像卡片
--   snacks.picker 的 format 返回 Highlight 数组（逐段着色），勾选列与预览都是内置
--   而且 <Tab> 默认就绑了 select_and_next（勾选并下移），正是你要的交互

-- 单选卡片：行 = ▸指针 + id + peach hint（行内直排，默认无底部详情区）
-- items: { id = ..., hint = ... }；opts.footer=true 时启用 3 行详情区，
-- opts.preview: fun(item) -> Highlight[]（仅 footer 模式使用）
local function pick_one(items, title, opts)
  opts = opts or {}
  local footer_on = opts.footer == true
  local preview_of = opts.preview or function(d)
    return { { d.hint or "", "WizHint" } }
  end
  return bridge(function(done)
    if #items == 0 then
      -- 元数据异常 ≠ 用户取消：给明确错误，别冒充「已取消」
      vim.schedule(function()
        vim.notify("向导内部错误：" .. title .. " 没有可选项（元数据异常）", vim.log.levels.ERROR)
        done(nil)
      end)
      return
    end
    local completed = false
    local picker = Snacks.picker.pick({
      source = "select",
      title = title,
      layout = card_layout(math.max(math.min(#items, 10), 2), footer_on),
      win = win_config(),
      finder = function()
        local ret = {}
        for idx, it in ipairs(items) do
          ret[#ret + 1] = {
            idx = idx,
            item = it,
            text = (it.id or "") .. " " .. (it.hint or ""),
          }
        end
        return ret
      end,
      format = function(item, picker)
        local d = item.item or item
        local cur = picker and picker.list and picker.list:current()
        local is_cur = cur == item
        if footer_on then
          return {
            { is_cur and "▸ " or "  ", is_cur and "WizMarker" or "WizDim" },
            { d.id or "", is_cur and "WizSel" or "WizKey" },
          }
        end
        return {
          { is_cur and "▸ " or "  ", is_cur and "WizMarker" or "WizDim" },
          { d.id or "", is_cur and "WizSel" or "WizKey" },
          { "  " },
          { d.hint or "", "WizPeach" },
        }
      end,
      preview = footer_on and footer_preview(preview_of) or function() return false end,
      filter = {},
      actions = {
        confirm = function(pk, pitem)
          -- 必须先置守卫再 close：否则 close 触发的 on_close 会抢先
          -- deliver(nil)，协程带着 nil 恢复，流程误判成「用户取消」
          if completed then return end
          completed = true
          stop_pulse()
          local chosen = pitem and pitem.item
          pcall(function() pk:close() end)
          vim.schedule(function() done(chosen) end)
        end,
      },
      on_close = function()
        if completed then return end
        completed = true
        stop_pulse()
        vim.schedule(function() done(nil) end)
      end,
    })
    -- snacks 对同 source 的活动 picker 会静默 close 旧的并返回 nil
    -- （picker/init.lua dedupe）——不兜底就是协程永久挂起 + timer 永转
    if not picker then
      vim.schedule(function() done(nil) end)
      return
    end
    start_pulse()
  end)
end

-- 依赖多选：Tab 勾选（snacks 默认键位）、Enter 确认
local function pick_deps(all_deps)
  return bridge(function(done)
    local completed = false

    -- id 是主键：列宽 = 实际最长 id，绝不截断（最长的 AI id 42 字符）。
    -- 名称列拿剩余，截断用 …（完整名在底部详情区）；窄终端时名称优先让位。
    local w_id = 0
    for _, d in ipairs(all_deps) do
      w_id = math.max(w_id, #(d.id or ""))
    end
    w_id = math.max(w_id, 8)
    local w_name = math.max(card_w() - 12 - w_id - 2, 12)

    local picker = Snacks.picker.pick({
      source = "select",
      title = "6. 选择依赖",
      layout = card_layout(14, true),
      win = win_config(),
      -- 每行都显示勾选框：○ 未选 / ● 已选（Tab 切换，snacks 内置列）
      formatters = { selected = { show_always = true, unselected = true } },
      finder = function()
        local ret = {}
        for idx, d in ipairs(all_deps) do
          ret[#ret + 1] = {
            idx = idx,
            item = d,
            text = (d.group or "") .. " " .. (d.id or "") .. " " .. (d.name or ""),
          }
        end
        return ret
      end,
      format = function(item, picker)
        local d = item.item or item
        local cur = picker and picker.list and picker.list:current()
        local is_cur = cur == item
        return {
          { is_cur and "▸ " or "  ", is_cur and "WizMarker" or "WizDim" },
          { cut(d.id, w_id), is_cur and "WizSel" or "WizKey" },
          { "  " },
          { cut_last(d.name, w_name), is_cur and "WizSel" or "WizHint" },
        }
      end,
      -- 底部说明行：名称 · [分组] · 完整描述（一行，超长截断）
      preview = footer_preview(function(d)
        return {
          { d.name or "", "WizKey" },
          { "  ·  ", "WizDim" },
          { "[" .. (d.group or "") .. "]", "WizBadge" },
          { "  ·  ", "WizDim" },
          { d.description or "", "WizHint" },
        }
      end),
      filter = {},
      actions = {
        confirm = function(pk)
          if completed then return end
          completed = true
          stop_pulse()
          local sel = pk.list and pk.list.selected or {}
          -- snacks 内部 selected 目前是数组（list.lua table.insert/tbl_filter）；
          -- 若上游改成 map，ipairs 会静默得 0 项——断言把它变成显式报错
          if not vim.islist(sel) then
            vim.notify("向导内部错误：snacks 多选结构变化（selected 非数组），请检查 snacks 版本", vim.log.levels.ERROR)
          end
          local ids = {}
          for _, it in ipairs(sel) do
            if it.item and it.item.id then ids[#ids + 1] = it.item.id end
          end
          pcall(function() pk:close() end)
          vim.schedule(function() done(ids) end)
        end,
      },
      on_close = function()
        if completed then return end
        completed = true
        stop_pulse()
        vim.schedule(function() done(nil) end)
      end,
    })
    if not picker then
      vim.schedule(function() done(nil) end)
      return
    end
    start_pulse()
  end)
end

----------------------------------------------------------------------------
-- 6. 主流程（字段顺序对齐 IDEA New Project）
----------------------------------------------------------------------------
local function find_main_class(dir)
  -- 语言步可以选 kotlin，主类模式也得跟上，否则建完 kotlin 项目不开主类
  for _, pat in ipairs({
    "src/main/java/**/*Application.java", "src/main/java/**/*.java",
    "src/main/kotlin/**/*Application.kt", "src/main/kotlin/**/*.kt",
  }) do
    local found = vim.fn.globpath(dir, pat, true, true)
    if found[1] then return found[1] end
  end
  return nil
end

local function flow()
  define_highlights()
  local meta, err = load_meta()
  if not meta then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local build = pick_one({
    { id = "maven",  hint = "pom.xml + mvnw" },
    { id = "gradle", hint = "build.gradle.kts + gradlew" },
  }, "1. 构建工具")
  if not build then return cancel() end

  local langs = simple_options(meta.language)
  if #langs == 0 then langs = { { id = "java" } } end
  local lang_items = {}
  for i, l in ipairs(langs) do
    lang_items[i] = { id = l.id, hint = l.id == "java" and "推荐" or "" }
  end
  local lang = pick_one(lang_items, "2. 语言")
  if not lang then return cancel() end

  local jvers = simple_options(meta.javaVersion)
  table.sort(jvers, function(a, b) return vcmp(a.id, b.id) > 0 end)
  local jv_items = {}
  for i, v in ipairs(jvers) do
    local hint = ""
    if v.id == "21" then hint = "LTS，推荐" elseif v.id == "17" then hint = "最低可用" end
    jv_items[i] = { id = v.id, hint = hint }
  end
  local jv = pick_one(jv_items, "3. Java 版本")
  if not jv then return cancel() end

  local boots = boot_options(meta)
  local boot_items = {}
  for i, b in ipairs(boots) do
    local hint = "正式版"
    if b.pre then hint = "预发布，可能拉不到" elseif i == 1 then hint = "最新正式版" end
    boot_items[i] = { id = b.real, hint = hint }
  end
  local bv = pick_one(boot_items, "4. Spring Boot 版本")
  if not bv then return cancel() end

  local packs = simple_options(meta.packaging)
  if #packs == 0 then packs = { { id = "jar" } } end
  local pack_items = {}
  for i, v in ipairs(packs) do
    pack_items[i] = {
      id = v.id,
      hint = v.id == "jar" and "可执行 jar，内嵌 Tomcat" or "部署到外部容器",
    }
  end
  local pkg = pick_one(pack_items, "5. 打包方式")
  if not pkg then return cancel() end

  local all_deps = dependency_options(meta)
  local deps = pick_deps(all_deps)
  if not deps then return cancel() end

  local group = ask("7. Group ID（组织反写域名）: ", "com.example")
  if not group then return cancel() end
  if not valid_segment(group) then
    vim.notify("Group ID 不合法（只允许字母数字和 . - _，不能以 - 开头）：" .. group, vim.log.levels.ERROR)
    return
  end
  local artifact = ask("8. Artifact ID（小写，建议无连字符）: ", "demo")
  if not artifact then return cancel() end
  if not valid_segment(artifact) then
    vim.notify("Artifact ID 不合法（不能含 / 或空格，不能以 - 开头）：" .. artifact, vim.log.levels.ERROR)
    return
  end
  local name = ask("9. 项目名 / 目录名: ", artifact)
  if not name then return cancel() end
  if not valid_segment(name) then
    vim.notify("项目名不合法（不能含 / 或空格，不能以 - 开头，不能是 . 或 ..）：" .. name, vim.log.levels.ERROR)
    return
  end
  local pkgname = ask("10. 包名: ", sanitize_package(group .. "." .. artifact))
  if not pkgname then return cancel() end
  local parent = ask("11. 创建到哪个目录下: ", vim.fn.getcwd())
  if not parent then return cancel() end
  parent = vim.fn.expand(parent)
  local pstat = vim.uv.fs_stat(parent)
  if not pstat or pstat.type ~= "directory" then
    -- fs_stat 对普通文件也返回非 nil——必须查 type，否则 vim.system 坏 cwd
    -- 抛错后被误报成「找不到 spring 命令」
    vim.notify("目录不存在或不是目录：" .. parent, vim.log.levels.ERROR)
    return
  end
  -- 目标已存在时提前拦截：spring init 会失败/留下半截目录，不如在这里说清楚
  if vim.uv.fs_stat(parent .. "/" .. name) ~= nil then
    vim.notify("目标目录已存在：" .. parent .. "/" .. name .. "（换个项目名或先删掉它）", vim.log.levels.ERROR)
    return
  end

  local argv = {
    "spring", "init",
    "--build=" .. build.id,
    "--language=" .. lang.id,
    "--java-version=" .. jv.id,
    "--boot-version=" .. bv.id,
    "--packaging=" .. pkg.id,
    "--group-id=" .. group,
    "--artifact-id=" .. artifact,
    "--name=" .. name,
    "--package-name=" .. pkgname,
  }
  if #deps > 0 then
    argv[#argv + 1] = "--dependencies=" .. table.concat(deps, ",")
  end
  argv[#argv + 1] = name

  local id2name = {}
  for _, d in ipairs(all_deps) do id2name[d.id] = d.name end
  local dep_names = {}
  for _, id in ipairs(deps) do dep_names[#dep_names + 1] = id2name[id] or id end

  local summary = table.concat({
    "构建 " .. build.id,
    "Java " .. jv.id,
    "Boot " .. bv.id,
    "打包 " .. pkg.id,
    "依赖 " .. #dep_names .. " 个",
  }, "   ")

  local go = pick_one({
    { id = "go",   hint = "创建到 " .. parent .. "/" .. name },
    { id = "redo", hint = "回到第 1 步，重新走一遍向导" },
    { id = "no",   hint = "取消，不留任何文件" },
  }, "确认创建", {
    footer = true,
    preview = function(d)
      if d.id == "go" then
        return {
          { summary, "WizKey" },
          { "   →   ", "WizDim" },
          { parent .. "/" .. name, "WizSel" },
        }
      end
      return { { d.hint or "", "WizHint" } }
    end,
  })
  if not go or go.id == "no" then return cancel() end
  if go.id == "redo" then
    vim.schedule(function() M.create() end)
    return
  end

  local oksys, res = pcall(function()
    return vim.system(argv, { cwd = parent, text = true }):wait()
  end)
  if not oksys then
    vim.notify(
      "执行失败：找不到 spring 命令。本仓库不分发 spring CLI："
        .. "需手工解到 ~/.local/share/spring/<版本>/ 并在 ~/.local/bin/spring 建包装器"
        .. "（见仓库 README「手工准备项」）",
      vim.log.levels.ERROR
    )
    return
  end
  if res.code ~= 0 then
    vim.notify("创建失败：" .. tostring(res.stderr or ""), vim.log.levels.ERROR)
    return
  end

  local dir = parent .. "/" .. name
  vim.fn.chdir(dir)
  local main = find_main_class(dir)
  if main then vim.cmd("edit " .. vim.fn.fnameescape(main)) end
  vim.notify("已创建 " .. dir .. "　jdtls 正在导入依赖（首次 10~60 秒），稍后 :LspInfo 确认", vim.log.levels.INFO)
end

-- tmux 真机复现的 bug：snacks 的 List:render() 只在 dirty（top 滚动变化）时
-- 重写行，纯光标移动不设 dirty——原生靠 CursorLine 显示当前行。而我们的
-- 当前行标注（▸ + 粉色文字）算在 format() 里，不重渲染就原地卡死，
-- 表现为「按 ↓ 上下移动不了」（内部其实在动）。
-- 补丁：渲染前发现 cursor 变了就先置 dirty，强制重跑可见行（≤14 行，轻）。
-- 注意时机：setup() 在 init.lua 阶段跑，那时 lazy 还没把 snacks 加进
-- runtimepath，require 会静默失败——所以 create() 里也要兜底调一次。
local function patch_list_rerender_on_move()
  local ok, List = pcall(require, "snacks.picker.core.list")
  if not ok or type(List) ~= "table" or List.__wiz_patched then return end
  local orig_render = List.render
  List.render = function(self, ...)
    if self.cursor and self.__wiz_cursor ~= self.cursor and not self.dirty then
      self.dirty = true
    end
    local ret = orig_render(self, ...)
    self.__wiz_cursor = self.cursor
    return ret
  end
  List.__wiz_patched = true
end

function M.create()
  -- 重入守卫：连开两个向导时，第二个 pick 会撞上 snacks 同 source dedupe
  -- （close 第一个、返回 nil）→ 两边协程互相踩。直接拒绝第二个。
  if M._running then
    vim.notify("向导已在运行中——先完成或 Esc 退出当前那个", vim.log.levels.WARN)
    return
  end
  M._running = true
  define_highlights()
  patch_list_rerender_on_move()
  local co = coroutine.create(function()
    local ok, rerr = pcall(flow)
    M._running = false
    if not ok then
      stop_pulse()  -- 兜底：任何中途抛错都不许留呼吸 timer（R2 实测坐实的泄漏）
      vim.notify("向导内部错误：" .. tostring(rerr), vim.log.levels.ERROR)
    end
  end)
  local okr, err = coroutine.resume(co)
  if not okr then
    M._running = false
    stop_pulse()
    vim.notify("向导启动失败：" .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.setup()
  define_highlights()
  patch_list_rerender_on_move()
  -- 配色直写十六进制但 ColorScheme 会清掉非 default 组，换主题时补一次。
  -- 必须挂 group：setup() 被 commands.lua 和 springboot.lua 两处调用，
  -- 无 group 会叠两份 autocmd
  local grp = vim.api.nvim_create_augroup("SpringWizardHL", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = grp,
    desc = "重建 Spring Boot 向导的派生高亮组",
    callback = define_highlights,
  })
  if vim.fn.exists(":SpringBootCreate") == 2 then return end
  vim.api.nvim_create_user_command("SpringBootCreate", function()
    M.create()
  end, { desc = "Spring Boot 项目向导（snacks.picker 版：逐段着色 + 勾选列 + 预览）" })
end

return M
