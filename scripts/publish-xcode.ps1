# =====================================================================
# 发布 Xcode 工程到 GitHub（打包 → 上传 Release）
#
# 为什么不用 git push：
#   Unity 导出的 Xcode 工程动辄 800MB+，单文件 libiPhone-lib.a 就有 300MB，
#   超过 GitHub 仓库 100MB/文件的硬限制。Release asset 支持 2GB/文件，
#   且不占用仓库体积。
#
# 用法：
#   .\publish-xcode.ps1 -ProjectPath "F:\UnityProject\TYDGYProject\Release\ET"
#   .\publish-xcode.ps1 -ProjectPath "..." -ProjectName "TYDGY"
# =====================================================================

param(
    [string]$ProjectPath,
    [string]$ProjectName,
    [string]$Repo = 'rao69/ios-build',
    [string]$Token,
    [switch]$NoUpload,
    [switch]$KeepZip
)

$ErrorActionPreference = 'Stop'
$toolsDir = $PSScriptRoot

function Write-Step($text) {
    Write-Host ''
    Write-Host ('  >> ' + $text) -ForegroundColor Cyan
}

# ---------- 定位 7z / curl ----------
$sevenZip = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe',
    'D:\Program Files\7-Zip\7z.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $sevenZip) {
    Write-Host '  找不到 7-Zip（7z.exe）。请先安装 7-Zip 再运行。' -ForegroundColor Red
    exit 1
}

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $curl)) {
    Write-Host '  找不到系统自带 curl.exe（Windows 10 以上应自带）。' -ForegroundColor Red
    exit 1
}

# ---------- 读取参数 ----------
Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '  发布 Xcode 工程到 GitHub' -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan

if (-not $ProjectPath) { $ProjectPath = Read-Host '请输入 Xcode 工程目录（可拖入窗口）' }
$ProjectPath = $ProjectPath.Trim('"').Trim("'").TrimEnd('\')

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    Write-Host ("  路径不存在: " + $ProjectPath) -ForegroundColor Red
    exit 1
}

$item = Get-Item -LiteralPath $ProjectPath
if (-not $item.PSIsContainer) {
    Write-Host '  请提供工程「目录」，不是单个文件。' -ForegroundColor Red
    exit 1
}

if (-not $ProjectName) { $ProjectName = $item.Name }
if ($ProjectName -notmatch '^[A-Za-z0-9_-]+$') {
    Write-Host ("  项目名只能包含字母、数字、下划线、中划线，当前是: " + $ProjectName) -ForegroundColor Red
    exit 1
}

# ---------- 校验工程完整性 ----------
Write-Step '检查工程结构'
$hasProj = @(Get-ChildItem -LiteralPath $ProjectPath -Filter '*.xcodeproj' -Directory -ErrorAction SilentlyContinue).Count -gt 0
$hasWs   = @(Get-ChildItem -LiteralPath $ProjectPath -Filter '*.xcworkspace' -Directory -ErrorAction SilentlyContinue).Count -gt 0
$hasPod  = Test-Path -LiteralPath (Join-Path $ProjectPath 'Podfile')

if (-not $hasProj -and -not $hasWs) {
    Write-Host '  这个目录里没有 .xcodeproj 或 .xcworkspace，不是 Unity 导出的 iOS 工程目录。' -ForegroundColor Red
    Write-Host ('  目录: ' + $ProjectPath) -ForegroundColor Gray
    exit 1
}
Write-Host ('  工程文件: ' + $(if ($hasWs) { 'xcworkspace' } elseif ($hasProj) { 'xcodeproj' } else { '无' })) -ForegroundColor Green
Write-Host ('  Podfile: ' + $(if ($hasPod) { '有（CI 会自动 pod install）' } else { '无' })) -ForegroundColor Gray

$files = Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Force -ErrorAction SilentlyContinue
$totalMB = ($files | Measure-Object Length -Sum).Sum / 1MB
Write-Host ('  文件数: ' + $files.Count + '    原始体积: ' + [math]::Round($totalMB, 1) + ' MB') -ForegroundColor Gray

# ---------- 压缩 ----------
Write-Step '打包中（工程大的话要几分钟）'
$stageDir = Join-Path $env:TEMP 'ios-build-publish'
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
$zipPath = Join-Path $stageDir ($ProjectName + '.zip')
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$sw = [Diagnostics.Stopwatch]::StartNew()
& $sevenZip a -tzip "$zipPath" "$ProjectPath\*" -mx=5 -r `
    -x'!.git' -x'!DerivedData' -x'!build' -x'!.DS_Store' -x'!*.xcuserstate' `
    -bso0 -bsp0 2>&1 | Out-Null
$sw.Stop()

if (-not (Test-Path -LiteralPath $zipPath)) {
    Write-Host '  打包失败。' -ForegroundColor Red
    exit 1
}
$zipMB = (Get-Item -LiteralPath $zipPath).Length / 1MB
Write-Host ('  压缩完成: ' + [math]::Round($zipMB, 1) + ' MB（' + [math]::Round($sw.Elapsed.TotalSeconds, 0) + ' 秒）' +
           '  压缩率 ' + [math]::Round(($zipMB / $totalMB) * 100, 0) + '%') -ForegroundColor Green
