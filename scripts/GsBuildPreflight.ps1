#requires -Version 5.1
<#
.SYNOPSIS
  Build preflight helpers for scripts\build-product.ps1.

.DESCRIPTION
  Pure validation helpers plus the aggregated preflight that the product
  build invokes BEFORE it deletes or creates anything. The checks:

    - MSI ProductVersion grammar with the Windows Installer numeric limits
      (major 0-255, minor 0-255, build 0-65535). Parsing uses TryParse so
      out-of-range input is reported as a structured violation instead of
      surfacing as an unstructured overflow exception.
    - Physical-path overlap between every user-supplied path (runtime
      bundle, WiX tools, output directory) and the build work directories
      (product stage, wix build directory) and the source inputs (product
      directory, module directories). Overlap is decided on physically
      resolved paths: junctions, directory symbolic links and 8.3 short
      names are expanded through the file system, and lexical inputs are
      normalized (relative parts against the repository root, '.'/'..'
      segments, mixed separators, trailing separators, ordinal
      case-insensitive comparison), so look-alike spellings cannot bypass
      a check and no work directory that may point at an input is ever
      deleted.

  These helpers never read file content, never execute anything found in
  the inputs, and never create or delete files. No signing and no runtime
  bundle content validation happens here.
#>

function ConvertTo-GsCanonicalLexical {
    <#
    .SYNOPSIS
      Normalizes a path lexically, without touching the file system.
    .DESCRIPTION
      Relative paths are resolved against -BaseDir, separators are unified,
      '.'/'..' segments are collapsed, trailing separators are trimmed and
      the Win32 device prefixes ('\\?\C:\...', '\\?\UNC\server\share\...')
      are unwrapped so the result is comparable with plain Win32 paths.
      Returns a string without a trailing separator ('C:\' becomes 'C:').
      Throws on empty or whitespace input.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$BaseDir
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is empty or whitespace.' }
    if ([string]::IsNullOrWhiteSpace($BaseDir)) { throw 'BaseDir is empty or whitespace.' }
    $p = $Path.Trim()
    if (-not [IO.Path]::IsPathRooted($p)) {
        $p = Join-Path ([IO.Path]::GetFullPath($BaseDir)) $p
    }
    if ($p.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $p = '\\' + $p.Substring(8)
    }
    elseif ($p.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $p = $p.Substring(4)
    }
    $p = [IO.Path]::GetFullPath($p)
    return $p.TrimEnd('\', '/')
}

function Test-GsPathOverlap {
    <#
    .SYNOPSIS
      Returns $true when two canonical paths denote the same or a nested
      location (ancestor/descendant in either direction).
    .DESCRIPTION
      Inputs must already be canonical (output of
      ConvertTo-GsCanonicalLexical or Resolve-GsPhysicalPath). The
      comparison is ordinal case-insensitive and component-boundary aware:
      'C:\a\b' overlaps 'C:\a' but not 'C:\ab'. An empty canonical path
      (a drive-relative root) overlaps everything as a safety default.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory)][AllowEmptyString()][string]$B
    )
    if ($A.Length -eq 0 -or $B.Length -eq 0) { return $true }
    if ($A.Length -eq $B.Length) {
        return $A.Equals($B, [StringComparison]::OrdinalIgnoreCase)
    }
    if ($A.Length -lt $B.Length) {
        return (($B[$A.Length] -eq '\') -and $B.StartsWith($A, [StringComparison]::OrdinalIgnoreCase))
    }
    return (($A[$B.Length] -eq '\') -and $A.StartsWith($B, [StringComparison]::OrdinalIgnoreCase))
}

function Test-GsMsiVersionString {
    <#
    .SYNOPSIS
      Validates a string as an MSI ProductVersion.
    .DESCRIPTION
      Accepts exactly three dot-separated numeric fields with the Windows
      Installer limits major 0-255, minor 0-255, build 0-65535. Leading
      zeros are allowed ('01.02.03'). Fields longer than ten digits fail
      the grammar, and every field is parsed with [uint64]::TryParse, so
      absurd input is a clean $false result, never an overflow exception.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version
    )
    # Anchors are \A/\z (not ^/$): .NET '$' also matches before a trailing
    # newline, which would let '1.2.3\n' through the grammar.
    if ($Version -notmatch '\A[0-9]{1,10}\.[0-9]{1,10}\.[0-9]{1,10}\z') { return $false }
    $fields = $Version.Split('.')
    $limits = @(255, 255, 65535)
    for ($i = 0; $i -lt 3; $i++) {
        $n = [uint64]0
        # NumberStyles.None: the field is digits only; Integer would also
        # tolerate surrounding whitespace.
        $ok = [uint64]::TryParse($fields[$i], [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
        if (-not $ok -or $n -gt $limits[$i]) { return $false }
    }
    return $true
}

function Resolve-GsPhysicalPath {
    <#
    .SYNOPSIS
      Resolves a path to its physical on-disk form for overlap decisions.
    .DESCRIPTION
      Starts from the lexical normalization (ConvertTo-GsCanonicalLexical)
      and then walks the path component by component: existing components
      are rewritten to their provider FullName (which expands 8.3 short
      names and reports on-disk casing), and junction or directory
      symbolic-link components are replaced by their link target, after
      which the walk restarts on the rewritten path. Components that do
      not exist yet keep their lexical spelling. A reparse cycle is
      reported as an error instead of looping forever. Read-only: this
      function only inspects directory metadata, never file content.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BaseDir
    )
    $lexical = ConvertTo-GsCanonicalLexical -Path $Path -BaseDir $BaseDir
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $expanded = $false
        $components = @($lexical.Split('\') | Where-Object { $_.Length -gt 0 })
        if ($components.Count -eq 0) { return $lexical }
        if ($lexical.StartsWith('\\')) {
            if ($components.Count -lt 2) { return $lexical }
            $built = '\\' + $components[0] + '\' + $components[1]
            $rest = @($components | Select-Object -Skip 2)
        }
        else {
            $built = $components[0]
            $rest = @($components | Select-Object -Skip 1)
        }
        for ($i = 0; $i -lt $rest.Count; $i++) {
            $candidate = $built + '\' + $rest[$i]
            $item = $null
            if (Test-Path -LiteralPath $candidate -PathType Any) {
                $item = Get-Item -LiteralPath $candidate -Force
            }
            if ($null -ne $item -and $item.PSIsContainer -and -not [string]::IsNullOrEmpty($item.LinkType)) {
                $target = @($item.Target)[0]
                if (-not [string]::IsNullOrEmpty($target)) {
                    if (-not [IO.Path]::IsPathRooted($target)) {
                        $target = Join-Path (Split-Path -Parent $item.FullName) $target
                    }
                    $remainder = ''
                    if (($i + 1) -lt $rest.Count) {
                        $remainder = '\' + (@($rest | Select-Object -Skip ($i + 1)) -join '\')
                    }
                    $lexical = ConvertTo-GsCanonicalLexical -Path ($target + $remainder) -BaseDir $BaseDir
                    $expanded = $true
                    break
                }
            }
            if ($null -ne $item) { $built = $item.FullName }
            else { $built = $candidate }
        }
        if (-not $expanded) { return $built }
    }
    throw ("Path could not be resolved within the attempt limit (reparse cycle?): {0}" -f $Path)
}

function Get-GsPathReparseComponent {
    <#
    .SYNOPSIS
      Returns the first reparse-point component of a canonical lexical path
      strictly below a boundary path, or $null when there is none.
    .DESCRIPTION
      Walks the components of -Path below -BelowPath and reports the first
      existing component that is a junction or symbolic link. Used to keep
      write/delete targets (which the build removes recursively) free of
      reparse points below the repository root, so they can never alias
      other content. Read-only metadata inspection.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BelowPath
    )
    $pathParts = @($Path.Split('\') | Where-Object { $_.Length -gt 0 })
    $belowParts = @($BelowPath.Split('\') | Where-Object { $_.Length -gt 0 })
    if ($pathParts.Count -le $belowParts.Count) { return $null }
    for ($i = 0; $i -lt $belowParts.Count; $i++) {
        if (-not $pathParts[$i].Equals($belowParts[$i], [StringComparison]::OrdinalIgnoreCase)) { return $null }
    }
    $prefix = $BelowPath
    for ($i = $belowParts.Count; $i -lt $pathParts.Count; $i++) {
        $candidate = $prefix + '\' + $pathParts[$i]
        if (Test-Path -LiteralPath $candidate -PathType Any) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (-not [string]::IsNullOrEmpty($item.LinkType)) { return $candidate }
        }
        $prefix = $candidate
    }
    return $null
}

function Invoke-GsBuildPreflight {
    <#
    .SYNOPSIS
      Runs every build preflight check and returns a structured result.
    .DESCRIPTION
      All supplied paths are resolved to their physical on-disk form
      (junctions, directory symbolic links and 8.3 short names expanded,
      lexical noise normalized) and then checked:

        - Version is a valid MSI ProductVersion.
        - OutputDirectory, when it exists, is a directory, not a file.
        - The write/delete targets (StageDir, WixBuildDir and, below the
          repository root, OutputDirectory) contain no junction or symlink
          component below the repository root, and StageDir and WixBuildDir
          do not alias each other.
        - No user input path (RuntimeBundleDir, WixDir, ProductDir,
          InstallerDir, ScriptsDir, module directories) overlaps a build
          work directory (StageDir, WixBuildDir); the work directories are
          deleted on every run, so an overlap would destroy inputs. The
          installer and scripts directories are build inputs too (wxs
          source, this script and its helper) and junction-aliasing them
          into a work directory is therefore rejected.
        - OutputDirectory overlaps none of the input paths and none of the
          work directories.

      Returns a pscustomobject with Passed, Violations (array of
      {Code, Message}) and Resolved (ordered dictionary of the physically
      resolved paths). Nothing is created, deleted, executed or signed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WixDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RuntimeBundleDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$WixBuildDir,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)][string]$InstallerDir,
        [Parameter(Mandatory)][string]$ScriptsDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ModuleDirs
    )

    $violations = @()
    $resolved = [ordered]@{}

    if (-not (Test-GsMsiVersionString -Version $Version)) {
        $violations += [pscustomobject]@{
            Code = 'VersionInvalid'
            Message = ("Version '{0}' is not a valid MSI ProductVersion; expected major.minor.build with major 0-255, minor 0-255, build 0-65535, digits only." -f $Version)
        }
    }

    foreach ($entry in @(
        @{ Key = 'Root'; Value = $Root },
        @{ Key = 'WixDir'; Value = $WixDir },
        @{ Key = 'RuntimeBundleDir'; Value = $RuntimeBundleDir },
        @{ Key = 'OutputDirectory'; Value = $OutputDirectory },
        @{ Key = 'StageDir'; Value = $StageDir },
        @{ Key = 'WixBuildDir'; Value = $WixBuildDir },
        @{ Key = 'ProductDir'; Value = $ProductDir },
        @{ Key = 'InstallerDir'; Value = $InstallerDir },
        @{ Key = 'ScriptsDir'; Value = $ScriptsDir }
    )) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) { continue }
        $resolved[$entry.Key] = Resolve-GsPhysicalPath -Path $entry.Value -BaseDir $Root
    }
    $moduleIndex = 0
    foreach ($m in $ModuleDirs) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        $resolved[('Module.{0}' -f $moduleIndex)] = Resolve-GsPhysicalPath -Path $m -BaseDir $Root
        $moduleIndex++
    }

    if ($resolved.Contains('OutputDirectory')) {
        $outPath = $resolved['OutputDirectory']
        if (Test-Path -LiteralPath $outPath -PathType Leaf) {
            $violations += [pscustomobject]@{
                Code = 'OutputNotADirectory'
                Message = ("OutputDirectory '{0}' is an existing file." -f $outPath)
            }
        }
    }

    # Protected paths: everything the build must not delete or overwrite.
    # Work paths: deleted recursively on every build run, so any overlap
    # with a protected path would destroy inputs.
    $protectedKeys = @('RuntimeBundleDir', 'WixDir', 'ProductDir', 'InstallerDir', 'ScriptsDir') +
        @($resolved.Keys | Where-Object { $_ -like 'Module.*' })
    $workKeys = @('StageDir', 'WixBuildDir')

    # The two work directories are deleted recursively at different points
    # of the build; if they alias each other physically, one deletion
    # destroys the other's freshly staged content. Lexically they are
    # always disjoint, so an overlap can only come from aliasing.
    if ($resolved.Contains('StageDir') -and $resolved.Contains('WixBuildDir')) {
        if (Test-GsPathOverlap -A $resolved['StageDir'] -B $resolved['WixBuildDir']) {
            $violations += [pscustomobject]@{
                Code = 'PathOverlap'
                Message = ("StageDir '{0}' overlaps WixBuildDir '{1}'; the build deletes each work directory recursively, so aliasing one into the other would destroy staged content." -f $resolved['StageDir'], $resolved['WixBuildDir'])
            }
        }
    }

    # Write/delete targets must be plain, non-reparse locations below the
    # repository root: a junction or symbolic link anywhere in their path
    # below the root could alias repository content into the recursive
    # deletion. External output directories (not below the root) are not
    # restricted by this rule.
    $rootLexical = ConvertTo-GsCanonicalLexical -Path $Root -BaseDir $Root
    foreach ($wp in @(
        @{ Name = 'StageDir'; Lexical = (ConvertTo-GsCanonicalLexical -Path $StageDir -BaseDir $Root) },
        @{ Name = 'WixBuildDir'; Lexical = (ConvertTo-GsCanonicalLexical -Path $WixBuildDir -BaseDir $Root) },
        @{ Name = 'OutputDirectory'; Lexical = (ConvertTo-GsCanonicalLexical -Path $OutputDirectory -BaseDir $Root) }
    )) {
        if ((Test-GsPathOverlap -A $rootLexical -B $wp.Lexical) -and
            (-not $wp.Lexical.Equals($rootLexical, [StringComparison]::OrdinalIgnoreCase))) {
            $reparse = Get-GsPathReparseComponent -Path $wp.Lexical -BelowPath $rootLexical
            if ($null -ne $reparse) {
                $violations += [pscustomobject]@{
                    Code = 'WritePathReparse'
                    Message = ("{0} '{1}' contains reparse point '{2}' below the repository root '{3}'; the build deletes this path recursively, so junctions or symbolic links inside it are not allowed." -f $wp.Name, $wp.Lexical, $reparse, $rootLexical)
                }
            }
        }
    }

    foreach ($pk in $protectedKeys) {
        if (-not $resolved.Contains($pk)) { continue }
        foreach ($wk in $workKeys) {
            if (Test-GsPathOverlap -A $resolved[$pk] -B $resolved[$wk]) {
                $violations += [pscustomobject]@{
                    Code = 'PathOverlap'
                    Message = ("{0} '{1}' overlaps work directory {2} '{3}'; the work directory is deleted on every run, so inputs placed there would be destroyed." -f $pk, $resolved[$pk], $wk, $resolved[$wk])
                }
            }
        }
    }

    if ($resolved.Contains('OutputDirectory')) {
        $outPath = $resolved['OutputDirectory']
        foreach ($key in @($protectedKeys + $workKeys)) {
            if (-not $resolved.Contains($key)) { continue }
            if (Test-GsPathOverlap -A $outPath -B $resolved[$key]) {
                $violations += [pscustomobject]@{
                    Code = 'PathOverlap'
                    Message = ("OutputDirectory '{0}' overlaps {1} '{2}'." -f $outPath, $key, $resolved[$key])
                }
            }
        }
    }

    for ($i = 0; $i -lt $protectedKeys.Count; $i++) {
        $ki = $protectedKeys[$i]
        if (-not $resolved.Contains($ki)) { continue }
        for ($j = $i + 1; $j -lt $protectedKeys.Count; $j++) {
            $kj = $protectedKeys[$j]
            if (-not $resolved.Contains($kj)) { continue }
            if (Test-GsPathOverlap -A $resolved[$ki] -B $resolved[$kj]) {
                $violations += [pscustomobject]@{
                    Code = 'PathOverlap'
                    Message = ("{0} '{1}' overlaps {2} '{3}'." -f $ki, $resolved[$ki], $kj, $resolved[$kj])
                }
            }
        }
    }

    [pscustomobject]@{
        Passed = ($violations.Count -eq 0)
        Violations = @($violations)
        Resolved = $resolved
    }
}
