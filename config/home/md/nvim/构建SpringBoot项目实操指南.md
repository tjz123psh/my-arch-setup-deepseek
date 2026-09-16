# 在 Neovim 里构建 Spring Boot 项目 —— 向导 + 分层实操

> 环境（Maven / Spring CLI / jdtls / Lombok / lemminx）已就位，本文不管这些，
> 只管**怎么把项目建起来、一层层写出来、跑起来**。
> 示例按本机 Neovim 配置整理；当前 Feed 项目使用 Spring Boot 4.0.8、Java 21。向导创建其他项目时，版本以 Initializr 当前可用的正式版本为准，不要把示例版本号硬编码到新项目。

---

## 一、打开向导

### 在哪敲

**不是**在项目文件夹里——项目还没建，不存在可进的项目目录。
你要站在**准备容纳这个项目的父目录**里启动 nvim：

```bash
mkdir -p ~/Projects && cd ~/Projects   # ← 站在这里
nvim .
```

然后在 **普通模式**下按 `空格` → `s` → `p`（`<leader>` 就是你的空格键，
不是要打的字符，也不进命令行）。

想走命令行的话输 `:SpringBootCreate` 回车，两条路完全等价。

### 项目最终建在哪

由第 ⑪ 步「创建到哪个目录下」决定，它的默认值就是 **nvim 当前的工作目录**
（`vim.fn.getcwd()`）。所以：

| 你的操作 | 结果 |
|----------|------|
| `cd ~/Projects && nvim .` 后按 `<leader>sp` | 建到 `~/Projects/项目名/` ✅ |
| 在家目录 `~` 启动 nvim 就直接开向导 | 建到 `~/项目名/` ❌ 脏了家目录 |
| 已经开着 nvim 了 | 先 `:cd ~/Projects` 再开向导，或干脆在 ⑪ 那一步手填路径 |

第 11 步之后的确认屏会把创建摘要和目标目录列出来让你**最后确认一次**，
看清路径再回车；不满意就 Esc 整体取消，不会留下半个项目。

会依次弹 11 个可搜索的选择/输入框，顺序刻意对齐 IDEA 的 New Project 对话框。
选择框用 `jk` 或继续打字过滤，回车确认；输入框直接回车表示采纳括号里的默认值；
任何一步按 `Esc` 都是整体取消，不会留下半个项目。

### 与 IDEA 的对照

| 向导提问 | IDEA 里对应的字段 | 建议填 |
|----------|------------------|--------|
| ① 构建工具 | Build system | `maven`（pom.xml + mvnw） |
| ② 语言 | Language | `java` |
| ③ Java 版本 | SDK / Language level | `21`（LTS） |
| ④ Spring Boot 版本 | Version | 选带「最新正式版」标记的那一项 |
| ⑤ 打包方式 | Packaging | `jar` |
| ⑥ 依赖 | Dependencies 搜索列表 | 见下表 |
| ⑦ Group ID | Group | `com.example` |
| ⑧ Artifact ID | Artifact | 小写、无连字符，如 `wizdemo` |
| ⑨ 项目名 | Name / 目录名 | 同 Artifact |
| ⑩ 包名 | Package name | 默认 `group.artifact`，直接回车 |
| ⑪ 创建到哪个目录 | Location | **改成你的项目目录** |

最后会列出**创建摘要（构建/Java/Boot/打包/依赖数）和目标路径**让你确认，再动手。

### ⚠ 第 ⑪ 步是唯一容易栽的地方

项目建在**当前 Neovim 工作目录**下面。如果你是从 `~` 启动的 nvim，
项目就会掉进家目录。要么在这里手填目标路径，要么先 `:cd ~/Projects` 再开向导。

### 为什么不优先用 springboot-nvim 自带的向导

`<leader>sP` 仍然保留（`:SpringBootNewProject`），但旧版向导可能把
`start.spring.io` 返回的版本标识直接写进 `pom.xml`。如果标识带有历史格式的
`.RELEASE` 后缀，就可能生成无法解析的 parent 版本。

本向导会在提交给 Initializr 前规范化这类版本标识，生成结果仍以服务端实际返回的
正式版本为准。创建后如果构建失败，优先检查 `pom.xml` 的 parent 版本是否能在 Maven
中央仓库解析，不要手动照抄旧示例版本。

