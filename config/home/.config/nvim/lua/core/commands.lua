-- ============================================
-- 自定义命令
-- 用 :命令名 回车即可执行
-- ============================================

-- 重新加载配置 / 打开欢迎页 --------

vim.api.nvim_create_user_command("R", function()
  if vim.bo.filetype ~= "lua" then
    vim.notify(":R 只能在 .lua 文件中使用", vim.log.levels.WARN)
    return
  end
  vim.cmd.luafile(vim.fn.expand("%:p"))
end, { force = true, desc = "重新加载当前 Lua 文件" })

vim.api.nvim_create_user_command("A", function()
  -- 确保 alpha-nvim 已加载，再打开欢迎页
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "alpha-nvim" } })
  end

  local ok, err = pcall(vim.cmd, "Alpha")
  if not ok then
    vim.notify("打开欢迎页失败: " .. tostring(err), vim.log.levels.ERROR)
  end
end, { force = true, desc = "打开欢迎页" })

-- LSP 客户端信息查看（0.12 移除了内置版，手动恢复）-----

vim.api.nvim_create_user_command("LspInfo", function()
  local clients = vim.lsp.get_clients()
  if #clients == 0 then
    vim.notify("没有活跃的 LSP 客户端", vim.log.levels.INFO)
    return
  end
  local lines = {}
  for _, c in ipairs(clients) do
    table.insert(lines, string.format("%s (%s)", c.name, c.id))
    local root = type(c.config.root_dir) == "string" and c.config.root_dir or "N/A"
    table.insert(lines, "  root: " .. root)
    table.insert(lines, "  filetypes: " .. table.concat(c.config.filetypes or {}, ", "))
    table.insert(lines, "")
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LSP 客户端" })
end, { force = true, desc = "查看 LSP 客户端状态" })

vim.api.nvim_create_user_command("LspLog", function()
  vim.cmd.edit(vim.fn.fnameescape(vim.lsp.log.get_filename()))
end, { force = true, desc = "打开 LSP 日志文件" })

-- 项目列表 --------

local function read_project_history_sync()
  local ok_history, history = pcall(require, "project_nvim.utils.history")
  local ok_path, path = pcall(require, "project_nvim.utils.path")
  if not (ok_history and ok_path) or history.recent_projects ~= nil then
    return
  end

  if vim.fn.filereadable(path.historyfile) ~= 1 then
    history.recent_projects = {}
    return
  end

  local projects = {}
  local seen = {}
  for _, dir in ipairs(vim.fn.readfile(path.historyfile)) do
    local normalized = dir:gsub("\\", "/"):gsub("//", "/")
    local stat = normalized ~= "" and vim.uv.fs_stat(normalized) or nil
    if stat and stat.type == "directory" and not path.is_excluded(normalized) and not seen[normalized] then
      seen[normalized] = true
      table.insert(projects, normalized)
    end
  end

  history.recent_projects = projects
end

