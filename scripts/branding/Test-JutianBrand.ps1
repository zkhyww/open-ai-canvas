[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:failures.Add($Message)
}

function Read-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        return [System.IO.File]::ReadAllText($Path, $encoding)
    } catch {
        throw "不是有效 UTF-8 文件: $DisplayPath"
    }
}

function Convert-ApprovedBrandText {
    param([Parameter(Mandatory = $true)][string]$Text)
    return $Text.Replace("YINGCE STUDIO", "JUTIAN STUDIO").Replace("影策", "巨天")
}

function Expand-RuleTextForFile {
    param(
        [Parameter(Mandatory = $true)][string]$RuleText,
        [Parameter(Mandatory = $true)][string]$FileText,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if ($RuleText.Contains("`r")) {
        throw "品牌多行规则必须使用 LF: $Target"
    }
    if (-not $RuleText.Contains("`n")) {
        return $RuleText
    }
    $withoutCrLf = $FileText.Replace("`r`n", "")
    if ($FileText.Contains("`r`n") -and $withoutCrLf.Contains("`n")) {
        throw "品牌目标包含混合行尾: $Target"
    }
    $lineEnding = if ($FileText.Contains("`r`n")) { "`r`n" } else { "`n" }
    return $RuleText.Replace("`n", $lineEnding)
}

function Get-BrandTextLeaves {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string]) {
        Write-Output ([string]$Value)
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            Write-Output ([string]$property.Name)
            Get-BrandTextLeaves -Value $property.Value
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Write-Output ([string]$key)
            Get-BrandTextLeaves -Value $Value[$key]
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Get-BrandTextLeaves -Value $item
        }
    }
}

function Get-LiteralCount {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle
    )

    if ($Needle.Length -eq 0) {
        throw "品牌规则的 old/new 不能为空"
    }

    $count = 0
    $index = 0
    while ($true) {
        $next = $Text.IndexOf($Needle, $index, [System.StringComparison]::Ordinal)
        if ($next -lt 0) {
            return $count
        }
        $count++
        $index = $next + $Needle.Length
    }
}

function Get-ApprovedBrandTargets {
    return @(
        "web/index.html",
        "web/src/components/layout/workspace-top-bar.tsx",
        "web/src/components/layout/app-top-nav.tsx",
        "web/src/pages/home/index.tsx",
        "web/src/pages/auth/auth-scene.tsx",
        "web/src/pages/assets/index.tsx",
        "web/src/pages/create/index.tsx",
        "web/src/pages/admin/components/admin-shell.tsx",
        "web/src/pages/admin/components/email-settings-panel.tsx",
        "web/src/components/canvas/canvas-local-agent-panel.tsx",
        "web/src/components/canvas/canvas-assistant-panel.tsx",
        "web/src/lib/canvas/canvas-export.ts",
        "web/src/components/canvas/canvas-project-card.tsx",
        "web/src/pages/canvas/index.tsx",
        "backend/internal/service/email.go",
        "canvas-agent/src/config.ts",
        "canvas-agent/src/agents.ts",
        "canvas-agent/README.md",
        "README.md",
        "scripts/install-server.sh"
    )
}

function Resolve-ApprovedBrandTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$ApprovedTargets,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$ApprovedTargetsIgnoreCase
    )

    if ([string]::IsNullOrWhiteSpace($Target) -or [System.IO.Path]::IsPathRooted($Target)) {
        throw "target 必须是批准的仓库内规范相对路径"
    }
    if ($Target.Contains("\") -or $Target.StartsWith("./", [System.StringComparison]::Ordinal) -or $Target.Contains("/./") -or $Target.Contains("//") -or $Target.EndsWith("/", [System.StringComparison]::Ordinal)) {
        throw "target 路径形式不规范"
    }
    foreach ($segment in $Target.Split('/')) {
        if ($segment -eq ".." -or $segment.Length -eq 0) {
            throw "target 路径形式不规范"
        }
    }
    if (-not $ApprovedTargets.Contains($Target)) {
        if ($ApprovedTargetsIgnoreCase.Contains($Target)) {
            throw "target 存在大小写歧义"
        }
        throw "target 不在 Phase 1 批准范围"
    }

    $root = [System.IO.Path]::GetFullPath($RepoRoot)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root ($Target.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    $rootPrefix = $root
    if (-not $rootPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal)) {
        $rootPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "target 越出仓库边界"
    }
    return $candidate
}

function Test-BrandValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    if ([string]$Actual -cne $Expected) {
        Add-Failure "$Name 固定值不匹配"
    }
}

function Test-BrandSchemaNode {
    param(
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Expected,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Actual -or $Actual -isnot [pscustomobject]) {
        Add-Failure "$Path 必须是对象"
        return
    }

    $expectedNames = @($Expected.Keys | ForEach-Object { [string]$_ })
    foreach ($property in $Actual.PSObject.Properties) {
        if ($expectedNames -cnotcontains $property.Name) {
            Add-Failure "$Path 含未知字段: $($property.Name)"
        }
    }

    foreach ($name in $expectedNames) {
        $property = $Actual.PSObject.Properties[$name]
        if ($null -eq $property) {
            Add-Failure "$Path 缺少字段: $name"
            continue
        }
        $expectedValue = $Expected[$name]
        $actualValue = $property.Value
        if ($expectedValue -is [System.Collections.IDictionary]) {
            Test-BrandSchemaNode -Actual $actualValue -Expected $expectedValue -Path "$Path.$name"
        } elseif ($expectedValue -is [int]) {
            if ($actualValue -isnot [int] -or [int]$actualValue -ne [int]$expectedValue) {
                Add-Failure "$Path.$name 类型或固定值不匹配"
            }
        } elseif ($expectedValue -is [string]) {
            if ($actualValue -isnot [string] -or [string]$actualValue -cne [string]$expectedValue) {
                Add-Failure "$Path.$name 类型或固定值不匹配"
            }
        } else {
            Add-Failure "$Path.$name 的批准 schema 类型未定义"
        }
    }
}