---

## 二、依赖怎么选（第 6 步）

弹的是 **snacks.picker**（选型原因见文末「界面说明」），**单卡片布局**
（宽度自适应：目标 104 列，窄终端让到 `columns-2`；无右侧预览，
说明在当前项的底部 3 行详情区）：

```
╭───────────── 6. 选择依赖 ─────────────
│ ❯                                204/204 │
│ ○ ▸ mcp-security    Model Context Prot…  │
│ ●   spring-ai-anthropic Anthropic Claude │
│ ○   data-jpa        Spring Data JPA      │
│ ───────────────────────────────────────  │
│ Model Context Protocol Security · [AI] · │
│ Provides security for Spring AI's MCP    │
│ server and client, and OAuth2 Auth…      │
╰──────────────────────────────────────────╯
```

行是 **▸ 指针 + id（亮白主键，列宽=最长 id 绝不截断）+ 名称（灰，占剩余
宽度，截断用 …）**，勾选列在最左
○ 未选 / ● 已选（Tab 切换）。当前行**没有底色条**：只把行首点亮一个粉色 ▸、
文字转粉色加粗。光标停在哪个依赖，底部 3 行详情区实时显示
「名称 · [分组] · 完整描述」。

**前 5 步（构建工具/语言/Java/Boot/打包）没有详情区**：hint 短，直接排在
id 后面（peach 橙色），卡片只有 5~9 行高；只有依赖页和确认步保留 3 行
详情区（确认步显示完整摘要和目标路径）。

界面跟 noice 通知弹框统一为 **catppuccin-mocha 粉系主题**：

| 元素 | 颜色 | 说明 |
|---|---|---|
| 背景 | 透明 | 和编辑器其它浮窗同风格（kitty 全局透明度透出壁纸） |
| 边框 | #F38BA8 | 粉色细圆角 ╭╮╰╯，**1.2s 呼吸变色** |
| 主文字 | #CDD6F4 | id 列亮白 |
| 当前行 | #F5C2E7 | 行首粉 ▸ + 文字粉色（catppuccin pink）加粗（无底色条） |
| 关键词/匹配词 | #CBA6F7 | mauve 加粗 |
| 分组徽章 / 行内 hint | #FAB387 | peach（徽章加粗，hint 不加粗） |
| ❯ 提示符 | #A6E3A1 | green，和粉色边框撞色 |
| 计数器 | #CBA6F7 | 右上 204/204 mauve 加粗 |

实现要点（v6 推倒重构）：

- 布局不再用 snacks 的 default/select 预设，自绘 vertical box：
  `input(1) + list(≤14) + preview(3)`，边框画在 box 层
- **边框变粉的关键**：snacks 窗口的 winhighlight 是它自己生成的链接链
  （`FloatBorder → SnacksPickerListBorder → SnacksPickerBorder`），
  传自定义 winhighlight 字符串会被 force 覆盖。正确做法是启动时把链接链
  的基座组（`SnacksPickerBorder`/`SnacksPicker`/`SnacksTitle` 等）定义成
  实色（非 default），snacks 的 default=true 注册就永远盖不住
- 底部说明区 = 3 行高的 preview 窗口，逐字换行（中文按 2 列宽计算）+ 分段着色；
  短 hint 的步骤直接 hidden = { "preview" }，卡片缩到 5~9 行
- 面板底色透明（`SnacksPicker`/`SnacksNormal` bg=NONE），不设 backdrop 压暗；
  当前行底色条也去掉（`SnacksPickerListCursorLine` bg=NONE），标注改行首 ▸
- 终端没有真正的模糊发光，用透明面板、粗体、行首指针和呼吸动画近似 noice。
  如果卡片仍显透，那是 kitty 的 background_opacity 在全局混合（noice 同理会透）

操作键位（v4 定稿：**Tab 选择，Enter 确认**，和绝大多数勾选列表一致）：

| 键 | 作用 |
|----|------|
| `<Tab>` | 勾选 / 取消当前项（并下移一行） |
| `<Enter>` | 确认勾选结果，进入下一步 |
| `<C-s>` | 同 Enter，快捷完成 |
| `<Esc>` | 取消整个向导 |

