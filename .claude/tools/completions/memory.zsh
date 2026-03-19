#compdef memory.sh

# Zsh completion for memory.sh
# Add to your .zshrc or place in a directory in your $fpath:
# fpath=(~/.zsh/completions $fpath)

_memory() {
    local -a commands categories

    commands=(
        'add:Add a new memory'
        'search:Search memories (ranked by relevance + recency)'
        'context:Get context block for a topic'
        'list:List all memories'
        'rebuild:Force rebuild index'
        'delete:Delete a memory'
        'stats:Show statistics'
        'maintain:Check database health and clean old memories'
    )

    categories=(
        'architecture:System design, structure'
        'discovery:Things learned during exploration'
        'pattern:Code patterns, conventions'
        'gotcha:Bugs, workarounds, edge cases'
        'config:Configuration, environment'
        'entity:Key classes, functions, APIs'
        'decision:Design decisions, rationale'
        'todo:Pending items, follow-ups'
        'reference:External links, docs'
        'context:Project-specific context'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args' \
        '(-h --help)'{-h,--help}'[Show help message]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-q --quiet)'{-q,--quiet}'[Suppress non-essential output]' \
        '(-t --tags)'{-t,--tags}'[Comma-separated tags]:tags:' \
        '(-l --limit)'{-l,--limit}'[Limit results]:limit:(5 10 20 50 100)' \
        '(-c --category)'{-c,--category}'[Filter by category]:category:(${categories%%:*})' \
        '(-o --output)'{-o,--output}'[Output format]:format:(text json)' \
        '--max-age[Max age in days for maintain]:days:' \
        '--execute[Actually delete old memories]'

    case $state in
        command)
            _describe -t commands 'command' commands
            ;;
        args)
            case $words[1] in
                add)
                    if (( CURRENT == 2 )); then
                        _describe -t categories 'category' categories
                    else
                        _message 'content'
                    fi
                    ;;
                search)
                    _message 'search query'
                    ;;
                context)
                    _message 'topic'
                    ;;
                delete)
                    _message 'memory ID'
                    ;;
                maintain)
                    _arguments \
                        '--max-age[Max age in days]:days:' \
                        '--execute[Actually delete old memories]' \
                        '(-o --output)'{-o,--output}'[Output format]:format:(text json)'
                    ;;
            esac
            ;;
    esac
}

_memory "$@"
