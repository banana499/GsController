#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$BuildOnly,
    [string]$EvidenceDir = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { $EvidenceDir = Join-Path $PSScriptRoot '..\artifacts\stage3' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$build = Join-Path $root 'scripts\build.ps1'
if (-not (Test-Path -LiteralPath $build)) { throw "Missing build entry: $build" }
& $build -CheckTools
if ($LASTEXITCODE -ne 0) { throw 'Tool check failed' }
& $build -Version 0.1.0 -OutputDirectory (Join-Path $EvidenceDir 'msi')
if ($LASTEXITCODE -ne 0) { throw 'MSI build failed' }
if ($BuildOnly) { Write-Host 'Stage 3 build checks passed.'; exit 0 }
& $build -Version 0.1.1 -OutputDirectory (Join-Path $EvidenceDir 'msi')
if ($LASTEXITCODE -ne 0) { throw 'MSI 0.1.1 build failed' }
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Real MSI tests require elevation' }
$target = 'C:\Program Files\Local Development\GsControllerSample'
$userData = Join-Path $env:ProgramData 'Local Development\GsControllerSample\user-data.txt'
New-Item -ItemType Directory -Path (Split-Path -Parent $userData) -Force | Out-Null
Set-Content -LiteralPath $userData -Value 'preserve-me' -NoNewline
$command = Join-Path $target 'Get-SampleInfo.ps1'
function Invoke-Msi([string]$Action, [string]$Msi, [string]$Name, [switch]$FailTest) {
    $log = Join-Path $EvidenceDir ($Name + '.log')
    $args = '/' + $Action + ' "' + $Msi + '" /qn /norestart /L*v "' + $log + '"'
    if ($Name -eq 'custom-directory') { $args += ' INSTALLFOLDER="C:\GsControllerSampleCustom"' }
    if ($FailTest) { $args += ' FAILTEST=1' }
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
    $code = $p.ExitCode
    Write-Host "$Name exit=$code log=$log"
    if ($code -ne 0) { throw "$Name failed: $code" }
}
function Assert-Sample([string]$Version) {
    if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw "Installed command missing: $command" }
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command
    $info = $json | ConvertFrom-Json
    if ($info.Version -ne $Version -or -not $info.Ready) { throw "Unexpected installed app: $json" }
}
function Get-ProductCode([string]$Msi) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Msi, 0))
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @("SELECT `Value` FROM `Property` WHERE `Property`='ProductCode'"))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($null -eq $record) { throw "ProductCode missing: $Msi" }
    return [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
}
try {
    $msi0 = Join-Path $EvidenceDir 'msi\GsControllerSample-0.1.0.msi'
    $msi1 = Join-Path $EvidenceDir 'msi\GsControllerSample-0.1.1.msi'
    $existing = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Where-Object { $_.GetValue('DisplayName') -eq 'GsControllerSample' }
    foreach ($item in $existing) {
        $code = $item.PSChildName
        $clean = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $code, '/qn', '/norestart') -Wait -PassThru
        Write-Host "precleanup $code exit=$($clean.ExitCode)"
    }
    if (Test-Path -LiteralPath $command) { throw "Precleanup did not remove sample command" }
    Invoke-Msi 'i' $msi0 'install-0.1.0'
    Assert-Sample '0.1.0'
    Invoke-Msi 'i' $msi0 'reinstall-0.1.0'
    Assert-Sample '0.1.0'
    $code0 = Get-ProductCode $msi0
    $un0 = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/x ' + $code0 + ' /qn /norestart') -Wait -PassThru
    if ($un0.ExitCode -ne 0) { throw "Custom path setup uninstall failed: $($un0.ExitCode)" }
    $custom = 'C:\GsControllerSampleCustom\Get-SampleInfo.ps1'
    Invoke-Msi 'i' $msi0 'custom-directory'
    if (-not (Test-Path -LiteralPath $custom -PathType Leaf)) { throw 'Non-default install directory was ignored' }
    $unCustom = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/x ' + $code0 + ' /qn /norestart') -Wait -PassThru
    if ($unCustom.ExitCode -ne 0) { throw "Custom path uninstall failed: $($unCustom.ExitCode)" }
    Invoke-Msi 'i' $msi0 'install-0.1.0'
    $failed = $false
    try { Invoke-Msi 'i' $msi1 'rollback-injected' -FailTest } catch { $failed = $true; Write-Host $_.Exception.Message }
    if (-not $failed) { throw 'Injected upgrade failure did not fail' }
    Assert-Sample '0.1.0'
    Write-Host 'Injected upgrade failure preserved working 0.1.0'
    Invoke-Msi 'i' $msi1 'upgrade-0.1.1'
    Assert-Sample '0.1.1'
} finally {
    $productCode = Get-ProductCode $msi1
    $productCode = Get-ProductCode $msi1
    $msiExecArgs = '/x ' + $productCode + ' /qn /norestart /L*v "' + (Join-Path $EvidenceDir 'uninstall.log') + '"'
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiExecArgs -Wait -PassThru
    Write-Host "uninstall exit=$($p.ExitCode) product=$productCode"
    if ($p.ExitCode -ne 0) {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $installer.UILevel = 2
        $installer.ConfigureProduct($productCode, 0, 2)
        Write-Host 'Windows Installer API fallback uninstall completed'
    }
}
if (Test-Path -LiteralPath $command) { throw 'Sample command remains after uninstall' }
if ((Get-Content -LiteralPath $userData -Raw) -ne 'preserve-me') { throw 'User data was not preserved' }
Write-Host 'Stage 3 MSI install, reinstall, rollback, upgrade, uninstall and data preservation passed.'