function Test-ApprovedBrandSchema {
    param([AllowNull()][object]$Brand)

    $expected = [ordered]@{
        schemaVersion = 1
        productName = "巨天"
        englishName = "Jutian"
        englishNameUpper = "JUTIAN"
        web = [ordered]@{
            title = "巨天"
            metaDescription = "巨天，让一个故事从文字走向银幕。面向 AI 影视与短剧创作的开源工作台。"
            workspaceTitle = "巨天工作台"
            authStudioLabel = "JUTIAN STUDIO"
            homeBrandLabel = "巨天"
            adminSubtitle = "管理后台"
            creationWorkbenchLabel = "巨天 · AI 影视创作工作台"
            assetLibraryLabel = "巨天素材库"
        }
        email = [ordered]@{
            fromName = "巨天"
            registrationSubject = "巨天注册验证码"
            registrationBodyLead = "你正在注册巨天。"
        }
        canvasAgent = [ordered]@{
            displayName = "巨天 Canvas Agent"
            localPromptLead = "你正在帮助用户操作巨天网页画布。"
            onlinePromptLead = "你是巨天网页内置在线画布助手。"
            diagnosticTitle = "巨天 Canvas Agent 诊断日志"
            onlineDiagnosticTitle = "巨天网站 Agent 诊断日志"
        }
        export = [ordered]@{
            defaultCanvasName = "巨天画布"
        }
    }
    Test-BrandSchemaNode -Actual $Brand -Expected $expected -Path "brand"
}

function Get-SelfTestApprovedTargets {
    return @(Get-ApprovedBrandTargets)
}

function Write-SelfTestText {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function New-BrandSelfTestRepo {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [ValidateSet("official", "applied")][string]$State = "applied",
        [ValidateSet("LF", "CRLF")][string]$LineEnding = "LF"
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("jutian-brand-selftest-" + [Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $root "scripts/branding")) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $root "branding/jutian")) | Out-Null
    [System.IO.File]::Copy((Join-Path $SourceRoot "scripts/branding/Apply-JutianBrand.ps1"), (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1"), $true)
    [System.IO.File]::Copy((Join-Path $SourceRoot "scripts/branding/Test-JutianBrand.ps1"), (Join-Path $root "scripts/branding/Test-JutianBrand.ps1"), $true)
    [System.IO.File]::Copy((Join-Path $SourceRoot "branding/jutian/brand.json"), (Join-Path $root "branding/jutian/brand.json"), $true)

    $targets = @(Get-SelfTestApprovedTargets)
    $rules = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $targets.Count; $index++) {
        $target = $targets[$index]
        $brandCount = if ($target -eq "web/src/pages/auth/auth-scene.tsx") { 1 } elseif ($index -eq ($targets.Count - 1)) { 4 } else { 2 }
        $oldBrands = (@("影策") * $brandCount) -join " | "
        $newBrands = (@("巨天") * $brandCount) -join " | "
        if ($target -eq "web/src/pages/auth/auth-scene.tsx") {
            $old = "fixture-$($index + 1)-before`n  影策`nfixture-$($index + 1)-after | $oldBrands"
            $new = "fixture-$($index + 1)-before`n  巨天`nfixture-$($index + 1)-after | $newBrands"
        } else {
            $old = "fixture-$($index + 1): $oldBrands"
            $new = "fixture-$($index + 1): $newBrands"
        }
        $content = if ($State -eq "official") { $old } else { $new }
        if ($LineEnding -eq "CRLF") {
            $content = $content.Replace("`r`n", "`n").Replace("`n", "`r`n")
        }
        if ($target -eq "README.md") {
            $content += "`nhttps://github.com/ddcat-ai/open-ai-canvas"
        }
        Write-SelfTestText -Path (Join-Path $root $target) -Text $content
        $rules.Add([ordered]@{ target = $target; old = $old; new = $new; expectedCount = 1; userVisible = $true })
    }

    Write-SelfTestText -Path (Join-Path $root "LICENSE") -Text "fixture license"
    Write-SelfTestText -Path (Join-Path $root "NOTICE") -Text "https://github.com/basketikun/infinite-canvas"
    Write-SelfTestText -Path (Join-Path $root "canvas-agent/package.json") -Text '{"repository":"https://github.com/ddcat-ai/open-ai-canvas.git"}'
    $manifest = [ordered]@{ schemaVersion = 1; replacements = @($rules) }
    Write-SelfTestText -Path (Join-Path $root "branding/jutian/replacements.json") -Text ($manifest | ConvertTo-Json -Depth 8)
    return $root
}

function Read-SelfTestManifest {
    param([string]$Root)
    return (Get-Content -Raw -Encoding UTF8 (Join-Path $Root "branding/jutian/replacements.json")) | ConvertFrom-Json
}

function Write-SelfTestManifest {
    param([string]$Root, [object]$Manifest)
    Write-SelfTestText -Path (Join-Path $Root "branding/jutian/replacements.json") -Text ($Manifest | ConvertTo-Json -Depth 8)
}

function Get-SelfTestSnapshot {
    param([string]$Root, [string[]]$RelativePaths)
    $snapshot = @{}
    foreach ($relativePath in ($RelativePaths | Select-Object -Unique)) {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $relativePath))
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $snapshot[$fullPath] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fullPath))
        }
    }
    return $snapshot
}

