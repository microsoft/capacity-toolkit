@{
    # PSScriptAnalyzer configuration for the capacity toolkit CI.
    #
    # The scripts are interactive, Reader-only Azure CLI tools that target Windows
    # PowerShell 5.1. A few default rules do not fit that design and are excluded here so
    # the remaining findings stay actionable:
    #
    #   PSAvoidUsingWriteHost              - the scripts are console UX tools; coloured
    #                                        Write-Host output is intentional and by design.
    #   PSAvoidUsingPositionalParameters  - fires on the many `az ...` external-command
    #                                        calls, which are not PowerShell cmdlets.
    #   PSUseSingularNouns                 - several public script/function names ship with
    #                                        plural nouns (Get-ZoneMappings, Get-QuotaGroups,
    #                                        Get-CapacityReservations); renaming is breaking.
    #   PSUseApprovedVerbs                 - Scan-SkuEnablement / Watch-SkuEnablement are
    #                                        established public command names.
    #
    # Everything else runs at its default severity. CI fails the build on any Error-severity
    # finding (and on a Windows PowerShell 5.1 parse error); Warnings are surfaced but do not
    # block, so they can be triaged over time.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingPositionalParameters',
        'PSUseSingularNouns',
        'PSUseApprovedVerbs'
    )
}
