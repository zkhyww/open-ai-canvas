[CmdletBinding()]
param(
    [Parameter(DontShow = $true)][ValidateRange(0, 1000)][int]$SelfTestFailAfterReplace = 0,
    [Parameter(DontShow = $true)][ValidateRange(0, 1000)][int]$SelfTestFailRollbackCopyAt = 0,
    [Parameter(DontShow = $true)][ValidateRange(0, 1000)][int]$SelfTestFailRollbackProbeAt = 0,
    [Parameter(DontShow = $true)][ValidateRange(0, 1000)][int]$SelfTestFailReplaceWithPathAt = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

trap {
    $safeMessage = [string]$_.Exception.Message
    if (-not ($safeMessage.StartsWith("品牌", [System.StringComparison]::Ordinal) -or $safeMessage.StartsWith("Jutian brand", [System.StringComparison]::Ordinal))) {
        $safeMessage = "品牌应用失败：未分类安全错误"
    }
    [Console]::Error.WriteLine($safeMessage)
    exit 1
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

function Test-Utf8BomBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
}

function Read-Utf8FileState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $emitBom = Test-Utf8BomBytes -Bytes $bytes
        $offset = if ($emitBom) { 3 } else { 0 }
        $length = $bytes.Length - $offset
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString($bytes, $offset, $length)
        return [pscustomobject]@{ Text = $text; Bytes = $bytes; EmitBom = $emitBom }
    } catch {
        throw "不是有效 UTF-8 文件: $DisplayPath"
    }
}

function ConvertTo-Utf8Bytes {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][bool]$EmitBom
    )

    $body = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (-not $EmitBom) {
        return [byte[]]$body
    }
    return [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $body)
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Resolve-ApprovedBrandTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$ApprovedTargets,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$ApprovedTargetsIgnoreCase
    )

    if ([string]::IsNullOrWhiteSpace($Target) -or [System.IO.Path]::IsPathRooted($Target)) {
        throw "品牌 target 必须是批准的仓库内规范相对路径"
    }
    if ($Target.Contains("\") -or $Target.StartsWith("./", [System.StringComparison]::Ordinal) -or $Target.Contains("/./") -or $Target.Contains("//") -or $Target.EndsWith("/", [System.StringComparison]::Ordinal)) {
        throw "品牌 target 路径形式不规范: $Target"
    }
    foreach ($segment in $Target.Split('/')) {
        if ($segment -eq ".." -or $segment.Length -eq 0) {
            throw "品牌 target 路径形式不规范: $Target"
        }
    }
    if (-not $ApprovedTargets.Contains($Target)) {
        if ($ApprovedTargetsIgnoreCase.Contains($Target)) {
            throw "品牌 target 存在大小写歧义: $Target"
        }
        throw "品牌 target 不在 Phase 1 批准范围: $Target"
    }

    $root = [System.IO.Path]::GetFullPath($RepoRoot)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root ($Target.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    $rootPrefix = $root
    if (-not $rootPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal)) {
        $rootPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "品牌 target 越出仓库边界: $Target"
    }
    return $candidate
}

function Write-PreparedTempFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    try {
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $written = [System.IO.File]::ReadAllBytes($Path)
        if (-not (Test-ByteArrayEqual -Left $written -Right $Bytes)) {
            throw "临时文件字节校验失败"
        }
    } catch {
        throw "准备品牌临时文件失败: $DisplayPath"
    }
}

function Get-UnixFileModeMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { return $null }
    $method = @([System.IO.File].GetMethods() | Where-Object { $_.Name -eq "GetUnixFileMode" -and $_.GetParameters().Count -eq 1 })[0]
    if ($null -eq $method) { return $null }
    return $method.Invoke($null, [object[]]@($Path))
}

function Set-UnixFileModeMetadata {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()][object]$Mode)
    if ($null -eq $Mode -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { return }
    $method = @([System.IO.File].GetMethods() | Where-Object { $_.Name -eq "SetUnixFileMode" -and $_.GetParameters().Count -eq 2 })[0]
    if ($null -eq $method) { return }
    [void]$method.Invoke($null, [object[]]@($Path, $Mode))
}

