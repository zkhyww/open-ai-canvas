[CmdletBinding()]
param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$manifest = [System.IO.File]::ReadAllText((Join-Path $repoRoot "branding\jutian\replacements.json"), $utf8) | ConvertFrom-Json
$brand = [System.IO.File]::ReadAllText((Join-Path $repoRoot "branding\jutian\brand.json"), $utf8) | ConvertFrom-Json
$failures = [System.Collections.Generic.List[string]]::new()

if ([int]$manifest.schemaVersion -ne 2) { $failures.Add("Unsupported brand manifest version") }
if ([string]$brand.productName -cne [string]$manifest.mappings[2].new -or [string]$brand.englishName -cne [string]$manifest.mappings[1].new) { $failures.Add("Brand constants do not match") }

$targets = @($manifest.targets)
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($targetValue in $targets) {
    $target = [string]$targetValue
    if (-not $seen.Add($target)) {
        $failures.Add("Duplicate brand target: $target")
        continue
    }
    if ([string]::IsNullOrWhiteSpace($target) -or [System.IO.Path]::IsPathRooted($target) -or $target.Contains("\") -or $target.Split('/') -contains "..") {
        $failures.Add("Unsafe brand target path: $target")
        continue
    }
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $target))
    $rootPrefix = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $failures.Add("Missing or out-of-repository brand target: $target")
        continue
    }
    $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.UTF8Encoding]::new($false, $true))
    foreach ($mapping in @($manifest.mappings)) {
        if ($text.IndexOf([string]$mapping.old, [System.StringComparison]::Ordinal) -ge 0) {
            $failures.Add("Old brand remains in target: $target")
            break
        }
    }
}

$pluginManifestPath = Join-Path $repoRoot "plugins\yingce\.codex-plugin\plugin.json"
if (Test-Path -LiteralPath $pluginManifestPath -PathType Leaf) {
    $plugin = [System.IO.File]::ReadAllText($pluginManifestPath, $utf8) | ConvertFrom-Json
    if ([string]$plugin.interface.displayName -cne [string]$brand.productName) { $failures.Add("Codex plugin display name is not branded") }
}

$marketplacePath = Join-Path $repoRoot ".agents\plugins\marketplace.json"
if (Test-Path -LiteralPath $marketplacePath -PathType Leaf) {
    $marketplace = [System.IO.File]::ReadAllText($marketplacePath, $utf8) | ConvertFrom-Json
    if ([string]$marketplace.interface.displayName -cne "$($brand.productName) Local") { $failures.Add("Local marketplace display name is not branded") }
}

$readme = [System.IO.File]::ReadAllText((Join-Path $repoRoot "README.md"), $utf8)
if ($readme.IndexOf("https://github.com/ddcat-ai/open-ai-canvas", [System.StringComparison]::Ordinal) -lt 0) { $failures.Add("README is missing the upstream link") }
$notice = [System.IO.File]::ReadAllText((Join-Path $repoRoot "NOTICE"), $utf8)
if ($notice.IndexOf("basketikun/infinite-canvas", [System.StringComparison]::Ordinal) -lt 0) { $failures.Add("NOTICE is missing the original upstream source") }

$secretPatterns = @(
    '(?i)(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{12,}(?![A-Za-z0-9_-])',
    '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b',
    '(?i)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
)
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot "branding\jutian") -File -Recurse) {
    $text = [System.IO.File]::ReadAllText($file.FullName, $utf8)
    foreach ($pattern in $secretPatterns) {
        if ([regex]::IsMatch($text, $pattern)) { $failures.Add("Possible credential in brand directory: $($file.Name)") }
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine($failure) }
    exit 1
}

Write-Output "Jutian brand verified: targets=$($targets.Count)"
