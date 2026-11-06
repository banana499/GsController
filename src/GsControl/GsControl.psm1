Set-StrictMode -Version Latest

$script:SupportedSchemaVersion = 1

# Characters rejected anywhere in a path: .NET invalid path chars plus wildcards.
$script:InvalidPathChars = [char[]](@([System.IO.Path]::GetInvalidPathChars()) + [char[]]'<>|"*?')

function New-GsArgumentException {
    param([string]$Message, [string]$ParamName)
    return (New-Object System.ArgumentException($Message, $ParamName))
}

# Classifies a path string without touching the file system or PS drives.
# Returns 'Absolute' (X:\... or \\server\share...), 'Relative', or throws
# ArgumentException(ParamName) for illegal characters, drive-relative (C:foo),
# root-relative (\foo) and provider-qualified (HKLM:\...) forms.
function Get-GsPathKind {
    param([string]$Value, [string]$ParamName)

    if ($Value.IndexOfAny($script:InvalidPathChars) -ge 0) {
        throw (New-GsArgumentException "$ParamName contains illegal characters: '$Value'." $ParamName)
    }
    if ($Value -match '^[A-Za-z]:[\\/]') {
        if ($Value.IndexOf(':', 2) -ge 0) {
            throw (New-GsArgumentException "$ParamName contains ':' outside the drive prefix: '$Value'." $ParamName)
        }
        return 'Absolute'
    }
    if ($Value -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+') {
        if ($Value.IndexOf(':') -ge 0) {
            throw (New-GsArgumentException "$ParamName contains ':' in a UNC path: '$Value'." $ParamName)
        }
        return 'Absolute'
    }
    if ($Value -match '^[A-Za-z]:') {
        throw (New-GsArgumentException "$ParamName is drive-relative and ambiguous: '$Value'." $ParamName)
    }
    if ($Value.IndexOf(':') -ge 0) {
        throw (New-GsArgumentException "$ParamName is not a file system path: '$Value'." $ParamName)
    }
    if ($Value -match '^[\\/]') {
        throw (New-GsArgumentException "$ParamName is root-relative and ambiguous: '$Value'." $ParamName)
    }
    return 'Relative'
}

function ConvertTo-GsFullPath {
    param([string]$Value, [string]$ParamName)
    try {
        return [System.IO.Path]::GetFullPath($Value)
    } catch {
        $inner = $_.Exception
        while ($inner -is [System.Management.Automation.MethodInvocationException] -and $null -ne $inner.InnerException) {
            $inner = $inner.InnerException
        }
        throw (New-GsArgumentException "$ParamName cannot be normalized: '$Value'. $($inner.Message)" $ParamName)
    }
}

function Resolve-GsPath {
    <#
    .SYNOPSIS
        Normalizes a path to an absolute, canonical form. Does not touch the file system.
    .PARAMETER Path
        Absolute (X:\... or \\server\share\...) or relative path. Null, empty,
        whitespace-only, drive-relative, root-relative, provider-qualified and
        illegal-character values throw System.ArgumentException (ParamName Path).
    .PARAMETER BasePath
        Base for relative paths. Defaults to the current PowerShell FileSystem
        location. A relative BasePath is resolved against that location. Invalid
        values throw System.ArgumentException (ParamName BasePath).
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw (New-GsArgumentException 'Path must not be null, empty or whitespace.' 'Path')
    }
    $pathKind = Get-GsPathKind -Value $Path -ParamName 'Path'

    $hasBase = $PSBoundParameters.ContainsKey('BasePath')
    if ($hasBase -and [string]::IsNullOrWhiteSpace($BasePath)) {
        throw (New-GsArgumentException 'BasePath must not be empty or whitespace when specified.' 'BasePath')
    }
    $baseKind = $null
    if ($hasBase) { $baseKind = Get-GsPathKind -Value $BasePath -ParamName 'BasePath' }

    if ($pathKind -eq 'Absolute') {
        return (ConvertTo-GsFullPath -Value $Path -ParamName 'Path')
    }

    # Relative Path: build an absolute base from PowerShell state, never from
    # the .NET process current directory.
    if (-not $hasBase -or $baseKind -eq 'Relative') {
        $location = (Get-Location -PSProvider FileSystem).ProviderPath
        if ($hasBase) {
            $base = [System.IO.Path]::Combine($location, $BasePath)
        } else {
            $base = $location
        }
    } else {
        $base = $BasePath
    }

    return (ConvertTo-GsFullPath -Value ([System.IO.Path]::Combine($base, $Path)) -ParamName 'Path')
}

