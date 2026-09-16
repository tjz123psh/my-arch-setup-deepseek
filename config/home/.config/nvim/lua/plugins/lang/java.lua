-- ============================================
-- Java 语言支持：jdtls LSP + DAP 调试 + Maven / Spring Boot
-- 前置: :Mason 安装 jdtls + java-debug-adapter + java-test + lemminx
-- 外部依赖: mvn（Maven）/ spring（Spring Boot CLI），都在 ~/.local/bin
-- ============================================
--
-- 三件关键事（踩坑记录）:
--   1. java-debug-adapter / java-test 必须作为 bundles 由 jdtls 启动时加载，
--      不能独立 java -jar 运行；改了 bundles 要 :LspRestart 或重开才生效。
--   2. jdtls 需要独立 workspace 目录缓存每个项目的索引，
--      所以不能走 nvim-lspconfig 自动配置，必须 nvim-jdtls + 每项目 -data。
--   3. 本文件必须显式传 on_attach（见 core/lsp_on_attach.lua 注释），
--      否则 Java 缓冲区没有 gd/gr/gh 等导航键。
--
-- 调试流程:
--   F9 打断点 → F5 → jdtls 扫描带 main 的类 →（多个则 vim.ui.select 选）
--   → dap.run() → jdtls.startDebugSession 返回端口 → nvim-dap 连接
--   注意 F5 若提示"仍在导入项目"，是因为 Maven 依赖还没索引完，会自动重试。
-- ============================================