function Remove-OwnedFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [System.IO.File]::Delete($Path)
    }
}

if (($SelfTestFailAfterReplace -gt 0 -or $SelfTestFailRollbackCopyAt -gt 0 -or $SelfTestFailRollbackProbeAt -gt 0 -or $SelfTestFailReplaceWithPathAt -gt 0) -and $env:JUTIAN_BRAND_SELF_TEST -ne "1") {
    throw "品牌故障注入参数仅允许脚本自测使用"
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
$manifestPath = Join-Path $repoRoot "branding\jutian\replacements.json"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "缺少品牌规则: branding/jutian/replacements.json"
}

$manifestState = Read-Utf8FileState -Path $manifestPath -DisplayPath "branding/jutian/replacements.json"
try {
    $manifest = $manifestState.Text | ConvertFrom-Json
} catch {
    throw "品牌规则 JSON 无法解析: branding/jutian/replacements.json"
}

if ($null -eq $manifest.PSObject.Properties["schemaVersion"] -or [int]$manifest.schemaVersion -ne 1) {
    throw "品牌规则 schemaVersion 必须为 1"
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

# 先只校验 manifest 与冻结范围，任何目标文件读取/写入都在这一关之后。
$distinctTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$seenRuleKeys = @{}
$validatedRuleMetadata = [System.Collections.Generic.List[object]]::new()
$totalOldBrandLiterals = 0
$totalNewBrandLiterals = 0
foreach ($rule in $rules) {
    foreach ($name in @("target", "old", "new", "expectedCount", "userVisible")) {
        if ($null -eq $rule.PSObject.Properties[$name]) {
            throw "品牌规则缺少字段: $name"
        }
    }

    $target = [string]$rule.target
    $old = [string]$rule.old
    $new = [string]$rule.new
    if ([string]::IsNullOrEmpty($old) -or [string]::IsNullOrEmpty($new) -or $old -ceq $new) {
        throw "品牌规则 old/new 无效: $target"
    }
    if ($old -ceq "影策" -or $old -ceq "YINGCE STUDIO" -or $new -ceq "巨天" -or $new -ceq "JUTIAN STUDIO") {
        throw "品牌规则必须使用位置特定的完整展示片段: $target"
    }

    $expectedNumber = [double]$rule.expectedCount
    $expected = [int]$rule.expectedCount
    if ($expected -lt 1 -or $expectedNumber -ne $expected) {
        throw "品牌规则 expectedCount 必须是正整数: $target"
    }
    if ($rule.userVisible -isnot [bool] -or $rule.userVisible -ne $true) {
        throw "Phase 1 品牌规则必须是 userVisible=true: $target"
    }

    [void](Resolve-ApprovedBrandTarget -RepoRoot $repoRoot -Target $target -ApprovedTargets $approvedTargets -ApprovedTargetsIgnoreCase $approvedTargetsIgnoreCase)
    [void]$distinctTargets.Add($target)

    $ruleKey = $target + "`n" + $old
    if ($seenRuleKeys.ContainsKey($ruleKey)) {
        throw "品牌规则重复 target/old: $target"
    }
    $seenRuleKeys[$ruleKey] = $true

    $expectedNew = Convert-ApprovedBrandText -Text $old
    if ($expectedNew -cne $new) {
        throw "品牌规则 new 必须严格等于批准品牌映射后的 old: $target"
    }
    $oldBrandCount = (Get-LiteralCount -Text $old -Needle "影策") + (Get-LiteralCount -Text $old -Needle "YINGCE STUDIO")
    $newBrandCount = (Get-LiteralCount -Text $new -Needle "巨天") + (Get-LiteralCount -Text $new -Needle "JUTIAN STUDIO")
    if ($oldBrandCount -lt 1 -or $oldBrandCount -ne $newBrandCount) {
        throw "品牌规则 old/new 品牌字面量不对称: $target"
    }
    $totalOldBrandLiterals += $oldBrandCount * $expected
    $totalNewBrandLiterals += $newBrandCount * $expected
    $validatedRuleMetadata.Add([pscustomobject]@{ Target = $target; Old = $old; New = $new; Expected = $expected })
}

if ($distinctTargets.Count -ne $approvedTargetList.Count) {
    throw "品牌规则必须精确覆盖批准的 20 个目标文件"
}
foreach ($approvedTarget in $approvedTargetList) {
    if (-not $distinctTargets.Contains($approvedTarget)) {
        throw "品牌规则缺少批准目标: $approvedTarget"
    }
}
if ($totalOldBrandLiterals -ne 42 -or $totalNewBrandLiterals -ne 42) {
    throw "品牌规则必须精确覆盖 42 个旧/新品牌字面量"
}

$fileStates = @{}
$targetOrder = [System.Collections.Generic.List[string]]::new()
$targetNames = @{}
$validatedRules = [System.Collections.Generic.List[object]]::new()
foreach ($ruleMetadata in $validatedRuleMetadata) {
    $fullPath = Resolve-ApprovedBrandTarget -RepoRoot $repoRoot -Target $ruleMetadata.Target -ApprovedTargets $approvedTargets -ApprovedTargetsIgnoreCase $approvedTargetsIgnoreCase
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "品牌目标文件不存在: $($ruleMetadata.Target)"
    }
    if (-not $fileStates.ContainsKey($fullPath)) {
        $fileStates[$fullPath] = Read-Utf8FileState -Path $fullPath -DisplayPath $ruleMetadata.Target
        $targetNames[$fullPath] = $ruleMetadata.Target
        $targetOrder.Add($fullPath)
    }

    $text = [string]$fileStates[$fullPath].Text
    $effectiveOld = Expand-RuleTextForFile -RuleText $ruleMetadata.Old -FileText $text -Target $ruleMetadata.Target
    $effectiveNew = Expand-RuleTextForFile -RuleText $ruleMetadata.New -FileText $text -Target $ruleMetadata.Target
    $oldCount = Get-LiteralCount -Text $text -Needle $effectiveOld
    $newCount = Get-LiteralCount -Text $text -Needle $effectiveNew
    if ($oldCount -eq $ruleMetadata.Expected -and $newCount -eq 0) {
        $state = "official"
    } elseif ($oldCount -eq 0 -and $newCount -eq $ruleMetadata.Expected) {
        $state = "applied"
    } else {
        throw "品牌规则状态漂移: $($ruleMetadata.Target) (old=$oldCount, new=$newCount, expected=$($ruleMetadata.Expected))"
    }
    $validatedRules.Add([pscustomobject]@{
        Target = $ruleMetadata.Target
        FullPath = $fullPath
        Old = $effectiveOld
        New = $effectiveNew
        Expected = $ruleMetadata.Expected
        State = $state
    })
}