- 每行左侧是**勾选框列**：未选 `○`、已选 `●`，选了哪些一眼可见
- 直接打字即模糊搜索，**组名也能搜**：输 `sql` 只剩 SQL 组，输 `ai` 看 AI 组
- 204 个依赖按 23 个分组排序，同组天然聚在一起
- 光标停在某项上时，底部行实时显示该项的「名称 · [分组] · 官方描述」
- 文字分三档明暗：id 亮色、名称次之、底部描述压暗，分组徽章独立一色

啰嗦的组名做了缩短（`VMware Tanzu Spring Enterprise Extensions` → `Tanzu Ent`、
`Developer Tools` → `Dev Tools` 等），否则会被列宽截成 `VMware Tanzu Sp~`。

常用的这些：

| 依赖 id | 给你什么 | 什么时候要 |
|---------|----------|-----------|
| `web` | REST + 内嵌 Tomcat | 写接口就必选 |
| `data-jpa` | JPA/Hibernate 仓储 | 要存数据库 |
| `h2` | 内存数据库 | 开发期免装库 |
| `devtools` | 改代码自动重启 | 开发期必选 |
| `validation` | `@NotBlank`/`@Size` 等参数校验 | 有入参就要 |
| `lombok` | `@Data`/`@Builder` 少写样板 | 可选（见下方说明） |
| `actuator` | `/actuator/health` 等运维端点 | 要上线就加 |
| `security` | 认证授权 | 需要登录时再加 |
| `thymeleaf` | 服务端模板页面 | 不做前后端分离时 |
| `jdbc` | 裸 JdbcTemplate | 不想用 JPA 时 |

**必须一起选的**：`data-jpa` 单独选会启动失败（`Failed to configure a DataSource`），
它只是 JPA 支持，需要一个能连的库，开发期配上 `h2` 即可。

> `lombok` 这个依赖只负责把注解和编译期处理器放进 classpath。
> 让 jdtls 真正认识 Lombok 生成的 getter/setter，靠的是 `java.lua` 里挂的
> `-javaagent:.../lombok.jar`，两者都要有，缺后者会报一堆假错。

---

## 三、向导建完后你得到什么

```
wizdemo/
├── pom.xml                    依赖与插件（ lemminx 会给它补全）
├── mvnw  .mvn/                Maven Wrapper，锁定构建版本
├── src/main/java/com/example/wizdemo/
│   └── WizdemoApplication.java   main() + @SpringBootApplication
├── src/main/resources/
│   └── application.properties    配置
└── src/test/java/com/example/wizdemo/
    └── WizdemoApplicationTests.java
```

`@SpringBootApplication` 是三个注解的合成：
`@Configuration`（本类是配置源）+ `@EnableAutoConfiguration`（按 classpath 自动装配）
+ `@ComponentScan`（扫同包及子包）。所以**启动类要放在最外层包**，
否则子包里的 Bean 扫不到。

---

## 四、确认 jdtls 接管（别跳过）

```
:LspInfo
```

期望看到 `jdtls`，且 `root` 是项目根目录。然后光标停在 `@SpringBootApplication`
上按 `gd`，能跳进源码就说明索引好了。

刚建好时依赖还在导入（首次 10~60 秒），此时没补全、`gd` 无反应是**正常现象**，
不是坏了。nvim-jdtls 失败时通常不弹任何错误，只靠 `:LspInfo` / `:LspLog` 判断。

---

## 五、分层把代码写出来

推荐的写入顺序，每层写完 jdtls 就能给下一层做补全：

```
Entity → Repository → DTO → Service → Controller → 异常处理 → 配置
```

包结构可以全平铺在一个包下（小项目够用），也可以分子包 
（`domain`/`repository`/`web`/`config`）。下面按平铺写。

### 1. Entity

```java
package com.example.wizdemo;

import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "app_user")
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    private String name;

    protected User() {
    }

    public User(String name) {
        this.name = name;
    }

    public Long getId() {
        return id;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }
}
```

**`@Table(name = "app_user")` 不能省。** 实体 `User` 默认表名 `user`，
而 `user` 是 H2/PostgreSQL 的保留字。省略时编译、启动都不报错，
直到第一次插入才炸：

```
InvalidDataAccessResourceUsage: Could not prepare statement
[Syntax error in SQL statement "insert into [*]user (name,id) values (?,default)"]
```

