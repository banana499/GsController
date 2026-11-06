@{
    RootModule        = 'GsRuntime.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd4c9f7a1-2b6e-4a83-9c15-7e8b0d3f5a62'
    Author            = 'nvidia-gamestream-standalone'
    Description       = 'Stage 4: portable runtime layout, config and component plan for the private stack.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'New-GsRuntimeLayout',
        'Read-GsRuntimeConfig',
        'Write-GsRuntimeConfig',
        'Test-GsRuntimeLayout',
        'New-GsRuntimePlan',
        'New-GsComponentCatalog',
        'Import-GsRuntimeTree',
        'Install-GsRuntimeBundle',
        'Test-GsRuntimeBundle'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
