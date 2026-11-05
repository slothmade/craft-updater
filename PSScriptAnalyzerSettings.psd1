# Settings for PSScriptAnalyzer (code analysis in the Tests workflow).
# The excluded rules are intentional design choices of this project, not oversights:
@{
    ExcludeRules = @(
        # Console output for the user is the whole point of the console mode.
        'PSAvoidUsingWriteHost',
        # Short helper names such as Parse-Version and Norm-Publisher are kept for readability.
        'PSUseApprovedVerbs',
        # Write-Warning is wrapped on purpose so every warning also lands in the error report.
        'PSAvoidOverwritingBuiltInCmdlets',
        # The script is not a module; -WhatIf/-Confirm support is not offered.
        'PSUseShouldProcessForStateChangingFunctions',
        # Plural nouns describe what the helpers return (e.g. Find-RegistryEntries).
        'PSUseSingularNouns'
    )
}
