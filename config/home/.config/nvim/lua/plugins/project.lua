-- =============================================================================
-- 项目管理：project.nvim
-- =============================================================================
-- 自动检测当前文件所属的项目（通过 .git、LSP 等），
-- 并联动 Telescope 的 `projects` 扩展实现项目快速切换（<leader>fp）。
-- =============================================================================

return {
  "ahmedkhalf/project.nvim",
  lazy = false,
  config = function()
    require("project_nvim").setup({
      -- 检测策略：通过目录特征（pattern）和 LSP 推断项目根目录
      detection_methods = { "pattern", "lsp" },
      -- 识别项目的标记文件/目录
      patterns = {
        ".git",
        "_darcs",
        ".hg",
        ".bzr",
        ".svn",
        "Makefile",
        "CMakeLists.txt",
        "package.json",
        "go.mod",
        "Cargo.toml",
        "pom.xml",
        "build.gradle",
        "build.gradle.kts",
      },
      -- 切换缓冲区时自动切换 CWD 到项目根（不弹确认框）
      sync_root_with_cwd = true,
      manual_mode = false,
    })
    -- 运行时修补：用 vim.lsp.get_clients() 替换已废弃的 vim.lsp.buf_get_clients()
    -- 避免直接修改插件文件，否则 lazy.nvim 检测到 dirty 状态会显示红色 failed
    local ok_project, Project = pcall(require, "project_nvim.project")
    if not ok_project then
      vim.notify("project.nvim 内部模块加载失败，已跳过兼容性修补", vim.log.levels.WARN)
      return
    end

    Project.find_lsp_root = function()
      local buf_ft = vim.bo[0].filetype -- 当前缓冲区的文件类型
      local clients = vim.lsp.get_clients({ bufnr = 0 }) -- 获取当前缓冲区关联的 LSP 客户端（新 API）
      if next(clients) == nil then -- 没有 LSP 客户端则跳过
        return nil
      end
      local config = require("project_nvim.config")
      for _, client in pairs(clients) do
        local filetypes = client.config.filetypes
        if filetypes and vim.tbl_contains(filetypes, buf_ft) then -- 匹配文件类型
          if not vim.tbl_contains(config.options.ignore_lsp, client.name) then -- 不在忽略列表里
            local root_dir = client.config.root_dir
            if type(root_dir) == "string" and root_dir ~= "" then
              return root_dir, client.name -- 返回项目根目录和客户端名称
            end
          end
        end
      end
      return nil
    end

    local original_set_pwd = Project.set_pwd
    if type(original_set_pwd) ~= "function" then
      return
    end

    Project.set_pwd = function(dir, method)
      local ok_changed, changed = pcall(original_set_pwd, dir, method)
      if not ok_changed then
        vim.notify("项目目录切换失败: " .. tostring(changed), vim.log.levels.ERROR)
        return false
      end
      if changed and type(dir) == "string" and package.loaded["neo-tree.sources.manager"] then
        vim.schedule(function()
          local ok, manager = pcall(require, "neo-tree.sources.manager")
          if not ok then
            return
          end
          manager._for_each_state("filesystem", function(state)
            if state.path and state.path ~= dir then
              pcall(manager.navigate, state, dir)
            end
          end)
        end)
      end
      return changed
    end
  end,
}
