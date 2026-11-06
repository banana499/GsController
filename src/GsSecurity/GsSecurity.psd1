@{
    RootModule        = 'GsSecurity.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8f3e5c1a-2d74-4e96-b5a2-6c9d0f4b7e13'
    Author            = 'nvidia-gamestream-standalone'
    Description       = 'Read-only ACL policy build and validation for GsController state directories (in-memory SDDL/DirectorySecurity only; no apply path).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'New-GsAclPolicy',
        'Test-GsAclPolicy'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