function New-GsManifestError {
    param([string]$Code, [string]$Field, [string]$Message)
    [pscustomobject]@{
        Code    = $Code
        Field   = $Field
        Message = $Message
    }
}

function New-GsManifestResult {
    param([string]$Path, $Manifest, [object[]]$Errors)
    $errs = @($Errors)
    [pscustomobject]@{
        Success  = ($errs.Count -eq 0)
        Path     = $Path
        Manifest = $(if ($errs.Count -eq 0) { $Manifest } else { $null })
        Errors   = $errs
    }
}

function Read-GsManifest {
    <#
    .SYNOPSIS
        Reads and validates a stage-1 component manifest (JSON).
    .DESCRIPTION
        Never throws for content problems; returns a result object with
        Success, Path, Manifest and Errors (Code, Field, Message).
        Throws only for invalid arguments (empty Path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    $fullPath = Resolve-GsPath -Path $Path

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return New-GsManifestResult -Path $fullPath -Manifest $null -Errors @(
            New-GsManifestError -Code 'FileNotFound' -Field '' -Message "Manifest file not found: $fullPath")
    }

    try {
        $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    } catch {
        return New-GsManifestResult -Path $fullPath -Manifest $null -Errors @(
            New-GsManifestError -Code 'ReadFailed' -Field '' -Message $_.Exception.Message)
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-GsManifestResult -Path $fullPath -Manifest $null -Errors @(
            New-GsManifestError -Code 'InvalidJson' -Field '' -Message 'Manifest file is empty.')
    }

    try {
        # -InputObject with a single string avoids pipeline unrolling of top-level arrays.
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        return New-GsManifestResult -Path $fullPath -Manifest $null -Errors @(
            New-GsManifestError -Code 'InvalidJson' -Field '' -Message $_.Exception.Message)
    }

    if (-not ($data -is [System.Management.Automation.PSCustomObject])) {
        return New-GsManifestResult -Path $fullPath -Manifest $null -Errors @(
            New-GsManifestError -Code 'InvalidType' -Field '' -Message 'Manifest root must be a JSON object.')
    }

    $errors = New-Object System.Collections.Generic.List[object]
    $names = @($data.PSObject.Properties | ForEach-Object { $_.Name })

    if ($names -notcontains 'schemaVersion') {
        $errors.Add((New-GsManifestError -Code 'MissingField' -Field 'schemaVersion' -Message 'Required field schemaVersion is missing.'))
    } else {
        $sv = $data.schemaVersion
        if (-not ($sv -is [int] -or $sv -is [long])) {
            $errors.Add((New-GsManifestError -Code 'InvalidType' -Field 'schemaVersion' -Message 'schemaVersion must be an integer.'))
        } elseif ($sv -ne $script:SupportedSchemaVersion) {
            $errors.Add((New-GsManifestError -Code 'UnsupportedValue' -Field 'schemaVersion' -Message "schemaVersion $sv is not supported; expected $script:SupportedSchemaVersion."))
        }
    }

    if ($names -notcontains 'components') {
        $errors.Add((New-GsManifestError -Code 'MissingField' -Field 'components' -Message 'Required field components is missing.'))
    } else {
        $comp = $data.components
        if (-not ($comp -is [System.Array])) {
            $errors.Add((New-GsManifestError -Code 'InvalidType' -Field 'components' -Message 'components must be a JSON array.'))
        } elseif ($comp.Length -ne 0) {
            $errors.Add((New-GsManifestError -Code 'UnsupportedValue' -Field 'components' -Message 'Stage 1 only accepts an empty components array.'))
        }
    }

    return New-GsManifestResult -Path $fullPath -Manifest $data -Errors $errors.ToArray()
}

Export-ModuleMember -Function Resolve-GsPath, Read-GsManifest