Write-Host ('  临时文件: ' + $zipPath) -ForegroundColor Gray

if ($zipMB -gt 2000) {
    Write-Host '  压缩包超过 2GB，GitHub Release 单文件上限，无法上传。' -ForegroundColor Red
    exit 1
}

if ($NoUpload) {
    Write-Host ''
    Write-Host '  已指定 -NoUpload，只打包不上传。' -ForegroundColor Yellow
    exit 0
}

# ---------- Token ----------
if (-not $Token) {
    $tokenFile = Join-Path $toolsDir '.github-token'
    if (Test-Path -LiteralPath $tokenFile) {
        $Token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
        Write-Host ('  已读取本地保存的 Token: ' + $tokenFile) -ForegroundColor Gray
    } else {
        $Token = Read-Host '请粘贴 GitHub Token（ghp_ 开头）'
    }
}
$Token = $Token.Trim()

$headers = @{
    Authorization          = "Bearer $Token"
    'User-Agent'           = 'ios-xcode-publisher'
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

Write-Step '连接 GitHub'
try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 30
    Write-Host ('  已认证为: ' + $me.login) -ForegroundColor Green
} catch {
    Write-Host ('  Token 无效或网络不通: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$tag = "$ProjectName-latest"
$assetName = "$ProjectName.zip"

# ---------- 清理旧版本 ----------
Write-Step ('清理旧版本 Release (' + $tag + ')')
try {
    $old = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $headers -TimeoutSec 30
    $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/$($old.id)" -Method Delete -Headers $headers -TimeoutSec 30
    Write-Host ('  已删除旧 release: ' + $old.id) -ForegroundColor Gray
} catch {
    Write-Host '  没有旧版本，跳过' -ForegroundColor Gray
}
try {
    $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/git/refs/tags/$tag" -Method Delete -Headers $headers -TimeoutSec 30
    Write-Host '  已删除旧 tag' -ForegroundColor Gray
} catch { }

# ---------- 创建 Release ----------
Write-Step '创建新 Release'
$jsonBody = @{
    tag_name         = $tag
    target_commitish = 'main'
    name             = "$ProjectName - latest bundle"
    body             = "由 publish-xcode.ps1 自动发布`n`n- 项目: $ProjectName`n- 原始体积: $([math]::Round($totalMB,1)) MB`n- 压缩后: $([math]::Round($zipMB,1)) MB`n- 发布时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    draft            = $false
    prerelease       = $false
} | ConvertTo-Json

# PowerShell 5.1 的 Invoke-RestMethod 用 -Body <string> 时会按系统编码发送，
# 中文会变成问号。必须自己转成 UTF-8 字节再传。
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases" -Method Post -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
    Write-Host ('  Release 创建成功: ' + $release.tag_name) -ForegroundColor Green
} catch {
    Write-Host ('  创建 Release 失败: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host ('  ' + $_.ErrorDetails.Message) -ForegroundColor DarkRed }
    exit 1
}

# ---------- 上传 asset ----------
Write-Step ('上传工程包（' + [math]::Round($zipMB,1) + ' MB，视网速可能要几分钟）')
$uploadUrl = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets?name=$assetName"
$sw2 = [Diagnostics.Stopwatch]::StartNew()

$out = & $curl -sS --location --max-time 3600 -X POST `
    -T "$zipPath" `
    -H "Authorization: Bearer $Token" `
    -H "Content-Type: application/zip" `
    -H "Accept: application/vnd.github+json" `
    -H "User-Agent: ios-xcode-publisher" `
    $uploadUrl 2>&1
$sw2.Stop()

$outText = ($out | Out-String)
$json = $null
try { $json = $outText | ConvertFrom-Json } catch { }

if ($json -and $json.browser_download_url) {
    Write-Host ('  上传成功（' + [math]::Round($sw2.Elapsed.TotalSeconds,0) + ' 秒）') -ForegroundColor Green
    Write-Host ('  下载地址: ' + $json.browser_download_url) -ForegroundColor Gray
} else {
    Write-Host '  上传失败，返回内容如下：' -ForegroundColor Red
    Write-Host $outText -ForegroundColor DarkRed
    exit 1
}

if (-not $KeepZip) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }

# ---------- 完成 ----------
Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '  发布完成' -ForegroundColor Green
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  去 GitHub 触发构建：' -ForegroundColor White
Write-Host ("    https://github.com/$Repo/actions/workflows/build-ios.yml") -ForegroundColor Cyan
Write-Host ''
Write-Host '  点 Run workflow 时填：' -ForegroundColor White
Write-Host ("    project        = " + $ProjectName) -ForegroundColor Yellow
Write-Host '    export_method  = app-store' -ForegroundColor Yellow
Write-Host '    upload_to_testflight = 勾选' -ForegroundColor Yellow
Write-Host ''