### 2. Repository

```java
package com.example.wizdemo;

import org.springframework.data.jpa.repository.JpaRepository;

public interface UserRepository extends JpaRepository<User, Long> {

    boolean existsByName(String name);
}
```

只写接口不写实现，Spring Data 运行时生成实现。
方法名按规则拼（`findByXxx`、`existsByXxx`、`countByXxx`）就能出查询，
这也是 `existsByName` 无需任何注解即可用的原因。

### 3. DTO（别让 Entity 直接当出入参）

```java
package com.example.wizdemo;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record CreateUserRequest(@NotBlank @Size(min = 2, max = 30) String name) {
}
```

用 `record` 省掉构造器与 getter。校验注解放 DTO 上，实体保持干净。

### 4. Service（业务规则与事务边界）

```java
package com.example.wizdemo;

import java.util.List;
import java.util.NoSuchElementException;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class UserService {

    private final UserRepository repository;

    UserService(UserRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true)
    public List<User> list() {
        return repository.findAll();
    }

    @Transactional
    public User create(String name) {
        if (repository.existsByName(name)) {
            throw new IllegalArgumentException("用户名已存在: " + name);
        }
        return repository.save(new User(name));
    }

    @Transactional(readOnly = true)
    public User get(Long id) {
        return repository.findById(id).orElseThrow(() -> new NoSuchElementException("用户不存在: " + id));
    }
}
```

`@Transactional` 放 Service 而不是 Controller，事务边界才对。
查询加 `readOnly = true`，Hibernate 会跳过脏检查。

### 5. Controller（只做参数转换，不写业务）

```java
package com.example.wizdemo;

import java.util.List;

import jakarta.validation.Valid;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class UserController {

    private final UserService service;

    UserController(UserService service) {
        this.service = service;
    }

    @GetMapping("/users")
    List<User> list() {
        return service.list();
    }

    @GetMapping("/users/{id}")
    User get(@PathVariable Long id) {
        return service.get(id);
    }

    @PostMapping("/users")
    @ResponseStatus(HttpStatus.CREATED)
    User create(@Valid @RequestBody CreateUserRequest req) {
        return service.create(req.name());
    }
}
```

`@Valid` 才会触发 DTO 上的校验，漏了它 `@NotBlank` 形同不存在。

### 6. 统一异常处理

```java
package com.example.wizdemo;

import java.util.NoSuchElementException;

import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(MethodArgumentNotValidException.class)
    @ResponseStatus(HttpStatus.BAD_REQUEST)
    ProblemDetail invalid(MethodArgumentNotValidException ex) {
        String detail = ex.getBindingResult().getFieldErrors().stream()
            .map(e -> e.getField() + ": " + e.getDefaultMessage())
            .reduce((a, b) -> a + "; " + b)
            .orElse("参数校验失败");
        return ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, detail);
    }

    @ExceptionHandler(IllegalArgumentException.class)
    @ResponseStatus(HttpStatus.CONFLICT)
    ProblemDetail conflict(IllegalArgumentException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, ex.getMessage());
    }

    @ExceptionHandler(NoSuchElementException.class)
    @ResponseStatus(HttpStatus.NOT_FOUND)
    ProblemDetail notFound(NoSuchElementException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage());
    }
}
```

注意 `ProblemDetail` 在 `org.springframework.http` 包下（不是 `http` 之外）；
工厂方法是 `forStatusAndDetail(...)`，**没有 `valueOf(...)`**。

### 7. application.properties

```properties
spring.application.name=wizdemo

# H2 内存库：每次启动都是新库
spring.datasource.url=jdbc:h2:mem:wizdemo;DB_CLOSE_DELAY=-1
spring.datasource.driverClassName=org.h2.Driver
spring.datasource.username=sa
spring.datasource.password=

# 自动建表，仅原型阶段；正式用 Flyway/Liquibase
spring.jpa.hibernate.ddl-auto=create-drop
spring.jpa.open-in-view=false

# 浏览器开 http://localhost:8080/h2-console
spring.h2.console.enabled=true
spring.h2.console.path=/h2-console
```

`open-in-view=false` 建议显式关掉，否则懒加载字段会在序列化时偷偷查库。

---

## 六、跑起来

