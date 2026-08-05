# nemo 文件管理器（替换 nautilus）

把默认文件管理器从 nautilus 换成 nemo（Cinnamon 的 Nautilus fork），中文界面、跟随 DMS 动态配色、带缩略图。nautilus 保留不卸载，仅不再作默认。

## 安装的包

| 包 | 作用 |
| --- | --- |
| `nemo` | 主体（6.6.4） |
| `cinnamon-translations` | nemo 的 zh_CN 翻译（`/usr/share/locale/zh_CN/LC_MESSAGES/nemo.mo`），系统 `LC_MESSAGES=zh_CN` 时自动生效 |
| `ffmpegthumbnailer` | 视频缩略图 |
| `tumbler` | 缩略图服务（图片/PDF/字体等），nemo 依赖它出缩略图 |
| `nemo-fileroller` | 右键压缩/解压 |
| `adw-gtk-theme` | 提供 `adw-gtk3` / `adw-gtk3-dark` 主题（见下） |

装法：`gsudo pacman -S --needed --noconfirm nemo cinnamon-translations ffmpegthumbnailer tumbler nemo-fileroller adw-gtk-theme`（gsudo 弹 fuzzel 密码框）。

## 美化 / 动态配色机制

- GTK 主题名由 `gsettings get org.gnome.desktop.interface gtk-theme` 控制，之前设的是 `adw-gtk3-dark`，但 **`adw-gtk-theme` 包一直没装**，所以 GTK3 应用一直回退到内置 Adwaita。装上后 `adw-gtk3-dark` 才真实存在于 `/usr/share/themes/`。
- 配色跟随 DMS：DMS 的 matugen 钩子持续把 Material 动态色写入 `~/.config/gtk-3.0/dank-colors.css` 和 `~/.config/gtk-4.0/`。nemo 是 GTK3 应用自动继承，所以配色随壁纸/主题变，与桌面一致。对应 DMS 模板 `gtk3-dark.toml`（output 到 `CONFIG_DIR/gtk-3.0/dank-colors.css`）。
- 图标主题：当前用系统内置 `Adwaita`（`gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'`）。曾试过 Papirus-Dark（`papirus-icon-theme` + AUR `papirus-folders` 染色），后按需求卸载（`sudo pacman -Rns papirus-folders papirus-icon-theme`）并把图标主题指回 `Adwaita`。DMS **不管理** icon-theme，改图标主题安全、不与 DMS 打架。若日后想重装 Papirus：`papirus-folders` 只在 AUR，不能与 `papirus-icon-theme` 放同一条 pacman 命令（会导致整个事务中止）。
- nemo 启动时的 `Current gtk theme is not known to have nemo support (adw-gtk3-dark) - checking...` 是良性 warning，它会自行 check 通过。`Action '90_new-launcher... missing dependency: cinnamon-desktop-editor` 也是良性（缺"新建启动器"右键项，不影响使用）。

## Nemo 窗口外壳精修（gtk.css + nemo.css）

图标主题只改文件/文件夹图标，窗口"外壳"（菜单栏、工具栏按钮、侧边栏、路径栏、滚动条、选中态）由 GTK 主题 + 自定义 CSS 控制。nemo 是 GTK3 应用（官方明确长期停留 GTK3，不上 libadwaita），无法做到胶囊侧栏等现代外观，只能在 GTK3 框架内精修。

