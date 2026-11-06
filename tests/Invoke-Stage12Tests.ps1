#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProductPath = 'C:\Program Files\Local Development\GsController\gs-product.ps1',
    [string]$StateDir = 'C:\ProgramData\Local Development\GsController',
    [string]$LogDir = 'C:\ProgramData\Local Development\GsControllerLogs'
)
$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passed++; Write-Host "PASS $Name" } else { $script:failed++; Write-Host "FAIL $Name" }
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Stage 12 requires elevation' }
$eventMax = 0
try { $eventMax = [long](Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7023,7031 } -MaxEvents 1).RecordId } catch { }
$appPid = (Get-CimInstance Win32_Service -Filter "Name='NvContainerLocalSystem'").ProcessId
try {
    $reg = & $ProductPath -Action RegisterAutostart -StateDir $StateDir -LogDir $LogDir
    Assert-True $reg.Success 'product RegisterAutostart succeeds'
    if (-not $reg.Success) { throw 'RegisterAutostart failed' }
    $task = Get-ScheduledTask -TaskName 'GsControllerSupervisor' -ErrorAction SilentlyContinue
    Assert-True ($null -ne $task) 'task GsControllerSupervisor exists'
    Assert-True ($task.Principal.UserId -eq 'SYSTEM' -and $task.Principal.RunLevel -eq 'Highest') 'task runs as SYSTEM/Highest'
    Assert-True ([string]$task.Actions[0].Arguments -match 'runtime\\bin\\gs_supervisor\.ps1') 'task points at product supervisor'

    Start-ScheduledTask -TaskName 'GsControllerSupervisor'
    $deadline = (Get-Date).AddSeconds(90)
    $info = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $info = Get-ScheduledTaskInfo -TaskName 'GsControllerSupervisor'
        if ($info.LastTaskResult -eq 0) { break }
    }
    Assert-True ($info.LastTaskResult -eq 0) 'scheduled cycle returns 0'
    $supLog = Join-Path $StateDir 'runtime\bin\_supervisor.log'
    Assert-True (Test-Path -LiteralPath $supLog) 'supervisor log written'
    $paused = Select-String -LiteralPath $supLog -Pattern 'PAUSED' -Quiet -ErrorAction SilentlyContinue
    Assert-True $paused 'supervisor respects manual pause flag'

    $unreg = & $ProductPath -Action UnregisterAutostart -StateDir $StateDir -LogDir $LogDir
    Assert-True $unreg.Success 'product UnregisterAutostart succeeds'
    $gone = Get-ScheduledTask -TaskName 'GsControllerSupervisor' -ErrorAction SilentlyContinue
    Assert-True ($null -eq $gone) 'task removed'

    $newEvents = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7023,7031 } -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { [long]$_.RecordId -gt $eventMax -and [string]$_.Properties[0].Value -match 'VIDIA' })
    Assert-True ($newEvents.Count -eq 0) 'no new NVIDIA service failures'
    $appPidAfter = (Get-CimInstance Win32_Service -Filter "Name='NvContainerLocalSystem'").ProcessId
    Assert-True ($appPid -eq $appPidAfter) 'NVIDIA App PID unchanged'
} finally {
    Get-ScheduledTask -TaskName 'GsControllerSupervisor' -ErrorAction SilentlyContinue | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false }
}
Write-Host ("Summary: {0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
