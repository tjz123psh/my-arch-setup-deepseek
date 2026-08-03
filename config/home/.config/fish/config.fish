# 私有环境变量（从独立文件加载，不提交版本控制）

# 用户自定义脚本路径
fish_add_path -g ~/scripts/maintenance
fish_add_path -g ~/scripts
fish_add_path -g ~/Projects/gpt/scripts

if status is-interactive
# Commands to run in interactive sessions can go here
set fish_greeting ""
starship init fish | source

# 树形目录查看（需安装 eza）
function lt
    command eza --icons --tree $argv
end
end



# >>> maintenance terminal-tools >>>
# 由 ~/scripts/maintenance/terminal-tools 管理；可用 terminal-tools --disable 撤销。
# 仅交互式 Fish 使用：脚本和非交互命令不会受到 cat 别名影响。
if status is-interactive
    if type -q zoxide
        zoxide init fish | source
    end

    # bat 提供语法高亮；--paging=never 避免在短输出和脚本复制时出现额外分页器。
    if type -q bat
        alias cat 'bat --paging=never --style=plain'
    end
end
# <<< maintenance terminal-tools <<<

# Codex/OpenAI 凭据不进入仓库。若存在私有环境文件，则由当前用户显式维护。
if test -r ~/.config/fish/private-env.fish
    source ~/.config/fish/private-env.fish
end
