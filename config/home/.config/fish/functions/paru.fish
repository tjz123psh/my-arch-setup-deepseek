function paru --description "Use fzf UI for plain package searches, keep paru commands unchanged"
    set -l ui_script "$HOME/scripts/package/paru-ui"

    if test -x "$ui_script"
        if test (count $argv) -eq 0
            command "$ui_script"
            return $status
        end

        if not string match -q -- '-*' $argv[1]
            command "$ui_script" $argv
            return $status
        end
    end

    command paru $argv
end