function Test-SelfTestSnapshotEqual {
    param([hashtable]$Before)
    foreach ($entry in $Before.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Key -PathType Leaf)) {
            return $false
        }
        $after = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($entry.Key))
        if ($after -cne [string]$entry.Value) {
            return $false
        }
    }
    return $true
}

function Get-CurrentPowerShellExecutable {
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    if ($null -eq $process.MainModule -or [string]::IsNullOrWhiteSpace($process.MainModule.FileName)) {
        throw "无法解析当前 PowerShell host"
    }
    return $process.MainModule.FileName
}

function Invoke-SelfTestPowerShell {
    param([string]$ScriptPath, [string[]]$Arguments = @())
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $powerShellHost = Get-CurrentPowerShellExecutable
        $output = @(& $powerShellHost -NoProfile -File $ScriptPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
}

function Get-SelfTestUnixModeApi {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { return $null }
    $getMethod = @([System.IO.File].GetMethods() | Where-Object { $_.Name -eq "GetUnixFileMode" -and $_.GetParameters().Count -eq 1 })[0]
    $setMethod = @([System.IO.File].GetMethods() | Where-Object { $_.Name -eq "SetUnixFileMode" -and $_.GetParameters().Count -eq 2 })[0]
    if ($null -eq $getMethod -or $null -eq $setMethod) { return $null }
    return [pscustomobject]@{ Get = $getMethod; Set = $setMethod; ModeType = $getMethod.ReturnType }
}

function Set-SelfTestUnixMode {
    param([object]$Api, [string]$Path, [int]$Mode)
    if ($null -eq $Api) { return }
    $modeValue = [System.Enum]::ToObject($Api.ModeType, $Mode)
    [void]$Api.Set.Invoke($null, [object[]]@($Path, $modeValue))
}

function Get-SelfTestUnixMode {
    param([object]$Api, [string]$Path)
    if ($null -eq $Api) { return $null }
    return [int]$Api.Get.Invoke($null, [object[]]@($Path))
}

function Invoke-BrandSelfTest {
    $sourceRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSCommandPath) "..\.."))
    $selfFailures = [System.Collections.Generic.List[string]]::new()
    $tempRoots = [System.Collections.Generic.List[string]]::new()
    try {
        $productionManifest = (Get-Content -Raw -Encoding UTF8 (Join-Path $sourceRoot "branding/jutian/replacements.json")) | ConvertFrom-Json
        $testScriptText = [System.IO.File]::ReadAllText((Join-Path $sourceRoot "scripts/branding/Test-JutianBrand.ps1"), [System.Text.UTF8Encoding]::new($false, $true))
        $applyScriptText = [System.IO.File]::ReadAllText((Join-Path $sourceRoot "scripts/branding/Apply-JutianBrand.ps1"), [System.Text.UTF8Encoding]::new($false, $true))
        if ($applyScriptText.IndexOf("GetUnixFileMode", [System.StringComparison]::Ordinal) -lt 0 -or $applyScriptText.IndexOf("SetUnixFileMode", [System.StringComparison]::Ordinal) -lt 0) {
            $selfFailures.Add("I3 RED: Apply 尚未保存/恢复 Unix executable mode")
        }
        $windowsOnlyHostNeedle = "power" + "shell.exe"
        if ($testScriptText.IndexOf($windowsOnlyHostNeedle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $selfFailures.Add("I6 RED: SelfTest 子进程仍硬编码 Windows-only host")
        }
        $genericRules = @($productionManifest.replacements | Where-Object { $_.old -ceq "影策" -or $_.old -ceq "YINGCE STUDIO" -or $_.new -ceq "巨天" -or $_.new -ceq "JUTIAN STUDIO" })
        if ($genericRules.Count -gt 0) {
            $selfFailures.Add("I1 RED: replacements.json 仍包含裸品牌通用规则")
        }

        foreach ($case in @(
            @{ Name = "body"; Suffix = " [fixture extra body]" },
            @{ Name = "model-prompt"; Suffix = " model=fixture-model prompt=fixture-prompt" },
            @{ Name = "url"; Suffix = " https://fixture.invalid/changed" }
        )) {
            foreach ($validator in @("Apply", "Test")) {
                $state = if ($validator -eq "Apply") { "official" } else { "applied" }
                $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State $state
                $tempRoots.Add($root)
                $manifest = Read-SelfTestManifest -Root $root
                $rule = @($manifest.replacements)[0]
                $maliciousNew = [string]$rule.new + $case.Suffix
                $rule.new = $maliciousNew
                if ($validator -eq "Test") {
                    $targetPath = Join-Path $root ([string]$rule.target)
                    $targetText = [System.IO.File]::ReadAllText($targetPath, [System.Text.UTF8Encoding]::new($false, $true))
                    [System.IO.File]::WriteAllText($targetPath, $targetText.Replace(([string]$rule.new).Substring(0, ([string]$rule.new).Length - $case.Suffix.Length), $maliciousNew), [System.Text.UTF8Encoding]::new($false))
                }
                Write-SelfTestManifest -Root $root -Manifest $manifest
                $before = Get-SelfTestSnapshot -Root $root -RelativePaths @(Get-SelfTestApprovedTargets)
                $scriptName = if ($validator -eq "Apply") { "Apply-JutianBrand.ps1" } else { "Test-JutianBrand.ps1" }
                $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/$scriptName")
                if ($result.ExitCode -eq 0 -or -not (Test-SelfTestSnapshotEqual -Before $before)) {
                    $selfFailures.Add("I1 RED: $validator 未拒绝 new 夹带 case '$($case.Name)'")
                }
            }
        }

        foreach ($propertyCase in @(
            @{ Name = "upstreamRepository"; Value = "https://fixture.invalid/upstream" },
            @{ Name = "forkRepository"; Value = "https://fixture.invalid/fork" },
            @{ Name = "sourceVersion"; Value = "fixture-version" },
            @{ Name = "originRepository"; Value = "https://fixture.invalid/origin" },
            @{ Name = "repository"; Value = "https://fixture.invalid/repository" },
            @{ Name = "metadata"; Value = [pscustomobject]@{ upstreamRepository = "https://fixture.invalid/nested" } }
        )) {
            $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State applied
            $tempRoots.Add($root)
            $brandPath = Join-Path $root "branding/jutian/brand.json"
            $brandFixture = (Get-Content -Raw -Encoding UTF8 $brandPath) | ConvertFrom-Json
            $brandFixture | Add-Member -NotePropertyName $propertyCase.Name -NotePropertyValue $propertyCase.Value -Force
            Write-SelfTestText -Path $brandPath -Text ($brandFixture | ConvertTo-Json -Depth 8)
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
            if ($result.ExitCode -eq 0) {
                $selfFailures.Add("I1 RED: Test 未拒绝非批准 brand provenance '$($propertyCase.Name)'")
            }
        }

        foreach ($case in @(
            @{ Name = "LICENSE"; Target = "LICENSE"; Actual = "LICENSE" },
            @{ Name = "web/package.json"; Target = "web/package.json"; Actual = "web/package.json" },
            @{ Name = "backslash"; Target = "web\\index.html"; Actual = "web/index.html" },
            @{ Name = "dot-slash"; Target = "./web/index.html"; Actual = "web/index.html" }
        )) {
            $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
            $tempRoots.Add($root)
            $manifest = Read-SelfTestManifest -Root $root
            $actualPath = Join-Path $root $case.Actual
            if (-not (Test-Path -LiteralPath $actualPath -PathType Leaf)) {
                Write-SelfTestText -Path $actualPath -Text "fixture-malicious-old"
            } else {
                [System.IO.File]::AppendAllText($actualPath, "`nfixture-malicious-old", [System.Text.UTF8Encoding]::new($false))
            }
            $rules = @($manifest.replacements)
            $rules += [pscustomobject]@{ target = $case.Target; old = "fixture-malicious-old"; new = "fixture-malicious-new"; expectedCount = 1; userVisible = $true }
            $manifest.replacements = $rules
            Write-SelfTestManifest -Root $root -Manifest $manifest
            $snapshotPaths = @(Get-SelfTestApprovedTargets) + @($case.Actual)
            $before = Get-SelfTestSnapshot -Root $root -RelativePaths $snapshotPaths
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1")
            if ($result.ExitCode -eq 0 -or -not (Test-SelfTestSnapshotEqual -Before $before)) {
                $selfFailures.Add("I2 RED: Apply 未在写入前拒绝 target case '$($case.Name)'")
            }
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
        $tempRoots.Add($root)
        $before = Get-SelfTestSnapshot -Root $root -RelativePaths @(Get-SelfTestApprovedTargets)
        $previousSelfTestEnv = $env:JUTIAN_BRAND_SELF_TEST
        try {
            $env:JUTIAN_BRAND_SELF_TEST = "1"
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1") -Arguments @("-SelfTestFailAfterReplace", "1")
        } finally {
            $env:JUTIAN_BRAND_SELF_TEST = $previousSelfTestEnv
        }
        $leftovers = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -like ".jutian-brand-*" })
        $i3Snapshot = Test-SelfTestSnapshotEqual -Before $before
        if ($result.ExitCode -eq 0 -or -not $i3Snapshot -or $leftovers.Count -ne 0) {
            $selfFailures.Add("I3 RED: exit=$($result.ExitCode); restored=$i3Snapshot; leftovers=$($leftovers.Count)")
        }

        $unixModeApi = Get-SelfTestUnixModeApi
        if ($null -ne $unixModeApi) {
            $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
            $tempRoots.Add($root)
            $installPath = Join-Path $root "scripts/install-server.sh"
            Set-SelfTestUnixMode -Api $unixModeApi -Path $installPath -Mode 493
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1")
            $modeAfterApply = Get-SelfTestUnixMode -Api $unixModeApi -Path $installPath
            if ($result.ExitCode -ne 0 -or $modeAfterApply -ne 493) {
                $selfFailures.Add("I3 RED: Unix executable mode 未在正常 Apply 后保持 100755")
            }

            $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
            $tempRoots.Add($root)
            $installPath = Join-Path $root "scripts/install-server.sh"
            Set-SelfTestUnixMode -Api $unixModeApi -Path $installPath -Mode 493
            $previousSelfTestEnv = $env:JUTIAN_BRAND_SELF_TEST
            try {
                $env:JUTIAN_BRAND_SELF_TEST = "1"
                $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1") -Arguments @("-SelfTestFailAfterReplace", "20")
            } finally {
                $env:JUTIAN_BRAND_SELF_TEST = $previousSelfTestEnv
            }
            $modeAfterRollback = Get-SelfTestUnixMode -Api $unixModeApi -Path $installPath
            if ($result.ExitCode -eq 0 -or $modeAfterRollback -ne 493) {
                $selfFailures.Add("I3 RED: Unix executable mode 未在 rollback 后保持 100755")
            }
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
        $tempRoots.Add($root)
        $previousSelfTestEnv = $env:JUTIAN_BRAND_SELF_TEST
        try {
            $env:JUTIAN_BRAND_SELF_TEST = "1"
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1") -Arguments @("-SelfTestFailAfterReplace", "1", "-SelfTestFailRollbackCopyAt", "1")
        } finally {
            $env:JUTIAN_BRAND_SELF_TEST = $previousSelfTestEnv
        }
        $rollbackBackups = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -like ".jutian-brand-*.bak" })
        $rootLeaked = $result.Output.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($result.ExitCode -eq 0 -or $rollbackBackups.Count -lt 1 -or $rootLeaked) {
            $selfFailures.Add("I2 RED: rollback copy 失败后 backup 未安全保留或错误输出泄露绝对路径")
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
        $tempRoots.Add($root)
        $previousSelfTestEnv = $env:JUTIAN_BRAND_SELF_TEST
        try {
            $env:JUTIAN_BRAND_SELF_TEST = "1"
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1") -Arguments @("-SelfTestFailAfterReplace", "1", "-SelfTestFailRollbackProbeAt", "1")
        } finally {
            $env:JUTIAN_BRAND_SELF_TEST = $previousSelfTestEnv
        }
        $rollbackProbeBackups = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -like ".jutian-brand-*.bak" })
        $rollbackProbeRootLeaked = $result.Output.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($result.ExitCode -eq 0 -or $rollbackProbeBackups.Count -lt 1 -or $rollbackProbeRootLeaked) {
            $selfFailures.Add("I1 RED: rollback probe 异常后已提交 backup 未保留或错误输出泄露绝对路径")
        }

        foreach ($case in @(
            @{ Name = "env"; Content = "API_TOKEN=fixture-secret-value"; Secret = "fixture-secret-value" },
            @{ Name = "userinfo"; Content = "postgres://fixture-user:fixture-password@example.com/db"; Secret = "fixture-password" },
            @{ Name = "jwt"; Content = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.fixtureSignature0123456789"; Secret = "fixtureSignature0123456789" },
            @{ Name = "unix-path"; Content = "/opt/jutian/runtime/file"; Secret = "/opt/jutian/runtime/file" },
            @{ Name = "unix-generic-usr"; Content = "/usr/local/jutian/file"; Secret = "/usr/local/jutian/file" },
            @{ Name = "unix-generic-private"; Content = "/private/jutian"; Secret = "/private/jutian" },
            @{ Name = "unix-generic-volumes"; Content = "/Volumes/JutianBrand"; Secret = "/Volumes/JutianBrand" },
            @{ Name = "unix-unicode-root"; Content = "/用户/巨天/密钥.json"; Secret = "/用户/巨天/密钥.json" },
            @{ Name = "unix-unicode-at"; Content = "/tmp/巨天@品牌/file"; Secret = "/tmp/巨天@品牌/file" },
            @{ Name = "unix-unicode-volumes"; Content = "/Volumes/巨天"; Secret = "/Volumes/巨天" },
            @{ Name = "sqlite"; Content = "cache/session.sqlite3"; Secret = "cache/session.sqlite3" },
            @{ Name = "log"; Content = "logs/session.log"; Secret = "logs/session.log" },
            @{ Name = "task-result"; Content = "runtime/task-result/result.json"; Secret = "runtime/task-result/result.json" }
        )) {
            $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State applied
            $tempRoots.Add($root)
            Write-SelfTestText -Path (Join-Path $root "branding/jutian/probe.json") -Text $case.Content
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
            if ($result.ExitCode -eq 0) {
                $selfFailures.Add("I4 RED: Test 未拒绝敏感/运行数据 case '$($case.Name)'")
            }
            if ($result.Output.Contains($case.Secret)) {
                $selfFailures.Add("I4 RED: Test 输出泄露 case '$($case.Name)' 的命中值")
            }
        }

        foreach ($lineEnding in @("LF", "CRLF")) {
            $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official -LineEnding $lineEnding
            $tempRoots.Add($root)
            $beforeBytes = @{}
            foreach ($target in Get-SelfTestApprovedTargets) {
                $beforeBytes[$target] = [System.IO.File]::ReadAllBytes((Join-Path $root $target))
            }
            $applyResult = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1")
            $testResult = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
            $lineEndingPreserved = $true
            foreach ($target in Get-SelfTestApprovedTargets) {
                $afterText = [System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $root $target)))
                if ($lineEnding -eq "CRLF" -and $target -eq "web/src/pages/auth/auth-scene.tsx" -and $afterText.Contains("`n") -and -not $afterText.Contains("`r`n")) { $lineEndingPreserved = $false }
                if ($lineEnding -eq "LF" -and $afterText.Contains("`r`n")) { $lineEndingPreserved = $false }
            }
            if ($applyResult.ExitCode -ne 0 -or $testResult.ExitCode -ne 0 -or -not $lineEndingPreserved) {
                $selfFailures.Add("I5 RED: $lineEnding fixture Apply/Test 或行尾保留失败")
            }
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State official
        $tempRoots.Add($root)
        $previousSelfTestEnv = $env:JUTIAN_BRAND_SELF_TEST
        try {
            $env:JUTIAN_BRAND_SELF_TEST = "1"
            $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Apply-JutianBrand.ps1") -Arguments @("-SelfTestFailReplaceWithPathAt", "1")
        } finally {
            $env:JUTIAN_BRAND_SELF_TEST = $previousSelfTestEnv
        }
        if ($result.ExitCode -eq 0 -or $result.Output.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $selfFailures.Add("I4 RED: 底层 I/O 故障未转换为无绝对路径稳定消息")
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State applied
        $tempRoots.Add($root)
        Write-SelfTestText -Path (Join-Path $root "branding/jutian/probe.json") -Text '{"description":"Jutian brand fixture; relative paths only", "url":"https://example.com/usr/local/not-a-local-path", "css":"url(/logo.svg)", "route":"<Link to=\"/\">"}'
        $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
        if ($result.ExitCode -ne 0) {
            $selfFailures.Add("I4 RED: benign 品牌包 fixture 被误报")
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State applied
        $tempRoots.Add($root)
        $assetDir = Join-Path $root "branding/jutian/assets"
        [System.IO.Directory]::CreateDirectory($assetDir) | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $assetDir "logo.png"), [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0xFF, 0x00))
        $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
        if ($result.ExitCode -ne 0) {
            $selfFailures.Add("M1 RED: 允许扩展的非 UTF-8 二进制资产仍被当文本拒绝")
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State applied
        $tempRoots.Add($root)
        $assetDir = Join-Path $root "branding/jutian/assets"
        [System.IO.Directory]::CreateDirectory($assetDir) | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $assetDir "logo.bin"), [byte[]](0x00, 0xFF, 0x10, 0x20))
        $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
        if ($result.ExitCode -eq 0) {
            $selfFailures.Add("M1 RED: 未知二进制扩展未 fail-closed")
        }

        $root = New-BrandSelfTestRepo -SourceRoot $sourceRoot -State applied
        $tempRoots.Add($root)
        $assetDir = Join-Path $root "branding/jutian/assets"
        [System.IO.Directory]::CreateDirectory($assetDir) | Out-Null
        $secretBytes = [System.Text.Encoding]::ASCII.GetBytes("sk-ABCDEFGHIJKLMNOPQRSTUVWX")
        $bytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF) + $secretBytes
        [System.IO.File]::WriteAllBytes((Join-Path $assetDir "logo.png"), $bytes)
        $result = Invoke-SelfTestPowerShell -ScriptPath (Join-Path $root "scripts/branding/Test-JutianBrand.ps1")
        $m1CredentialCategory = $result.Output.IndexOf("凭据", [System.StringComparison]::Ordinal) -ge 0
        $m1SecretLeaked = $result.Output.Contains("sk-ABCDEFGHIJKLMNOPQRSTUVWX")
        if ($result.ExitCode -eq 0 -or -not $m1CredentialCategory -or $m1SecretLeaked) {
            $selfFailures.Add("M1 RED: exit=$($result.ExitCode); credentialCategory=$m1CredentialCategory; leaked=$m1SecretLeaked")
        }
    } finally {
        foreach ($root in $tempRoots) {
            if (Test-Path -LiteralPath $root) {
                [System.IO.Directory]::Delete($root, $true)
            }
        }
    }

    if ($selfFailures.Count -gt 0) {
        throw ("Jutian brand self-test failed:`n - " + ($selfFailures -join "`n - "))
    }
    Write-Output "Jutian brand self-test passed"
}

