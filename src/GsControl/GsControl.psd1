@{
    RootModule        = 'GsControl.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6f3c2a1e-4b7d-4c59-9a8e-2d1f0b7c3e41'
    Author            = 'nvidia-gamestream-standalone'
    Description       = 'Stage 1 foundation: path normalization and component manifest reading.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Resolve-GsPath', 'Read-GsManifest')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
