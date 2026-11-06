@{
    RootModule        = 'GsLifecycle.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'b8e4d0a2-61c3-4f7e-9d25-3a7c5e9f1b06'
    Author            = 'nvidia-gamestream-standalone'
    Description       = 'Stage 2: installation config validation and a persisted, validated lifecycle state machine.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Read-GsInstallationConfig',
        'Test-GsInstallationConfig',
        'Get-GsLifecycleTransitionTable',
        'Test-GsLifecycleTransition',
        'Get-GsLifecycleState',
        'Invoke-GsLifecycleTransition',
        'Start-GsLifecycle',
        'Stop-GsLifecycle'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