$states = @($validatedRules | ForEach-Object { $_.State } | Select-Object -Unique)
if ($states.Count -ne 1) {
    throw "品牌规则处于混合状态；必须是完整官方态或完整巨天态"
}
if ($states[0] -eq "applied") {
    Write-Output "Jutian brand no-op: rules=$($validatedRules.Count); literals=$totalNewBrandLiterals; files=$($targetOrder.Count)"
    exit 0
}

$updatedTexts = @{}
foreach ($fullPath in $targetOrder) {
    $updatedTexts[$fullPath] = [string]$fileStates[$fullPath].Text
}
foreach ($rule in $validatedRules) {
    $updatedTexts[$rule.FullPath] = ([string]$updatedTexts[$rule.FullPath]).Replace($rule.Old, $rule.New)
}
foreach ($rule in $validatedRules) {
    $text = [string]$updatedTexts[$rule.FullPath]
    $oldCount = Get-LiteralCount -Text $text -Needle $rule.Old
    $newCount = Get-LiteralCount -Text $text -Needle $rule.New
    if ($oldCount -ne 0 -or $newCount -ne $rule.Expected) {
        throw "品牌应用后校验失败: $($rule.Target) (old=$oldCount, new=$newCount, expected=$($rule.Expected))"
    }
}

$runId = [Guid]::NewGuid().ToString("N")
$prepared = [System.Collections.Generic.List[object]]::new()
$preservedBackups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
try {
    $index = 0
    foreach ($fullPath in $targetOrder) {
        $beforeState = $fileStates[$fullPath]
        $afterText = [string]$updatedTexts[$fullPath]
        if ([string]$beforeState.Text -ceq $afterText) {
            continue
        }
        $index++
        $directory = Split-Path -Parent $fullPath
        $tempPath = Join-Path $directory (".jutian-brand-$runId-$index.tmp")
        $backupPath = Join-Path $directory (".jutian-brand-$runId-$index.bak")
        $expectedBytes = ConvertTo-Utf8Bytes -Text $afterText -EmitBom ([bool]$beforeState.EmitBom)
        $originalUnixMode = Get-UnixFileModeMetadata -Path $fullPath
        Write-PreparedTempFile -Path $tempPath -Bytes $expectedBytes -DisplayPath ([string]$targetNames[$fullPath])
        Set-UnixFileModeMetadata -Path $tempPath -Mode $originalUnixMode
        $prepared.Add([pscustomobject]@{
            Target = [string]$targetNames[$fullPath]
            FullPath = $fullPath
            TempPath = $tempPath
            BackupPath = $backupPath
            OriginalBytes = [byte[]]$beforeState.Bytes
            ExpectedBytes = [byte[]]$expectedBytes
            OriginalUnixMode = $originalUnixMode
            Committed = $false
            RollbackVerified = $false
        })
    }

    # 所有临时文件都落盘且验证完成后，再确认源文件没有在预备期间被外部修改。
    foreach ($item in $prepared) {
        $liveBytes = [System.IO.File]::ReadAllBytes($item.FullPath)
        if (-not (Test-ByteArrayEqual -Left $liveBytes -Right $item.OriginalBytes)) {
            throw "品牌目标在提交前发生外部变化: $($item.Target)"
        }
    }

    $replaceCount = 0
    try {
        foreach ($item in $prepared) {
            $liveBytes = [System.IO.File]::ReadAllBytes($item.FullPath)
            if (-not (Test-ByteArrayEqual -Left $liveBytes -Right $item.OriginalBytes)) {
                throw "品牌目标在提交期间发生外部变化: $($item.Target)"
            }
            $nextReplaceCount = $replaceCount + 1
            try {
                if ($SelfTestFailReplaceWithPathAt -gt 0 -and $nextReplaceCount -eq $SelfTestFailReplaceWithPathAt) {
                    throw [System.IO.IOException]::new("fixture I/O path: $($item.FullPath)")
                }
                [System.IO.File]::Replace($item.TempPath, $item.FullPath, $item.BackupPath)
                # File.Replace 一旦成功，先记录 committed；之后 mode 恢复/校验再失败也必须保留该 backup。
                $item.Committed = $true
                Set-UnixFileModeMetadata -Path $item.FullPath -Mode $item.OriginalUnixMode
            } catch {
                throw "品牌原子替换失败: $($item.Target)"
            }
            $replaceCount++
            $committedBytes = [System.IO.File]::ReadAllBytes($item.FullPath)
            if (-not (Test-ByteArrayEqual -Left $committedBytes -Right $item.ExpectedBytes)) {
                throw "品牌原子替换后字节校验失败: $($item.Target)"
            }
            if ($SelfTestFailAfterReplace -gt 0 -and $replaceCount -eq $SelfTestFailAfterReplace) {
                throw "Jutian brand self-test injected commit failure after replace $replaceCount"
            }
        }

        foreach ($item in $prepared) {
            $committedBytes = [System.IO.File]::ReadAllBytes($item.FullPath)
            if (-not (Test-ByteArrayEqual -Left $committedBytes -Right $item.ExpectedBytes)) {
                throw "品牌提交后最终字节校验失败: $($item.Target)"
            }
        }
    } catch {
        $commitError = "品牌提交阶段失败"
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        $rollbackCopyCount = 0
        $rollbackProbeCount = 0
        for ($rollbackIndex = $prepared.Count - 1; $rollbackIndex -ge 0; $rollbackIndex--) {
            $item = $prepared[$rollbackIndex]
            if (-not [bool]$item.Committed) {
                continue
            }

            # committed backup 默认属于唯一恢复材料；只有完整探测、恢复与验证全部成功后才转为可删除。
            [void]$preservedBackups.Add($item.BackupPath)
            try {
                $rollbackProbeCount++
                if ($SelfTestFailRollbackProbeAt -gt 0 -and $rollbackProbeCount -eq $SelfTestFailRollbackProbeAt) {
                    throw [System.IO.IOException]::new("fixture rollback probe path: $($item.BackupPath)")
                }
                if (-not (Test-Path -LiteralPath $item.BackupPath -PathType Leaf)) {
                    $rollbackErrors.Add("已提交目标缺少恢复备份: $($item.Target)")
                    continue
                }

                # 备份由同目录 File.Replace 生成；回滚按逆序覆盖原目标并验证字节和 Unix mode。
                $rollbackCopyCount++
                if ($SelfTestFailRollbackCopyAt -gt 0 -and $rollbackCopyCount -eq $SelfTestFailRollbackCopyAt) {
                    throw [System.IO.IOException]::new("fixture rollback path: $($item.FullPath)")
                }
                [System.IO.File]::Copy($item.BackupPath, $item.FullPath, $true)
                Set-UnixFileModeMetadata -Path $item.FullPath -Mode $item.OriginalUnixMode
                $restoredBytes = [System.IO.File]::ReadAllBytes($item.FullPath)
                if (-not (Test-ByteArrayEqual -Left $restoredBytes -Right $item.OriginalBytes)) {
                    throw "恢复后字节不一致"
                }
                if ($null -ne $item.OriginalUnixMode) {
                    $restoredUnixMode = Get-UnixFileModeMetadata -Path $item.FullPath
                    if ($null -eq $restoredUnixMode -or -not $restoredUnixMode.Equals($item.OriginalUnixMode)) {
                        throw "恢复后 Unix mode 不一致"
                    }
                }

                $item.RollbackVerified = $true
                [void]$preservedBackups.Remove($item.BackupPath)
            } catch {
                $rollbackErrors.Add("回滚失败且已保留恢复备份: $($item.Target)")
            }
        }

        foreach ($item in $prepared) {
            try { Remove-OwnedFile -Path $item.TempPath } catch { $rollbackErrors.Add("安全临时文件清理失败: $($item.Target)") }
            if (-not $preservedBackups.Contains($item.BackupPath)) {
                try { Remove-OwnedFile -Path $item.BackupPath } catch { $rollbackErrors.Add("安全备份清理失败: $($item.Target)") }
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw ("品牌提交失败且恢复材料已按安全类别处理: $commitError; " + ($rollbackErrors -join "; "))
        }
        throw $commitError
    }

    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $prepared) {
        try { Remove-OwnedFile -Path $item.TempPath } catch { $cleanupErrors.Add("临时文件清理失败: $($item.Target)") }
        try { Remove-OwnedFile -Path $item.BackupPath } catch { $cleanupErrors.Add("备份文件清理失败: $($item.Target)") }
    }
    if ($cleanupErrors.Count -gt 0) {
        throw ("品牌已应用，但本次临时文件清理失败: " + ($cleanupErrors -join "; "))
    }
} catch {
    # 预备阶段失败时，只清理由本次 runId 记录的文件；产品文件尚未提交。
    foreach ($item in $prepared) {
        try { Remove-OwnedFile -Path $item.TempPath } catch {}
        $backupStateUnknown = [bool]$item.Committed -and -not [bool]$item.RollbackVerified
        if (-not $backupStateUnknown -and -not $preservedBackups.Contains($item.BackupPath)) {
            try { Remove-OwnedFile -Path $item.BackupPath } catch {}
        }
    }
    throw
}

Write-Output "Jutian brand applied: rules=$($validatedRules.Count); literals=$totalNewBrandLiterals; files=$($prepared.Count)"