if ($SelfTest) {
    Invoke-BrandSelfTest
    exit 0
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
$brandPath = Join-Path $repoRoot "branding\jutian\brand.json"
$manifestPath = Join-Path $repoRoot "branding\jutian\replacements.json"

foreach ($requiredPath in @(
    @{ Path = $brandPath; Display = "branding/jutian/brand.json" },
    @{ Path = $manifestPath; Display = "branding/jutian/replacements.json" }
)) {
    if (-not (Test-Path -LiteralPath $requiredPath.Path -PathType Leaf)) {
        throw "缺少品牌文件: $($requiredPath.Display)"
    }
}

try {
    $brand = (Read-Utf8Text -Path $brandPath -DisplayPath "branding/jutian/brand.json") | ConvertFrom-Json
} catch {
    throw "品牌 JSON 无法解析: branding/jutian/brand.json"
}
try {
    $manifest = (Read-Utf8Text -Path $manifestPath -DisplayPath "branding/jutian/replacements.json") | ConvertFrom-Json
} catch {
    throw "品牌规则 JSON 无法解析: branding/jutian/replacements.json"
}

Test-ApprovedBrandSchema -Brand $brand

if ($null -eq $manifest.PSObject.Properties["schemaVersion"] -or [int]$manifest.schemaVersion -ne 1) {
    Add-Failure "replacements.json schemaVersion 必须为 1"
}
if ($null -eq $manifest.PSObject.Properties["replacements"]) {
    throw "品牌规则缺少 replacements"
}

$rules = @($manifest.replacements)
if ($rules.Count -eq 0) {
    throw "品牌规则为空"
}

$approvedTargetList = @(Get-ApprovedBrandTargets)
$approvedTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$approvedTargetsIgnoreCase = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($approvedTarget in $approvedTargetList) {
    [void]$approvedTargets.Add($approvedTarget)
    [void]$approvedTargetsIgnoreCase.Add($approvedTarget)
}

$seenRuleKeys = @{}
$distinctTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$fileTexts = @{}
$targetNames = @{}
$visiblePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$totalLiterals = 0
$validRuleCount = 0

foreach ($rule in $rules) {
    $missingField = $false
    foreach ($name in @("target", "old", "new", "expectedCount", "userVisible")) {
        if ($null -eq $rule.PSObject.Properties[$name]) {
            Add-Failure "品牌规则缺少字段: $name"
            $missingField = $true
        }
    }
    if ($missingField) {
        continue
    }

    $target = [string]$rule.target
    $old = [string]$rule.old
    $new = [string]$rule.new
    if ([string]::IsNullOrEmpty($old) -or [string]::IsNullOrEmpty($new) -or $old -ceq $new) {
        Add-Failure "品牌规则 old/new 无效: $target"
        continue
    }
    if ($old -ceq "影策" -or $old -ceq "YINGCE STUDIO" -or $new -ceq "巨天" -or $new -ceq "JUTIAN STUDIO") {
        Add-Failure "品牌规则必须使用位置特定的完整展示片段: $target"
        continue
    }

    try {
        $expectedNumber = [double]$rule.expectedCount
        $expected = [int]$rule.expectedCount
    } catch {
        Add-Failure "品牌规则 expectedCount 无效: $target"
        continue
    }
    if ($expected -lt 1 -or $expectedNumber -ne $expected) {
        Add-Failure "品牌规则 expectedCount 必须是正整数: $target"
        continue
    }
    if ($rule.userVisible -isnot [bool] -or $rule.userVisible -ne $true) {
        Add-Failure "Phase 1 品牌规则必须是 userVisible=true: $target"
        continue
    }

    try {
        $fullPath = Resolve-ApprovedBrandTarget -RepoRoot $repoRoot -Target $target -ApprovedTargets $approvedTargets -ApprovedTargetsIgnoreCase $approvedTargetsIgnoreCase
    } catch {
        Add-Failure "品牌 target 非法或超出冻结范围: $target"
        continue
    }
    [void]$distinctTargets.Add($target)

    $ruleKey = $target + "`n" + $old
    if ($seenRuleKeys.ContainsKey($ruleKey)) {
        Add-Failure "品牌规则重复 target/old: $target"
        continue
    }
    $seenRuleKeys[$ruleKey] = $true

    $expectedNew = Convert-ApprovedBrandText -Text $old
    if ($expectedNew -cne $new) {
        Add-Failure "品牌规则 new 必须严格等于批准品牌映射后的 old: $target"
        continue
    }
    $oldBrandCount = (Get-LiteralCount -Text $old -Needle "影策") + (Get-LiteralCount -Text $old -Needle "YINGCE STUDIO")
    $newBrandCount = (Get-LiteralCount -Text $new -Needle "巨天") + (Get-LiteralCount -Text $new -Needle "JUTIAN STUDIO")
    if ($oldBrandCount -lt 1 -or $oldBrandCount -ne $newBrandCount) {
        Add-Failure "品牌规则 old/new 品牌字面量不对称: $target"
        continue
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Add-Failure "品牌目标文件不存在: $target"
        continue
    }
    if (-not $fileTexts.ContainsKey($fullPath)) {
        try {
            $fileTexts[$fullPath] = Read-Utf8Text -Path $fullPath -DisplayPath $target
            $targetNames[$fullPath] = $target
        } catch {
            Add-Failure $_.Exception.Message
            continue
        }
    }

    $text = [string]$fileTexts[$fullPath]
    try {
        $effectiveOld = Expand-RuleTextForFile -RuleText $old -FileText $text -Target $target
        $effectiveNew = Expand-RuleTextForFile -RuleText $new -FileText $text -Target $target
    } catch {
        Add-Failure $_.Exception.Message
        continue
    }
    $oldCount = Get-LiteralCount -Text $text -Needle $effectiveOld
    $newCount = Get-LiteralCount -Text $text -Needle $effectiveNew
    if ($oldCount -ne 0 -or $newCount -ne $expected) {
        Add-Failure "品牌目标未完整应用: $target (old=$oldCount, new=$newCount, expected=$expected)"
    }

    [void]$visiblePaths.Add($fullPath)
    $totalLiterals += $newBrandCount * $expected
    $validRuleCount++
}

if ($distinctTargets.Count -ne $approvedTargetList.Count) {
    Add-Failure "品牌规则必须精确覆盖批准的 20 个目标文件"
}
foreach ($approvedTarget in $approvedTargetList) {
    if (-not $distinctTargets.Contains($approvedTarget)) {
        Add-Failure "品牌规则缺少批准目标: $approvedTarget"
    }
}
if ($totalLiterals -ne 45) {
    Add-Failure "品牌规则必须精确覆盖 45 个品牌字面量"
}

foreach ($fullPath in $visiblePaths) {
    if (-not $fileTexts.ContainsKey($fullPath)) {
        continue
    }
    $text = [string]$fileTexts[$fullPath]
    if ((Get-LiteralCount -Text $text -Needle "影策") -ne 0) {
        Add-Failure "用户可见品牌目标仍包含旧中文品牌: $($targetNames[$fullPath])"
    }
    if ([System.Text.RegularExpressions.Regex]::IsMatch($text, "(?i)yingce")) {
        Add-Failure "用户可见品牌目标仍包含旧英文品牌: $($targetNames[$fullPath])"
    }
}

$licensePath = Join-Path $repoRoot "LICENSE"
$noticePath = Join-Path $repoRoot "NOTICE"
$readmePath = Join-Path $repoRoot "README.md"
$agentPackagePath = Join-Path $repoRoot "canvas-agent\package.json"
foreach ($sourceFile in @(
    @{ Path = $licensePath; Display = "LICENSE" },
    @{ Path = $noticePath; Display = "NOTICE" },
    @{ Path = $readmePath; Display = "README.md" },
    @{ Path = $agentPackagePath; Display = "canvas-agent/package.json" }
)) {
    if (-not (Test-Path -LiteralPath $sourceFile.Path -PathType Leaf)) {
        Add-Failure "来源文件缺失: $($sourceFile.Display)"
    }
}

if (Test-Path -LiteralPath $licensePath -PathType Leaf) {
    if ((Read-Utf8Text -Path $licensePath -DisplayPath "LICENSE").Length -eq 0) {
        Add-Failure "LICENSE 为空"
    }
}
if (Test-Path -LiteralPath $noticePath -PathType Leaf) {
    $noticeText = Read-Utf8Text -Path $noticePath -DisplayPath "NOTICE"
    if ($noticeText.IndexOf("https://github.com/basketikun/infinite-canvas", [System.StringComparison]::Ordinal) -lt 0) {
        Add-Failure "NOTICE 缺少既有上游来源"
    }
}
if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
    $readmeText = Read-Utf8Text -Path $readmePath -DisplayPath "README.md"
    if ($readmeText.IndexOf("https://github.com/ddcat-ai/open-ai-canvas", [System.StringComparison]::Ordinal) -lt 0) {
        Add-Failure "README.md 缺少官方仓库来源"
    }
}
if (Test-Path -LiteralPath $agentPackagePath -PathType Leaf) {
    $agentPackageText = Read-Utf8Text -Path $agentPackagePath -DisplayPath "canvas-agent/package.json"
    if ($agentPackageText.IndexOf("https://github.com/ddcat-ai/open-ai-canvas.git", [System.StringComparison]::Ordinal) -lt 0) {
        Add-Failure "Canvas Agent package 缺少官方仓库来源"
    }
}

