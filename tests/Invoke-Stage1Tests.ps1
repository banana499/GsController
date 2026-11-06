#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 1 unit tests for the GsControl module. No external dependencies.
    Exits 0 only when every test passes; exits 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'src\GsControl\GsControl.psd1'

$script:Passed = 0
$script:Failed = 0

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name :: $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message (expected '$Expected', actual '$Actual')"
    }
}

# Asserts that $Body throws exactly System.ArgumentException with the given ParamName.
function Assert-ArgumentException {
    param([scriptblock]$Body, [string]$ParamName, [string]$Message)
    $caught = $null
    try { & $Body } catch { $caught = $_.Exception }
    if ($null -eq $caught) { throw "Assertion failed: expected ArgumentException: $Message" }
    $typeName = $caught.GetType().FullName
    if ($typeName -ne 'System.ArgumentException') {
        throw "Assertion failed: $Message (expected System.ArgumentException, actual $typeName : $($caught.Message))"
    }
    if ($caught.ParamName -ne $ParamName) {
        throw "Assertion failed: $Message (expected ParamName '$ParamName', actual '$($caught.ParamName)')"
    }
}

function Get-ErrorByField {
    param($Result, [string]$Field)
    # Leading comma keeps a single-element result as an array (no pipeline unrolling).
    return , @($Result.Errors | Where-Object { $_.Field -eq $Field })
}

try {
    Import-Module $manifestPath -Force -ErrorAction Stop
} catch {
    Write-Host "FAIL module import :: $($_.Exception.Message)"
    exit 1
}

