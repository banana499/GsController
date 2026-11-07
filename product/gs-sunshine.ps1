#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Sunshine detection helpers for the local console server
  (SUNSHINE-BACKEND-CONTRACT.md, worker A).

.DESCRIPTION
  Pure function library. Dot-sourcing this file defines functions ONLY:
  no probe runs at import time, no file is written, no network byte is
  sent, nothing is spawned. It stays ASCII and has no dependencies.

  Hard boundaries:
  - "installed" is file-metadata detection at the KNOWN OFFICIAL default
    location(s) only (%ProgramFiles%\Sunshine\sunshine.exe). It never
    claims to verify a publisher or a version, and never reads the
    registry, services, scheduled tasks, running processes or any
    credential material.
  - The management-port check is a single outbound TCP connect attempt to
    127.0.0.1 with a hard timeout clamped to at most 1000 ms. No HTTP is
    spoken, no TLS session is started, no certificate is inspected and
    nothing is ever logged in or bypassed. A connection refusal is a
    definite "closed"; a timeout is also a definite "closed" for this
    purpose (nothing accepted a connection within the budget); any other
    unexpected failure is "unknown" ($null) and is never reported as a
    definite negative.
  - Every probe accepts injectable seams (-InstallCandidates,
    -ExistenceProbe, -TcpProbe) so tests can exercise the true / false /
    null outcomes with TEMP fixtures and fake probes. No real Sunshine
    installation, download or service is ever required or touched.

  This file contains no writes, no process creation and no web access by
  construction; the console composes the demo/live decision on top.
#>

function Resolve-GsSunshineTimeoutMs {
    # Clamps the probe budget to the contractual [1, 1000] ms window.
    param([int]$TimeoutMs = 1000)
    if ($TimeoutMs -lt 1) { return 1 }
    if ($TimeoutMs -gt 1000) { return 1000 }
    return $TimeoutMs
}

function Get-GsSunshineDefaultInstallCandidates {
    # The official Windows MSI default location only. Custom install
    # locations are deliberately NOT guessed; an unseen location yields
    # "not detected" (the UI explains that a custom location may simply
    # not have been detected). The comma before $candidates preserves the
    # array shape for a single candidate (pipeline unrolling would hand
    # back a bare string otherwise).
    $candidates = @()
    try {
        $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
            $candidates += (Join-Path $programFiles 'Sunshine\sunshine.exe')
        }
    } catch { }
    return ,$candidates
}

function Test-GsSunshineInstalled {
    # Existence + size metadata at the known default location(s).
    #   Installed    = $true   -> a candidate exists as a file
    #   Installed    = $false  -> every candidate was checked, none exists
    #   Installed    = $null   -> nothing could be determined (no usable
    #                             candidates, a probe error, a non-boolean
    #                             probe result); never a false negative
    #   InstalledPath = first matching candidate, else ''
    param(
        [AllowEmptyCollection()][string[]]$InstallCandidates = @(),
        [AllowNull()][scriptblock]$ExistenceProbe = $null
    )
    $candidates = $InstallCandidates
    if ($null -eq $candidates) { $candidates = @() }
    if ($candidates.Count -eq 0) { $candidates = Get-GsSunshineDefaultInstallCandidates }
    if ($candidates.Count -eq 0) {
        return @{ Installed = $null; InstalledPath = '' }
    }
    $checkedAny = $false
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $exists = $null
        try {
            if ($null -ne $ExistenceProbe) {
                $exists = & $ExistenceProbe -Path $candidate
                if ($exists -isnot [bool]) { $exists = $null }
            } else {
                if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop) {
                    # Touch the file metadata once; a size read failure is
                    # an unknown, not a definite negative.
                    $info = Get-Item -LiteralPath $candidate -ErrorAction Stop
                    $null = $info.Length
                }
                $exists = [bool](Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop)
            }
        } catch { $exists = $null }
        if ($null -eq $exists) {
            return @{ Installed = $null; InstalledPath = '' }
        }
        if ($exists) {
            return @{ Installed = $true; InstalledPath = $candidate }
        }
        $checkedAny = $true
    }
    if (-not $checkedAny) {
        return @{ Installed = $null; InstalledPath = '' }
    }
    return @{ Installed = $false; InstalledPath = '' }
}

function Test-GsSunshineManagementPort {
    # One TCP connect attempt against 127.0.0.1:<Port>. Nothing above the
    # transport layer ever happens. Returns $true (a peer accepted the
    # connection), $false (refused or no acceptance within the clamped
    # budget) or $null (unexpected failure; unknown, not "closed").
    param(
        [int]$Port = 47990,
        [int]$TimeoutMs = 1000,
        [AllowNull()][scriptblock]$TcpProbe = $null
    )
    $timeout = Resolve-GsSunshineTimeoutMs -TimeoutMs $TimeoutMs
    if ($null -ne $TcpProbe) {
        try {
            $result = & $TcpProbe -Port $Port -TimeoutMs $timeout
            if ($result -is [bool]) { return $result }
            return $null
        } catch { return $null }
    }
    if ($Port -lt 1 -or $Port -gt 65535) { return $null }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        try {
            if (-not $task.Wait($timeout)) { return $false }
        } catch [System.AggregateException] {
            # A refusal is a definite negative; other socket/OS failures
            # are unknown and must not be reported as a closed port.
            $failure = $_.Exception.GetBaseException()
            if ($failure -is [System.Net.Sockets.SocketException] -and
                $failure.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
                return $false
            }
            return $null
        }
        return ([bool]$client.Connected)
    } catch {
        return $null
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-GsSunshineProbeSnapshot {
    # Composes both probes into one record. Mode logic (live vs demo) and
    # the status DTO live in the console; this stays probe-only.
    param(
        [AllowEmptyCollection()][string[]]$InstallCandidates = @(),
        [AllowNull()][scriptblock]$ExistenceProbe = $null,
        [int]$Port = 47990,
        [int]$TimeoutMs = 1000,
        [AllowNull()][scriptblock]$TcpProbe = $null
    )
    $installed = Test-GsSunshineInstalled -InstallCandidates $InstallCandidates -ExistenceProbe $ExistenceProbe
    $portOpen = Test-GsSunshineManagementPort -Port $Port -TimeoutMs $TimeoutMs -TcpProbe $TcpProbe
    return @{
        Installed         = $installed.Installed
        InstalledPath     = $installed.InstalledPath
        ManagementPortOpen = $portOpen
    }
}