```
<leader>mc    编译
<leader>sr    运行（单入口项目使用 ./mvnw spring-boot:run；多入口项目显式指定 spring-boot.run.main-class）
```

日志里出现即为成功：

```
Tomcat started on port 8080 (http) with context path /
Started WizdemoApplication in 2.028 seconds
```

**热重载**：应用跑着时，在 nvim 里 `<C-s>` 存一个 .java 文件，
devtools 会自己重启，不用手动停启（靠保存后触发 jdtls 增量编译）。

---

## 七、验证接口（实测返回）

另开终端（`<leader>tt`）：

```bash
curl -X POST -H "Content-Type: application/json" -d "{\"name\":\"mk\"}" http://localhost:8080/users
curl http://localhost:8080/users
curl http://localhost:8080/users/9999
```

| 请求 | 状态码 | 返回 |
|------|--------|------|
| POST `{\"name\":\"mk\"}` | 201 | `{\"name\":\"mk\",\"id\":1}` |
| POST `{\"name\":\"a\"}` | 400 | `{\"detail\":\"name: 个数必须在2和30之间\",...}` |
| POST 重复的 mk | 409 | `{\"detail\":\"用户名已存在: mk\",...}` |
| GET `/users/9999` | 404 | `{\"detail\":\"用户不存在: 9999\",...}` |

四条都对得上，说明 Controller、校验、事务、异常处理、JPA 全通了。

> 若 curl 报 `Empty reply from server` 而日志显示已 Started，多半是端口被上一次
> 没退干净的实例占了。换端口跑：
> `./mvnw spring-boot:run -Dspring-boot.run.arguments=--server.port=8085`

---

## 八、写测试

```java
package com.example.wizdemo;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.NoSuchElementException;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;

@DataJpaTest
class UserRepositoryTest {

    @Autowired
    private UserRepository repository;

    @Test
    void existsByNameWorks() {
        repository.saveAndFlush(new User("mk"));
        assertThat(repository.existsByName("mk")).isTrue();
        assertThat(repository.existsByName("nope")).isFalse();
    }

    @Test
    void userWithoutTableAliasStillMaps() {
        User saved = repository.saveAndFlush(new User("alice"));
        assertThat(repository.findById(saved.getId()))
            .get()
            .extracting(User::getName)
            .isEqualTo("alice");
    }
}
```

⚠ **`@DataJpaTest` 在 Boot 4 换了包**：

```
旧（Boot 3）：org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest   ← 找不到符号
新（Boot 4）：org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest
```

跑测试：

| 范围 | 按键 |
|------|------|
| 光标所在那一个方法（终端运行） | `<leader>Jt` |
| 当前测试类（终端运行） | `<leader>JT` |
| 光标所在那一个方法（DAP 调试） | `<leader>Jg` |
| 当前测试类（DAP 调试） | `<leader>JG` |
| 整个项目 | `<leader>mt` |

---

## 九、断点调试

普通测试运行和断点调试分开：

- `<leader>Jt`：在终端运行光标处的测试方法，适合日常验证，测试输出会留在终端里；
- `<leader>JT`：在终端运行当前测试类；
- `<leader>Jg`：通过 DAP 调试光标处的测试方法；
- `<leader>JG`：通过 DAP 调试当前测试类。

需要调试业务启动类时，仍使用下面的流程：

```
1. 在 UserService.create 里某行按 <F9> 打断点（行号旁出现 ●）
2. <F5> 启动，向导式扫描带 main() 的类；只有一个就直接跑，多个弹列表让你选
3. 命中后 <F10> 步过 / <F11> 步入 / <F12> 步出
   右侧 dap-ui 看变量与调用栈，底部 REPL 可写表达式求值
4. 用 :DapContinue 放行到下一个断点（⚠ Java 缓冲区中 <F5> 是"重新调试"，不是继续）
```

第一次 `<F5>` 提示「jdtls 仍在导入项目，重试 n/4」是正常的，说明依赖还没索引完。
也可以 `<leader>Jd` 手动重扫主类。

---

## 十、之后再改依赖

IDEA 里改完 pom 会自动重新导入，nvim 这边要手动按一下：

```
<leader>mb        让 jdtls 重新导入并构建（:JavaBuildProjects 同义）
```