$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ("GsControlStage1_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
$originalProcessDir = [System.Environment]::CurrentDirectory

function New-TestFile {
    param([string]$Name, [string]$Content)
    $p = Join-Path $workDir $Name
    [System.IO.File]::WriteAllText($p, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

# Runs $Body with the PowerShell location at $workDir while the .NET process
# current directory points elsewhere, so the two cannot be confused.
function Invoke-InWorkDir {
    param([scriptblock]$Body)
    Push-Location -LiteralPath $workDir
    [System.Environment]::CurrentDirectory = $tempRoot
    try { & $Body } finally {
        Pop-Location
        [System.Environment]::CurrentDirectory = $originalProcessDir
    }
}

try {
    # ---- Resolve-GsPath: normal paths ----
    Invoke-Test 'Resolve-GsPath normalizes absolute path' {
        $raw = Join-Path $workDir 'a\..\b\.\c'
        $actual = Resolve-GsPath -Path $raw
        Assert-Equal (Join-Path $workDir 'b\c') $actual 'normalized path'
        Assert-True ([System.IO.Path]::IsPathRooted($actual)) 'result is rooted'
    }

    Invoke-Test 'Resolve-GsPath resolves relative path against absolute BasePath' {
        $actual = Resolve-GsPath -Path 'x\..\y' -BasePath $workDir
        Assert-Equal (Join-Path $workDir 'y') $actual 'relative resolved'
    }

    Invoke-Test 'Resolve-GsPath without BasePath uses PowerShell location' {
        $actual = Invoke-InWorkDir { Resolve-GsPath -Path 'x' }
        Assert-Equal (Join-Path $workDir 'x') $actual 'resolved against PS location'
    }

    Invoke-Test 'Resolve-GsPath relative BasePath uses PowerShell location' {
        $actual = Invoke-InWorkDir { Resolve-GsPath -Path 'x' -BasePath 'sub' }
        Assert-Equal (Join-Path $workDir 'sub\x') $actual 'relative base resolved against PS location'
    }

    Invoke-Test 'Resolve-GsPath does not require BasePath drive to exist' {
        $actual = Resolve-GsPath -Path 'x' -BasePath 'Q:\nope' -ErrorAction Stop
        Assert-Equal 'Q:\nope\x' $actual 'pure string combination'
    }

    Invoke-Test 'Resolve-GsPath ignores BasePath for absolute Path' {
        $raw = Join-Path $workDir 'z'
        Assert-Equal $raw (Resolve-GsPath -Path $raw -BasePath 'Q:\other') 'absolute path wins'
    }

    Invoke-Test 'Resolve-GsPath accepts UNC path without touching network' {
        $unc = '\\srv\share\a\..\b'
        Assert-Equal '\\srv\share\b' (Resolve-GsPath -Path $unc) 'UNC normalized'
    }

    Invoke-Test 'Resolve-GsPath rejects extended-length prefix' {
        Assert-ArgumentException { Resolve-GsPath -Path '\\?\C:\x' } 'Path' 'extended-length prefix'
    }

    # ---- Resolve-GsPath: rejected input ----
    Invoke-Test 'Resolve-GsPath rejects empty string' {
        Assert-ArgumentException { Resolve-GsPath -Path '' } 'Path' 'empty path'
    }

    Invoke-Test 'Resolve-GsPath rejects whitespace' {
        Assert-ArgumentException { Resolve-GsPath -Path '   ' } 'Path' 'whitespace path'
    }

    Invoke-Test 'Resolve-GsPath rejects null' {
        Assert-ArgumentException { Resolve-GsPath -Path $null } 'Path' 'null path'
    }

    Invoke-Test 'Resolve-GsPath rejects illegal characters' {
        Assert-ArgumentException { Resolve-GsPath -Path 'C:\a<b|c' } 'Path' 'illegal characters'
    }

    Invoke-Test 'Resolve-GsPath rejects colon inside path' {
        Assert-ArgumentException { Resolve-GsPath -Path 'C:\a:b' } 'Path' 'colon in path'
    }

    Invoke-Test 'Resolve-GsPath rejects drive-relative path' {
        Assert-ArgumentException { Resolve-GsPath -Path 'C:foo' } 'Path' 'drive-relative'
    }

    Invoke-Test 'Resolve-GsPath rejects root-relative path' {
        Assert-ArgumentException { Resolve-GsPath -Path '\foo' } 'Path' 'root-relative'
    }

    Invoke-Test 'Resolve-GsPath rejects relative Path with illegal characters' {
        Assert-ArgumentException { Resolve-GsPath -Path 'a<b' -BasePath $workDir } 'Path' 'illegal relative'
    }

    Invoke-Test 'Resolve-GsPath rejects too-long path as ArgumentException' {
        $long = 'C:\' + ('a' * 300)
        Assert-ArgumentException { Resolve-GsPath -Path $long } 'Path' 'too-long path'
    }

    Invoke-Test 'Resolve-GsPath rejects non-filesystem BasePath' {
        Assert-ArgumentException { Resolve-GsPath -Path 'x' -BasePath 'HKLM:\SOFTWARE' } 'BasePath' 'registry base'
    }

    Invoke-Test 'Resolve-GsPath rejects whitespace BasePath' {
        Assert-ArgumentException { Resolve-GsPath -Path 'x' -BasePath ' ' } 'BasePath' 'whitespace base'
    }

    Invoke-Test 'Resolve-GsPath rejects drive-relative BasePath' {
        Assert-ArgumentException { Resolve-GsPath -Path 'x' -BasePath 'C:foo' } 'BasePath' 'drive-relative base'
    }

    # ---- Read-GsManifest: valid ----
    Invoke-Test 'Read-GsManifest accepts valid manifest' {
        $p = New-TestFile 'valid.json' '{ "schemaVersion": 1, "components": [] }'
        $r = Read-GsManifest -Path $p
        Assert-True $r.Success 'Success should be true'
        Assert-Equal $p $r.Path 'Path'
        Assert-Equal 0 @($r.Errors).Count 'no errors'
        Assert-Equal 1 $r.Manifest.schemaVersion 'schemaVersion'
        Assert-Equal 0 @($r.Manifest.components).Count 'components empty'
    }

    # ---- Read-GsManifest: argument errors ----
    Invoke-Test 'Read-GsManifest rejects empty path' {
        Assert-ArgumentException { Read-GsManifest -Path '' } 'Path' 'empty path'
    }

    Invoke-Test 'Read-GsManifest rejects illegal path' {
        Assert-ArgumentException { Read-GsManifest -Path 'C:\a<b.json' } 'Path' 'illegal path'
    }

    # ---- Read-GsManifest: file and JSON errors ----
    Invoke-Test 'Read-GsManifest reports missing file' {
        $r = Read-GsManifest -Path (Join-Path $workDir 'does-not-exist.json')
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'FileNotFound' $r.Errors[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports ReadFailed for locked file' {
        $p = New-TestFile 'locked.json' '{ "schemaVersion": 1, "components": [] }'
        $lock = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
        try { $r = Read-GsManifest -Path $p } finally { $lock.Dispose() }
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 1 @($r.Errors).Count 'one error'
        Assert-Equal 'ReadFailed' $r.Errors[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports empty file as InvalidJson' {
        $p = New-TestFile 'empty.json' ''
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'InvalidJson' $r.Errors[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports whitespace file as InvalidJson' {
        $p = New-TestFile 'blank.json' "  `r`n  "
        $r = Read-GsManifest -Path $p
        Assert-Equal 'InvalidJson' $r.Errors[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports invalid JSON' {
        $p = New-TestFile 'broken.json' '{ "schemaVersion": 1, "components": [ '
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'InvalidJson' $r.Errors[0].Code 'error code'
        Assert-True ($null -eq $r.Manifest) 'Manifest null'
    }

    Invoke-Test 'Read-GsManifest reports JSON that is not an object' {
        $p = New-TestFile 'array.json' '[]'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'InvalidType' $r.Errors[0].Code 'error code'
    }

    # ---- Read-GsManifest: field errors ----
    Invoke-Test 'Read-GsManifest reports missing schemaVersion' {
        $p = New-TestFile 'noschema.json' '{ "components": [] }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-True ($null -eq $r.Manifest) 'Manifest null'
        $e = Get-ErrorByField $r 'schemaVersion'
        Assert-Equal 1 $e.Count 'one schemaVersion error'
        Assert-Equal 'MissingField' $e[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports schemaVersion of wrong type' {
        $p = New-TestFile 'strschema.json' '{ "schemaVersion": "1", "components": [] }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'InvalidType' (Get-ErrorByField $r 'schemaVersion')[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports unsupported schemaVersion 2' {
        $p = New-TestFile 'schema2.json' '{ "schemaVersion": 2, "components": [] }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 1 @($r.Errors).Count 'one error'
        $e = Get-ErrorByField $r 'schemaVersion'
        Assert-Equal 1 $e.Count 'one schemaVersion error'
        Assert-Equal 'UnsupportedValue' $e[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports missing components' {
        $p = New-TestFile 'nocomp.json' '{ "schemaVersion": 1 }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        $e = Get-ErrorByField $r 'components'
        Assert-Equal 1 $e.Count 'one components error'
        Assert-Equal 'MissingField' $e[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports components of wrong type' {
        $p = New-TestFile 'badcomp.json' '{ "schemaVersion": 1, "components": {} }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        $e = Get-ErrorByField $r 'components'
        Assert-Equal 1 $e.Count 'one components error'
        Assert-Equal 'InvalidType' $e[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports components as string' {
        $p = New-TestFile 'strcomp.json' '{ "schemaVersion": 1, "components": "none" }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'InvalidType' (Get-ErrorByField $r 'components')[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest reports non-empty components as unsupported' {
        $p = New-TestFile 'fullcomp.json' '{ "schemaVersion": 1, "components": [ { "id": "x" } ] }'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 'UnsupportedValue' (Get-ErrorByField $r 'components')[0].Code 'error code'
    }

    Invoke-Test 'Read-GsManifest lists all missing fields' {
        $p = New-TestFile 'emptyobj.json' '{}'
        $r = Read-GsManifest -Path $p
        Assert-True (-not $r.Success) 'Success should be false'
        Assert-Equal 2 @($r.Errors).Count 'two errors'
        Assert-Equal 'MissingField' (Get-ErrorByField $r 'schemaVersion')[0].Code 'schemaVersion code'
        Assert-Equal 'MissingField' (Get-ErrorByField $r 'components')[0].Code 'components code'
    }

    Invoke-Test 'Read-GsManifest lists all wrong-type fields' {
        $p = New-TestFile 'alltypes.json' '{ "schemaVersion": "x", "components": {} }'
        $r = Read-GsManifest -Path $p
        Assert-Equal 2 @($r.Errors).Count 'two errors'
        Assert-Equal 'InvalidType' (Get-ErrorByField $r 'schemaVersion')[0].Code 'schemaVersion code'
        Assert-Equal 'InvalidType' (Get-ErrorByField $r 'components')[0].Code 'components code'
    }
} finally {
    [System.Environment]::CurrentDirectory = $originalProcessDir
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