vim.api.nvim_create_user_command("Projects", function()
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "project.nvim", "telescope.nvim", "neo-tree.nvim" } })
  end

  read_project_history_sync()

  local ok_history, history = pcall(require, "project_nvim.utils.history")
  local ok_telescope, pickers = pcall(require, "telescope.pickers")
  if not (ok_history and ok_telescope) then
    vim.notify("项目列表加载失败", vim.log.levels.ERROR)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local projects = vim.deepcopy(history.get_recent_projects())
  for i = 1, math.floor(#projects / 2) do
    projects[i], projects[#projects - i + 1] = projects[#projects - i + 1], projects[i]
  end

  if #projects == 0 then
    vim.notify("暂无项目历史", vim.log.levels.INFO)
    return
  end

  local function switch_project(prompt_bufnr)
    local entry = action_state.get_selected_entry()
    actions.close(prompt_bufnr)
    if not entry or not entry.value then
      return
    end

    local dir = entry.value
    local ok_project, project = pcall(require, "project_nvim.project")
    if ok_project then
      project.set_pwd(dir, "projects")
    else
      vim.api.nvim_set_current_dir(dir)
    end

    vim.schedule(function()
      local ok_neotree, err = pcall(vim.cmd, "Neotree filesystem reveal dir=" .. vim.fn.fnameescape(dir))
      if not ok_neotree then
        vim.notify("项目已切换，但文件树刷新失败: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end

  pickers
    .new({}, {
      prompt_title = "Projects",
      finder = finders.new_table({
        results = projects,
        entry_maker = function(dir)
          return {
            value = dir,
            display = vim.fn.fnamemodify(dir, ":t") .. "  " .. dir,
            ordinal = vim.fn.fnamemodify(dir, ":t") .. " " .. dir,
          }
        end,
      }),
      previewer = false,
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          switch_project(prompt_bufnr)
        end)
        return true
      end,
    })
    :find()
end, { force = true, desc = "打开项目列表" })

-- Java 项目初始化 / 单文件运行 --------

-- 从当前缓冲区提取 Java package 声明
local function java_package_name()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    local package_name = line:match("^%s*package%s+([%w_.]+)%s*;")
    if package_name then
      return package_name
    end
  end
  return nil
end

-- 根据文件目录和包名推导项目根目录
-- 例如：文件在 src/main/java/com/example/Foo.java，包名 com.example
--   → 文件目录尾部匹配 /com/example → 去掉后缀 → 根目录 = src/main/java
local function java_package_root(file_dir, package_name)
  if not package_name then
    return vim.fs.normalize(file_dir)
  end

  local package_path = package_name:gsub("%.", "/")
  local normalized_dir = vim.fs.normalize(file_dir)
  local suffix = "/" .. package_path

  if normalized_dir:sub(-#suffix) ~= suffix then
    return nil -- 目录结构与包声明不匹配
  end

  local root = normalized_dir:sub(1, #normalized_dir - #suffix)
  return root ~= "" and root or "/"
end

vim.api.nvim_create_user_command("JavaRun", function()
  -- 验证：仅 Java 文件可用，且需要的工具存在
  if vim.bo.filetype ~= "java" then
    vim.notify(":JavaRun 只能在 Java 文件中使用", vim.log.levels.WARN)
    return
  end
  if vim.fn.executable("java") ~= 1 then
    vim.notify("找不到 java 命令", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("javac") ~= 1 then
    vim.notify("找不到 javac 命令", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("bash") ~= 1 then
    vim.notify("找不到 bash 命令", vim.log.levels.ERROR)
    return
  end

  local file = vim.fn.expand("%:p")
  local package_name = java_package_name()

  -- 无 package：直接用 JDK 11+ 的单文件模式运行
  if not package_name then
    vim.cmd("term java " .. vim.fn.shellescape(file))
    return
  end

  -- 有 package：推导根目录，用 javac + java 两步编译运行
  local root = java_package_root(vim.fn.expand("%:p:h"), package_name)
  if not root then
    vim.notify(
      "无法从当前文件路径推导 package 根目录，请确认目录结构与 package 声明一致",
      vim.log.levels.ERROR
    )
    return
  end

  local class_name = vim.fn.expand("%:t:r")
  local main_class = package_name .. "." .. class_name
  local relative_file = vim.fs.relpath(root, file)
  if not relative_file then
    vim.notify("无法计算当前 Java 文件相对 package 根目录的路径", vim.log.levels.ERROR)
    return
  end

  -- 编译到临时目录再运行（支持任何 JDK 版本，不依赖 JDK 11+ 单文件模式）
  local out_dir = vim.fn.tempname()
  local command = table.concat({
    "cd " .. vim.fn.shellescape(root),
    "mkdir -p " .. vim.fn.shellescape(out_dir),
    "javac -d " .. vim.fn.shellescape(out_dir) .. " -sourcepath . " .. vim.fn.shellescape(relative_file),
    "java -cp " .. vim.fn.shellescape(out_dir) .. " " .. main_class,
  }, " && ")

  -- bash -lc 确保 shell 配置（如 PATH）被加载
  vim.cmd("term bash -lc " .. vim.fn.shellescape(command))
end, { force = true, desc = "运行当前 Java 文件（自动处理有/无 package）" })