改 `pom.xml` 时 lemminx 会给 artifactId / version 补全，
但**它不懂 Maven 语义**，不会告诉你版本冲突，冲突用：

```
<leader>ml        依赖树
```

---

## 踩坑速查

| 现象 | 原因 | 解法 |
|------|------|------|
| 旧向导建的项目一编译就报 Non-resolvable parent POM | 版本号带了 `.RELEASE` | 用 `<leader>sp` 本向导 |
| 启动报 `Failed to configure a DataSource` | 选了 `data-jpa` 但没有可连的库 | 加 `h2` 并配数据源 |
| 第一次插入报 SQL 语法错 | `user` 是 H2/PG 保留字 | `@Table(name = "app_user")` |
| `@DataJpaTest` 找不到符号 | Boot 4 挪包 | 用 `...data.jpa.test.autoconfigure` |
| 教程里的 `-web` 对不上 | Boot 4 artifact 改名为 `starter-webmvc` | Initializr 的 id 仍是 `web`，选它 |
| `@NotBlank` 不生效 | Controller 入参漏了 `@Valid` | 补上 |
| 打开文件没补全 | jdtls 还在导入 | 等 10~60 秒，`:LspInfo` 看 root |
| 改完 pom 依赖不生效 | jdtls 不会自动重导 | `<leader>mb` |
| `<leader>sp` 报找不到 spring 命令 | `~/.local/bin` 不在 PATH，或 `~/.local/share/spring` 不在了 | 重新放一个 `~/.local/bin/spring`，内容 `exec /home/pang/.local/share/spring/spring-4.1.1/bin/spring "$@"` 再 `chmod +x` |

---

## 界面说明

向导的 UI 引擎换过三次，结论记在这里免得走回头路：

| 引擎 | 结论 |
|------|------|
| dressing + nui | 只能整行一个颜色，做不出勾选列与层次；且本机这个 nui 版本没有 preview、没有模糊搜索 |
| telescope | 有多选，但风格与 nui 割裂，得手写 borderchars 才勉强像一张卡片 |
| **snacks.picker** | `format` 返回 Highlight 数组（逐段着色）、内置 ○/● 勾选列与预览、`<Tab>` 默认就是「勾选并下移」 |

⚠ snacks 的行渲染有缓存：光标移动不触发重画（原生靠 CursorLine 显示当前行）。
把「当前行标注」画进 `format`（本向导的 ▸ 指针）必须 patch `List.render`，
在 cursor 变化时强制置 dirty——否则按方向键看着不动（v6.2 踩过，真机 tmux 定位）。

因此装了 `folke/snacks.nvim`，但**只开 picker**：`notifier`（会抢 noice）、
`dashboard`（抢 alpha）、`terminal`（抢 toggleterm）、`input`（抢 dressing）
全部显式关闭，见 `lua/plugins/snacks.lua`。

配色 v6 起直写 catppuccin-mocha 十六进制（不再 link 语义组），与 noice
通知弹框同款；`ColorScheme` 事件时自动重建，换主题不丢。dressing 的
输入框/选择菜单（LSP 重命名、code action 等）也换成同一套
`WizBg/WizBorder` 组，全局浮窗一个血统。

---

## 快捷键

```
<leader>sp     Spring Boot 向导（本文主角）
<leader>sr     运行 Spring Boot
<leader>mc     编译      <leader>mt 跑测试    <leader>mp 打包
<leader>mi     装入本地仓库   <leader>mn 清理   <leader>ml 依赖树
<leader>mb     jdtls 重新导入（改完 pom 必按）

gd 定义   gR 类型定义   gr 引用   gi 实现   gU 父类/接口   gh 文档
[d ]d 上下条错误   <leader>ca 代码操作   <leader>ot 整理 import   <leader>rn 重命名
<leader>Rv/Rm/Rc 提取变量/方法/常量（先可视模式选中）
<leader>Jt 测试方法   <leader>JT 测试类   <leader>Jd 重扫主类
<leader>Gc/Gi/Ge/Gr 生成 Class/Interface/Enum/Record
<F5> 调试启动/继续   <F9> 断点   <F10/F11/F12> 步过/步入/步出

<leader>hk   完整速查表      :LspInfo   :LspLog   :JavaSetRuntime
```

