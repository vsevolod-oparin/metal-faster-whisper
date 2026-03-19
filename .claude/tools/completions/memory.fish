# Fish completion for memory.sh
# Place in ~/.config/fish/completions/memory.sh.fish

set -l commands add search context list rebuild delete stats maintain
set -l categories architecture discovery pattern gotcha config entity decision todo reference context

# Disable file completions
complete -c memory.sh -f

# Commands
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a add -d 'Add a new memory'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a search -d 'Search memories'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a context -d 'Get context block for a topic'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a list -d 'List all memories'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a rebuild -d 'Force rebuild index'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a delete -d 'Delete a memory'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a stats -d 'Show statistics'
complete -c memory.sh -n "not __fish_seen_subcommand_from $commands" -a maintain -d 'Check database health'

# Global options
complete -c memory.sh -s h -l help -d 'Show help message'
complete -c memory.sh -s v -l version -d 'Show version'
complete -c memory.sh -s q -l quiet -d 'Suppress non-essential output'
complete -c memory.sh -s t -l tags -d 'Comma-separated tags' -r
complete -c memory.sh -s l -l limit -d 'Limit results' -x -a '5 10 20 50 100'
complete -c memory.sh -s c -l category -d 'Filter by category' -x -a "$categories"
complete -c memory.sh -s o -l output -d 'Output format' -x -a 'text json'

# Maintain command options
complete -c memory.sh -n "__fish_seen_subcommand_from maintain" -l max-age -d 'Max age in days' -r
complete -c memory.sh -n "__fish_seen_subcommand_from maintain" -l execute -d 'Actually delete old memories'

# Category completion for 'add' command
complete -c memory.sh -n "__fish_seen_subcommand_from add; and test (count (commandline -opc)) -eq 2" -a "$categories"
