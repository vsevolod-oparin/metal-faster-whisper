# PowerShell completion for memory.bat
# Add to your PowerShell profile: . path\to\memory.ps1

$script:memoryCommands = @('add', 'search', 'context', 'list', 'rebuild', 'delete', 'stats', 'maintain')
$script:memoryCategories = @('architecture', 'discovery', 'pattern', 'gotcha', 'config', 'entity', 'decision', 'todo', 'reference', 'context')

Register-ArgumentCompleter -Native -CommandName memory.bat, memory.sh -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $tokens = $commandAst.CommandElements
    $command = $null

    # Find the command (first non-option argument after the script name)
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i].Extent.Text
        if ($token -notlike '-*' -and $token -in $script:memoryCommands) {
            $command = $token
            break
        }
    }

    # If no command yet, complete commands
    if (-not $command) {
        $script:memoryCommands | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
        return
    }

    # Command-specific completions
    switch ($command) {
        'add' {
            # After add, suggest categories
            $prevToken = $tokens[$tokens.Count - 2].Extent.Text
            if ($prevToken -eq 'add') {
                $script:memoryCategories | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
                }
            }
        }
        'list' {
            # Suggest options
            @('-c', '--category', '-l', '--limit', '-o', '--output') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_)
            }
        }
        'maintain' {
            # Suggest maintain options
            @('--max-age', '--execute', '-o', '--output') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_)
            }
        }
    }

    # Option value completions
    $prevToken = $tokens[$tokens.Count - 2].Extent.Text
    switch ($prevToken) {
        { $_ -in '-c', '--category' } {
            $script:memoryCategories | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
        { $_ -in '-o', '--output' } {
            @('text', 'json') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
        { $_ -in '-l', '--limit' } {
            @('5', '10', '20', '50', '100') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
    }
}