- **安全注入点**：`~/.config/gtk-3.0/gtk.css` 原为指向 `dank-colors.css` 的软链，现改为**真文件**，内容是两条 `@import`：`dank-colors.css`（DMS 动态色）+ `nemo.css`（精修）。DMS matugen 只重写 `dank-colors.css`，**不碰 `gtk.css`**，所以自定义样式不会被覆盖。
- **`~/.config/gtk-3.0/nemo.css`**：所有选择器限定在 `.nemo-window`（或 `nemo-canvas-item`/`NemoPathbarButton` 等 nemo 专属节点）下，只影响 nemo，不动其它 GTK 应用；颜色全部引用 DMS 动态色变量（`@accent_bg_color`/`@accent_fg_color`/`@window_fg_color`），随主题自动变。精修内容：侧边栏悬停/选中强调色高亮+圆角+行距、工具栏按钮圆角+hover、路径栏按钮圆角、图标/列表选中圆角高亮、输入框圆角、滚动条变细、磁盘占用条配色。
- **还原**：`rm ~/.config/gtk-3.0/{gtk.css,nemo.css} && ln -s dank-colors.css ~/.config/gtk-3.0/gtk.css`（`gtk.css` 原本就是指向 `dank-colors.css` 的软链，还原命令直接重建即可，无需额外备份）。
- 改样式后刷新：关掉 nemo（`nemo --quit` 或 `pkill nemo`）重开即可，无需注销。

## 隐藏菜单栏（gsettings 结构精简）

nemo 的窗口外壳除 CSS 外还能靠 gsettings 精简。已隐藏顶部菜单栏让界面更清爽：`gsettings set org.nemo.window-state start-with-menu-bar false`。

- 隐藏后**敲一下 `Alt` 键**或**右键工具栏空白处**可临时呼出菜单栏。
- 恢复常驻：`gsettings set org.nemo.window-state start-with-menu-bar true`。
- 相关同类项（均在 `org.nemo.window-state`，默认 `true`）：`start-with-sidebar`（侧边栏，运行时 `F9` 切换）、`start-with-toolbar`（工具栏）、`start-with-status-bar`（状态栏，含右下角缩放滑块）。按需 `false` 精简。
- 注意：`F9` 是 nemo 内置的**侧边栏**开关，不是菜单栏；菜单栏无固定呼出快捷键，只有 `Alt`/右键两种方式。

## 右键"打开终端"修复

nemo 右键"在此打开终端"调用的终端由 `gsettings get org.cinnamon.desktop.default-applications.terminal exec` 决定，原值是未安装的 `gnome-terminal`，故点击无反应。已 `gsettings set org.cinnamon.desktop.default-applications.terminal exec 'kitty'`（`exec-arg` 保持 `--`）。

## 为什么不卸载 nautilus

`nautilus` 有硬依赖链 `nautilus ← xdg-desktop-portal-gnome ← niri`：`xdg-desktop-portal-gnome` 硬依赖 nautilus，niri 又硬依赖前者。强删 nautilus 会级联移除 portal，破坏 niri 的文件选择框/截图门户。**结论：保留 nautilus 仅作 portal 后端，只把默认文件管理器指向 nemo 即可**（已达到不再用到 nautilus 的目的）。用 `pactree -r nautilus` 可复查依赖链。

## 设为默认文件管理器（三处 + xdg）

- Hyprland：`~/.config/hypr/conf/keybinds.lua` 的 `local fileManager`（Super+E）。
- niri：`~/.config/niri/dms/keybinds.kdl` 的 `Mod+E`（实际加载的中文版）；`dms/binds.kdl` 是英文备份，同步改。
- hypr-keys 速查数据源：`~/.config/hypr/keybinds.list`。
- xdg 默认处理器：`xdg-mime default nemo.desktop inode/directory`。
  - 注意：之前 `inode/directory` 被误设成 `kitty-open.desktop`（打开文件夹会进 kitty），一并修正。

## 验证

- 中文：nemo 窗口标题「主目录」、菜单「文件/编辑/查看/转到/书签/帮助」、底栏「N 项，剩余空间」全中文。
- 配色：深色背景跟随 DMS 深色主题，adw-gtk3-dark 生效。
- 缩略图：图片/视频文件显示真实缩略图 = tumbler + ffmpegthumbnailer 生效。
- 截图技巧：本机 Hyprland 是 scrolling 布局，窗口可能被滚出视口（x 超过屏宽）导致 grim 抓到黑边。截 nemo 前确认 `hyprctl clients -j` 里它的 `at`+`size` 完全落在 1920 内，再按其几何截图。