$brandDir = Join-Path $repoRoot "branding\jutian"
$credentialPatterns = @(
    '(?i)(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{12,}(?![A-Za-z0-9_-])',
    '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b',
    '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b',
    '(?i)\bAKIA[0-9A-Z]{16}\b',
    '(?i)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}',
    '(?i)"(?:api[_-]?key|token|cookie|password|secret)"\s*:\s*"[^"\r\n]+"',
    '(?im)^\s*(?:export\s+)?[A-Z_][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|COOKIE|CREDENTIALS?)\s*=\s*\S+',
    '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@',
    '(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'
)
$absolutePathPatterns = @(
    '(?i)\b[A-Z]:[\\/]',
    '(?i)(?<!\\)\\\\[A-Za-z0-9][A-Za-z0-9.-]{0,62}\\[A-Za-z0-9_$.-]+(?:\\[^\s"<>|]*)?',
    '(?i)(?<![:\p{L}\p{N}_<])/(?!/)[^\s"''`<>{}\[\](),;]+'
)
$runtimeDataPatterns = @(
    '(?i)(?:^|[/\\])\.local(?:[/\\]|$)',
    '(?i)(?:^|[/\\\s"=])[^/\\\s"<>]+\.(?:db|sqlite|sqlite3|log)(?=$|[/\\\s",;])',
    '(?i)(?:^|[/\\])sessions?(?:[/\\]|$)',
    '(?i)open_ai_canvas\.db',
    '(?i)runtime-state',
    '(?i)backend-data',
    '(?i)generation-receipt',
    '(?i)paid-generation',
    '(?i)task-results?'
)
$allowedAssetExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @(".png", ".jpg", ".jpeg", ".webp", ".svg", ".ico")) {
    [void]$allowedAssetExtensions.Add($extension)
}