return {
  {
    "mfussenegger/nvim-jdtls",
    ft = { "java" },
    opts = {
      cmd = { vim.fn.stdpath("data") .. "/mason/bin/jdtls" },
      -- root_dir 不用在 opts 里设函数——vim.lsp.start 不解析函数式 root_dir
      -- 在 config 里预先求值为字符串再传
      settings = {
        java = {
          inlayHints = { parameterNames = { enabled = "all" } },
          -- 让 jdtls 拉第三方库 sources jar，才能像 IDEA 一样点进依赖看源码
          maven = { downloadSources = true, downloadJavadoc = false },
          -- main/测试方法上方显示 run|debug 标记，引用处显示引用数
          referencesCodeLens = { enabled = true },
          implementationCodeLens = { enabled = true },
          completion = {
            -- 常用静态成员不强制全限定名（System.out、Assert.* 等）
            favoriteStaticMembers = {
              "org.junit.Assert.*",
              "org.junit.jupiter.api.Assertions.*",
              "org.mockito.Mockito.*",
              "java.util.Objects.requireNonNull",
              "java.lang.Math.*",
            },
            importOrder = { "java", "javax", "jakarta", "com", "org", "" },
          },
          signatureHelp = { descriptionEnabled = true },
        },
      },
      init_options = {
        bundles = {},
      },
    },

    config = function(_, opts)
      local ok, blink = pcall(require, "blink.cmp")
      if ok then
        opts.capabilities = blink.get_lsp_capabilities()
      end

      -- 将 java-debug/java-test JAR 作为 bundles 传给 jdtls（必须, 不能独立 java -jar 启动）
      -- java-test 的 server 目录里混着两个非 OSGi 的普通 jar（test runner、jacoco agent），
      -- 它们没有 Bundle-SymbolicName，会让 jdt.ls 的 bundle 列表整体加载失败，必须排除
      local non_bundles = {
        "runner%-jar%-with%-dependencies",
        "jacocoagent",
        "org%.objectweb%.asm",
      }
      local seen_bundles = {}
      local bundle_patterns = {
        vim.fn.stdpath("data")
          .. "/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar",
        vim.fn.stdpath("data") .. "/mason/packages/java-test/extension/server/*.jar",
      }
      for _, pattern in ipairs(bundle_patterns) do
        local jars = vim.fn.glob(pattern, false, true)
        for _, jar in ipairs(jars) do
          local skip = false
          for _, needle in ipairs(non_bundles) do
            if jar:match(needle) then
              skip = true
              break
            end
          end
          if not skip and not seen_bundles[jar] and vim.uv.fs_stat(jar) then
            seen_bundles[jar] = true
            table.insert(opts.init_options.bundles, jar)
          end
        end
      end

      -- Spring Boot Tools：把官方 jdtls 扩展作为 bundle 注入现有 jdtls。
      -- spring-boot.nvim 会从 Mason 的 vscode-spring-boot-tools 读取这些 jar。
      local ok_spring, spring_boot = pcall(require, "spring_boot")
      if ok_spring then
        vim.list_extend(opts.init_options.bundles, spring_boot.java_extensions())
      end

      -- Lombok：Spring Boot 项目几乎必用，没有 agent 时 @Data/@Builder/@Slf4j
      -- 会报一堆"找不到 getXxx()"的假错误。通过 jdtls 的 --jvm-arg 挂 javaagent。
      local lombok_jar = vim.fn.stdpath("data") .. "/java-extras/lombok.jar"
      local jvm_args = {}
      if vim.uv.fs_stat(lombok_jar) then
        table.insert(jvm_args, "--jvm-arg=-javaagent:" .. lombok_jar)
      else
        vim.notify("未找到 lombok.jar（" .. lombok_jar .. "），Lombok 注解可能报错", vim.log.levels.WARN)
      end

      -- 保存基础 cmd（不含 --jvm-arg / -data），后续每次 start_or_attach 时重新拼装
      local cmd_base = opts.cmd or { vim.fn.stdpath("data") .. "/mason/bin/jdtls" }

      local function build_cmd(dir)
        local project_name = vim.fn.fnamemodify(dir or vim.fn.getcwd(), ":t")
        local project_hash = vim.fn.sha256(vim.fs.normalize(dir or vim.fn.getcwd())):sub(1, 10)
        local workspace_dir = vim.fn.stdpath("data") .. "/site/jdtls-workspace/" .. project_name .. "-" .. project_hash
        local cmd = vim.deepcopy(cmd_base)
        vim.list_extend(cmd, jvm_args)
        vim.list_extend(cmd, { "-data", workspace_dir })
        return cmd
      end

      local jdtls = require("jdtls")
      local jdtls_dap = require("jdtls.dap")
      local dap = require("dap")
      local on_attach = require("core.lsp_on_attach")

      -- 解析 root_dir 为字符串（vim.lsp.start 直接传值，不支持函数）
      local resolve_root = function(bufnr)
        local fname = vim.api.nvim_buf_get_name(bufnr)
        if fname and #fname > 0 then
          return vim.fs.root(fname, { "pom.xml", "build.gradle", "build.gradle.kts", ".git", "src" }) or vim.fn.getcwd()
        end
        return vim.fn.getcwd()
      end
      opts.root_dir = resolve_root(0)

      -- 注册适配器: 找 jdtls client → startDebugSession → port（只执行一次）
      jdtls.setup_dap({ hotcodereplace = "auto" })

      ------------------------------------------------------------------
      -- 构建 / 运行：自动在 mvnw / gradlew / mvn / gradle 之间选择
      ------------------------------------------------------------------
      local function project_root()
        return vim.fs.root(0, { "mvnw", "gradlew", "pom.xml", "build.gradle", "build.gradle.kts" })
      end

      -- maven_task / gradle_task 任一为 nil 表示该构建工具不支持此操作
      local function run_build(maven_task, gradle_task, extra)
        local root = project_root()
        if not root then
          vim.notify("未找到项目根目录（需要 pom.xml 或 build.gradle*）", vim.log.levels.ERROR)
          return
        end

        local is_gradle = vim.uv.fs_stat(root .. "/build.gradle") or vim.uv.fs_stat(root .. "/build.gradle.kts")
        local is_maven = vim.uv.fs_stat(root .. "/pom.xml")

        local bin, task, tool
        if is_gradle then
          bin = vim.uv.fs_stat(root .. "/gradlew") and "./gradlew" or "gradle"
          task = gradle_task
          tool = "Gradle"
        elseif is_maven then
          bin = vim.uv.fs_stat(root .. "/mvnw") and "./mvnw" or "mvn"
          task = maven_task
          tool = "Maven"
        else
          vim.notify("项目根目录下既没有 pom.xml 也没有 build.gradle*", vim.log.levels.ERROR)
          return
        end

        if not task then
          vim.notify("当前项目用 " .. tool .. "，该操作没有对应任务", vim.log.levels.WARN)
          return
        end

        -- wrapper 从 git 克隆后常常没有可执行位，先补上
        if bin:sub(1, 2) == "./" then
          vim.fn.setfperm(root .. "/" .. bin:sub(3), "rwxr-xr-x")
        end

        local cmdline = bin .. " " .. task .. (extra or "")
        -- exec(cmd, num, size, dir, direction, ...) 是位置参数，不是 table
        -- 用 2 号终端，避免和 <leader>tt 的 1 号交互终端抢位置；保留终端焦点查看结果
        require("toggleterm").exec(cmdline, 2, nil, root, "horizontal", "Java 测试", false)
      end

      ------------------------------------------------------------------
      -- 调试：优先用 jdtls 扫出来的主类，扫不到才回退手工输入
      ------------------------------------------------------------------
      local function pick_main_and_run(configs)
        if #configs == 1 then
          dap.run(configs[1])
          return
        end
        -- dressing.nvim 会把 vim.ui.select 接管成漂亮的列表
        vim.ui.select(configs, {
          prompt = "选择要调试的主类",
          format_item = function(c)
            return c.mainClass or c.name
          end,
        }, function(choice)
          if choice then
            dap.run(choice)
          end
        end)
      end

      local function debug_java()
        local configs = dap.configurations.java or {}
        if #configs > 0 then
          pick_main_and_run(configs)
          return
        end

        -- 首次：jdtls 要先把 Maven 依赖导完、编译完，才扫得出带 main 的类。
        -- on_ready 无参数，必须自己回读 dap.configurations.java。
        local function attempt(n)
          jdtls_dap.setup_dap_main_class_configs({
            verbose = false,
            on_ready = function()
              local found = dap.configurations.java or {}
              if #found > 0 then
                vim.notify("找到 " .. #found .. " 个主类", vim.log.levels.INFO)
                pick_main_and_run(found)
                return
              end
              if n < 4 then
                vim.notify("jdtls 仍在导入项目，重试 " .. (n + 1) .. "/4…", vim.log.levels.WARN)
                vim.defer_fn(function()
                  attempt(n + 1)
                end, 2500)
              else
                vim.notify(
                  "未发现主类。确认：1) 类里有 public static void main 2) :JavaBuildProjects 已跑过 3) jdtls 导入完成",
                  vim.log.levels.ERROR
                )
                local main_class = vim.fn.input("主类名: ", vim.fn.expand("%:t:r"))
                if main_class and #main_class > 0 then
                  dap.run({
                    type = "java",
                    name = "Java 调试",
                    request = "launch",
                    mainClass = main_class,
                  })
                end
              end
            end,
          })
        end
        attempt(1)
      end

      ------------------------------------------------------------------
      -- 终端测试：运行测试不进入 DAP 调试界面，结果保留在终端中
      ------------------------------------------------------------------
      local function current_test_selector(include_method)
        local bufnr = vim.api.nvim_get_current_buf()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
        local package_name
        local class_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

        for _, line in ipairs(lines) do
          package_name = line:match("^%s*package%s+([%w_%.]+)%s*;") or package_name
          if package_name then
            break
          end
        end

        local selector = package_name and (package_name .. "." .. class_name) or class_name
        if not include_method then
          return selector
        end

        for index = cursor_line, 1, -1 do
          local method_name = lines[index]:match(
            "^%s*[%w_%s<>%[%],%.%?]+%s+([%w_]+)%s*%([^;]*%)%s*{%s*$"
          )
          if method_name then
            return selector .. "#" .. method_name
          end
        end

        vim.notify("光标附近未找到 Java 测试方法", vim.log.levels.WARN)
        return nil
      end

      local function run_java_test(include_method)
        local selector = current_test_selector(include_method)
        if not selector then
          return
        end
        run_build(
          "test -Dtest=" .. selector,
          "test --tests " .. selector:gsub("#", ".")
        )
      end

      ------------------------------------------------------------------
      -- 缓冲区快捷键
      ------------------------------------------------------------------
      local setup_java_keys = function(bufnr)
        local function d(s)
          return { buffer = bufnr, silent = true, desc = s }
        end

        -- 保留原有的两个别名
        vim.keymap.set("n", "<leader>co", vim.lsp.buf.code_action, d("Java 代码操作"))
        vim.keymap.set("n", "<leader>ot", jdtls.organize_imports, d("整理 import"))

        -- 调试
        vim.keymap.set("n", "<F5>", debug_java, d("Java: 调试（自动识别主类）"))
        vim.keymap.set("n", "<leader>Jd", function()
          jdtls_dap.setup_dap_main_class_configs({ verbose = true })
        end, d("Java: 重新扫描主类"))

        -- 测试默认走 Maven/Gradle 终端，结果不会随着 DAP 面板关闭而消失
        vim.keymap.set("n", "<leader>Jt", function()
          run_java_test(true)
        end, d("Java: 终端运行光标处测试方法"))
        vim.keymap.set("n", "<leader>JT", function()
          run_java_test(false)
        end, d("Java: 终端运行当前测试类"))

        -- 需要断点、变量和调用栈时，显式使用 Java 测试调试
        vim.keymap.set("n", "<leader>Jg", jdtls.test_nearest_method, d("Java: 调试光标处测试方法"))
        vim.keymap.set("n", "<leader>JG", jdtls.test_class, d("Java: 调试当前测试类"))

        -- 重构（IDEA 的 Extract…）
        vim.keymap.set("n", "<leader>Rv", jdtls.extract_variable, d("重构: 提取变量"))
        vim.keymap.set("n", "<leader>RV", jdtls.extract_variable_all, d("重构: 提取所有重复表达式为变量"))
        vim.keymap.set("n", "<leader>Rc", jdtls.extract_constant, d("重构: 提取常量"))
        vim.keymap.set("n", "<leader>Rm", jdtls.extract_method, d("重构: 提取方法"))

        -- 父类/接口实现跳转（IDEA 的 Ctrl+U）
        vim.keymap.set("n", "gU", jdtls.super_implementation, d("跳转到父类/接口实现"))

        -- Spring Boot
        vim.keymap.set("n", "<leader>sr", function()
          run_build("spring-boot:run", "bootRun")
        end, d("Spring Boot: 运行"))

        -- Maven / Gradle 生命周期
        vim.keymap.set("n", "<leader>mc", function()
          run_build("compile", "classes")
        end, d("构建: 编译"))
        vim.keymap.set("n", "<leader>mt", function()
          run_build("test", "test")
        end, d("构建: 跑测试"))
        vim.keymap.set("n", "<leader>mp", function()
          run_build("package -DskipTests", "build -x test")
        end, d("构建: 打包（跳过测试）"))
        vim.keymap.set("n", "<leader>mi", function()
          run_build("install -DskipTests", "install -x test")
        end, d("构建: 安装到本地仓库"))
        vim.keymap.set("n", "<leader>mn", function()
          run_build("clean", "clean")
        end, d("构建: 清理"))
        vim.keymap.set("n", "<leader>ml", function()
          run_build("dependency:tree", "dependencies")
        end, d("构建: 依赖树"))
        vim.keymap.set("n", "<leader>mb", jdtls.build_projects, d("构建: 让 jdtls 重新导入/构建项目"))
      end

      ------------------------------------------------------------------
      -- 全局命令（不依赖当前 buffer 是否已触发 FileType）
      ------------------------------------------------------------------
      vim.api.nvim_create_user_command("JavaBuildProjects", jdtls.build_projects,
        { desc = "jdtls: 重新导入并构建项目（改了 pom.xml 依赖后用）" })

      vim.api.nvim_create_user_command("JavaSetRuntime", function(p)
        jdtls.set_runtime(p.args)
      end, {
        desc = "切换 JDK（IDEA 的 Project SDK）",
        nargs = "?",
        complete = function(arg_lead)
          return jdtls._complete_set_runtime(arg_lead)
        end,
      })

      ------------------------------------------------------------------
      -- 启动 / 附加
      ------------------------------------------------------------------
      -- 每次启动/附加时重新解析 root_dir 和 cmd（-data workspace_dir 按项目切换）
      local function start_jdtls(bufnr)
        local root_dir = resolve_root(bufnr)
        local config = vim.deepcopy(opts)
        config.root_dir = root_dir
        config.cmd = build_cmd(root_dir)
        config.on_attach = on_attach
        jdtls.start_or_attach(config)
        setup_java_keys(bufnr)
      end

      -- 后续打开的 Java 文件
      local group = vim.api.nvim_create_augroup("java_jdtls", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "java",
        callback = function()
          start_jdtls(0)
        end,
      })

      -- 当前已有 Java 文件
      if vim.bo.filetype == "java" then
        vim.schedule(function()
          start_jdtls(0)
        end)
      end
    end,
  },
}
