#
# PSScriptAnalyzer configuration for the Moddex Windows scripts.
#
# These are operator-facing installer scripts, not a reusable module. A few
# default rules encode assumptions that do not hold here; they are excluded
# deliberately and with a reason, so the remaining findings are all actionable.
# Anything not listed stays enabled — silencing a rule to make a run green is
# how a linter stops being worth running.
#
@{
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # The installer's entire job is to talk to the operator at a console.
        # Write-Output would pollute the pipeline with log lines, and
        # Write-Information is invisible without -InformationAction. Write-Host
        # is the correct choice for interactive installer output.
        'PSAvoidUsingWriteHost',

        # 'Write-Log' collides with a cmdlet shipped in some Windows PowerShell
        # module inventories, but not in any module these scripts load. The
        # local helper is unambiguous within the script scope.
        'PSAvoidOverwritingBuiltInCmdlets'
    )

    Rules = @{
        # Installer scripts are read and audited by administrators before they
        # run them as SYSTEM. Consistent casing keeps diffs reviewable.
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
    }
}