foreach ($file in Get-ChildItem -LiteralPath $brandDir -Recurse -File) {
    $relative = "branding/jutian/" + $file.FullName.Substring($brandDir.Length).TrimStart([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)).Replace("\", "/")
    $isAsset = $relative.StartsWith("branding/jutian/assets/", [System.StringComparison]::OrdinalIgnoreCase)
    if ($isAsset) {
        if (-not $allowedAssetExtensions.Contains($file.Extension)) {
            Add-Failure "品牌资产扩展不受支持: $relative"
            continue
        }
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            # 二进制资产不做 UTF-8 解码；Latin-1 仅用于保留 ASCII 字节以执行有限的凭据/路径扫描。
            $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        } catch {
            Add-Failure "品牌资产无法读取: $relative"
            continue
        }
    } else {
        try {
            $text = Read-Utf8Text -Path $file.FullName -DisplayPath $relative
        } catch {
            Add-Failure $_.Exception.Message
            continue
        }
    }

    # JSON 先解析再扫描字符串/字段叶子，避免 JSON 转义把合法 Web-root 片段伪装成本机路径；任意新增 JSON 字段仍会进入扫描。
    $pathSourceText = $text
    if (-not $isAsset -and $file.Extension -ieq ".json") {
        try {
            if ($relative -ceq "branding/jutian/brand.json") {
                $pathObject = $brand
            } elseif ($relative -ceq "branding/jutian/replacements.json") {
                $pathObject = $manifest
            } else {
                $pathObject = $text | ConvertFrom-Json
            }
            $pathSourceText = (@(Get-BrandTextLeaves -Value $pathObject) -join "`n")
        } catch {
            Add-Failure "品牌包 JSON 无法解析: $relative"
            continue
        }
    }

    # 先移除合法 http(s) URL 与已批准 CSS Web-root logo 片段；凭据/运行数据扫描仍使用原始文本。
    $pathScanText = [System.Text.RegularExpressions.Regex]::Replace($pathSourceText, '(?i)\bhttps?://[^\s"''<>]+', '')
    $pathScanText = [System.Text.RegularExpressions.Regex]::Replace($pathScanText, '(?i)\burl\(\s*/logo\.svg\s*\)', '')

    foreach ($pattern in $credentialPatterns) {
        if ([System.Text.RegularExpressions.Regex]::IsMatch($text, $pattern)) {
            Add-Failure "品牌包疑似包含凭据格式: $relative"
            break
        }
    }
    foreach ($pattern in $absolutePathPatterns) {
        if ([System.Text.RegularExpressions.Regex]::IsMatch($pathScanText, $pattern)) {
            Add-Failure "品牌包包含绝对本机路径: $relative"
            break
        }
    }
    foreach ($pattern in $runtimeDataPatterns) {
        if ([System.Text.RegularExpressions.Regex]::IsMatch($text, $pattern)) {
            Add-Failure "品牌包包含运行数据标识: $relative"
            break
        }
    }
}

if ($failures.Count -gt 0) {
    throw ("Jutian brand verification failed:`n - " + ($failures -join "`n - "))
}

Write-Output "Jutian brand verification passed: rules=$validRuleCount; literals=$totalLiterals; files=$($fileTexts.Count)"
