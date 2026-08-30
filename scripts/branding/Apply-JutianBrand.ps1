[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Utf8State {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Bytes = $bytes; Text = $text; HasBom = $hasBom }
}

function ConvertTo-Utf8Bytes {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][bool]$HasBom
    )

    $body = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (-not $HasBom) { return [byte[]]$body }
    return [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $body)
}

function Test-BytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Resolve-BrandTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Target) -or [System.IO.Path]::IsPathRooted($Target) -or $Target.Contains("\") -or $Target.Split('/') -contains "..") {
        throw "Unsafe brand target path: $Target"
    }
    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Target))
    if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Brand target escapes repository: $Target"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Brand target does not exist: $Target"
    }
    return $fullPath
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$manifest = [System.IO.File]::ReadAllText((Join-Path $repoRoot "branding\jutian\replacements.json"), $utf8) | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 2) { throw "Unsupported brand manifest version" }

$mappings = @($manifest.mappings)
$targets = @($manifest.targets)
if ($mappings.Count -lt 1 -or $targets.Count -lt 1) { throw "Brand manifest is empty" }

$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$prepared = [System.Collections.Generic.List[object]]::new()
$runId = [Guid]::NewGuid().ToString("N")
$literalCount = 0

try {
    foreach ($targetValue in $targets) {
        $target = [string]$targetValue
        if (-not $seen.Add($target)) { throw "Duplicate brand target: $target" }
        $fullPath = Resolve-BrandTarget -RepoRoot $repoRoot -Target $target
        $state = Read-Utf8State -Path $fullPath
        $next = [string]$state.Text
        foreach ($mapping in $mappings) {
            $old = [string]$mapping.old
            $new = [string]$mapping.new
            if ([string]::IsNullOrEmpty($old) -or [string]::IsNullOrEmpty($new) -or $old -ceq $new) {
                throw "Invalid brand mapping"
            }
            $count = ([regex]::Matches($next, [regex]::Escape($old))).Count
            $literalCount += $count
            $next = $next.Replace($old, $new)
        }
        if ($next -ceq $state.Text) { continue }

        $tempPath = "$fullPath.jutian-$runId.tmp"
        $backupPath = "$fullPath.jutian-$runId.bak"
        [System.IO.File]::WriteAllBytes($tempPath, (ConvertTo-Utf8Bytes -Text $next -HasBom ([bool]$state.HasBom)))
        $prepared.Add([pscustomobject]@{
            Target = $target
            FullPath = $fullPath
            TempPath = $tempPath
            BackupPath = $backupPath
            OriginalBytes = [byte[]]$state.Bytes
            Committed = $false
        })
    }

    foreach ($item in $prepared) {
        $liveBytes = [System.IO.File]::ReadAllBytes($item.FullPath)
        if (-not (Test-BytesEqual -Left $liveBytes -Right ([byte[]]$item.OriginalBytes))) {
            throw "Brand target changed before commit: $($item.Target)"
        }
        [System.IO.File]::Replace($item.TempPath, $item.FullPath, $item.BackupPath)
        $item.Committed = $true
    }
} catch {
    for ($index = $prepared.Count - 1; $index -ge 0; $index--) {
        $item = $prepared[$index]
        if ($item.Committed -and (Test-Path -LiteralPath $item.BackupPath -PathType Leaf)) {
            [System.IO.File]::Copy($item.BackupPath, $item.FullPath, $true)
        }
    }
    throw
} finally {
    foreach ($item in $prepared) {
        if (Test-Path -LiteralPath $item.TempPath -PathType Leaf) { Remove-Item -LiteralPath $item.TempPath -Force }
        if (Test-Path -LiteralPath $item.BackupPath -PathType Leaf) { Remove-Item -LiteralPath $item.BackupPath -Force }
    }
}

Write-Output "Jutian brand applied: files=$($prepared.Count); literals=$literalCount"
