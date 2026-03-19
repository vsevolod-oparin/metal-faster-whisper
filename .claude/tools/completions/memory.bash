# Bash completion for memory.sh
# Source this file or add to ~/.bashrc:
# source /path/to/memory.bash

_memory_completions() {
    local cur prev commands categories options
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="add search context list rebuild delete stats maintain"
    categories="architecture discovery pattern gotcha config entity decision todo reference context"
    options="-h --help -t --tags -l --limit -c --category -o --output -q --quiet -v --version --max-age --execute"

    # First argument: command
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands} ${options}" -- "${cur}") )
        return 0
    fi

    # Command-specific completions
    case "${COMP_WORDS[1]}" in
        add)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                # Second arg after add: category
                COMPREPLY=( $(compgen -W "${categories}" -- "${cur}") )
            fi
            ;;
        search|context)
            # No specific completions for query
            ;;
        list)
            case "${prev}" in
                -c|--category)
                    COMPREPLY=( $(compgen -W "${categories}" -- "${cur}") )
                    ;;
                *)
                    COMPREPLY=( $(compgen -W "-c --category -l --limit -o --output" -- "${cur}") )
                    ;;
            esac
            ;;
        delete)
            # Could potentially complete with existing IDs, but that requires running the tool
            ;;
        maintain)
            COMPREPLY=( $(compgen -W "--max-age --execute -o --output" -- "${cur}") )
            ;;
    esac

    # Option value completions
    case "${prev}" in
        -c|--category)
            COMPREPLY=( $(compgen -W "${categories}" -- "${cur}") )
            ;;
        -o|--output)
            COMPREPLY=( $(compgen -W "text json" -- "${cur}") )
            ;;
        -l|--limit)
            COMPREPLY=( $(compgen -W "5 10 20 50 100" -- "${cur}") )
            ;;
    esac

    return 0
}

complete -F _memory_completions memory.sh
complete -F _memory_completions ./memory.sh
complete -F _memory_completions ./.claude/tools/memory.sh
