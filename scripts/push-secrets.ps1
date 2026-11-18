# =====================================================================
# 把签名信息一键写入 GitHub 仓库 Secrets
# 依赖: libsodium.dll（与本脚本同目录）
# 数据来源: ios-signing-helper.ps1 生成的 signing-info.json
# =====================================================================

param(
    [string]$Repo,
    [string]$Token,
    [string]$InfoFile,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------- 加载 libsodium ----------
$libDir = $PSScriptRoot
$dllPath = Join-Path $libDir 'libsodium.dll'
if (-not (Test-Path -LiteralPath $dllPath)) {
    Write-Host "找不到 libsodium.dll，请确认它和本脚本在同一目录: $libDir" -ForegroundColor Red
    exit 1
}
$env:PATH = "$libDir;$env:PATH"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SodiumForGitHub {
    [DllImport("libsodium.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int sodium_init();
    [DllImport("libsodium.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern uint crypto_box_sealbytes();
    [DllImport("libsodium.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int crypto_box_seal(byte[] c, byte[] m, ulong mlen, byte[] pk);
}
"@ -ErrorAction Stop

$init = [SodiumForGitHub]::sodium_init()
if ($init -lt 0) { Write-Host 'libsodium 初始化失败' -ForegroundColor Red; exit 1 }

function Seal-ForGitHub {
    param([byte[]]$PublicKey, [string]$PlainText)
    $msg = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $sealed = New-Object byte[] ($msg.Length + 48)
    $rc = [SodiumForGitHub]::crypto_box_seal($sealed, $msg, [uint64]$msg.Length, $PublicKey)
    if ($rc -ne 0) { throw "crypto_box_seal 失败 (code=$rc)" }
    return [Convert]::ToBase64String($sealed)
}

# ---------- 读取签名信息 ----------
if (-not $InfoFile) {
    $default = Join-Path $env:USERPROFILE 'Desktop\ios-signing-output\signing-info.json'
    if (Test-Path -LiteralPath $default) { $InfoFile = $default }
}

if (-not $InfoFile -or -not (Test-Path -LiteralPath $InfoFile)) {
    $InfoFile = Read-Host '请输入 signing-info.json 路径（可直接拖入）'
    $InfoFile = $InfoFile.Trim('"').Trim("'")
}
if (-not (Test-Path -LiteralPath $InfoFile)) {
    Write-Host "找不到信息文件: $InfoFile" -ForegroundColor Red
    exit 1
}

$info = Get-Content -LiteralPath $InfoFile -Raw -Encoding UTF8 | ConvertFrom-Json
$secretsObj = $info.secrets
$pairs = @()
foreach ($p in $secretsObj.PSObject.Properties) {
    $pairs += [pscustomobject]@{ Name = $p.Name; Value = [string]$p.Value }
}

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '  GitHub Secrets 自动写入' -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ("  信息文件 : " + $InfoFile)
Write-Host ("  项目     : " + $info.profile.name + "  (App ID: " + $info.profile.appId + ")")
Write-Host ("  证书匹配 : " + $(if ($info.check.certMatched) { '✓ 通过' } else { '✗ 不匹配！' })) -ForegroundColor $(if ($info.check.certMatched) { 'Green' } else { 'Red' })
Write-Host ''
Write-Host '  将写入以下 Secrets:'
foreach ($p in $pairs) {
    $preview = if ($p.Value.Length -gt 40) { '<' + $p.Value.Length + ' 字符>' } else { $p.Value }
    Write-Host ("    - {0} = {1}" -f $p.Name, $preview) -ForegroundColor Gray
}

if (-not $info.check.certMatched) {
    Write-Host ''
    Write-Host '  证书与描述文件不匹配，写入也会在构建时失败。已中止。' -ForegroundColor Red
    exit 1
}

if (-not $Repo) {
    $Repo = Read-Host '请输入仓库（owner/repo，默认 rao69/ios-build）'
    if (-not $Repo) { $Repo = 'rao69/ios-build' }
}
$Repo = $Repo.Trim()

if (-not $Token) {
    $tokenFile = Join-Path $libDir '.github-token'
    if (Test-Path -LiteralPath $tokenFile) {
        $Token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
        Write-Host ("  已读取本地保存的 Token: " + $tokenFile) -ForegroundColor Gray
    } else {
        $Token = Read-Host '请粘贴 GitHub Token（ghp_ 开头）'
        $save = Read-Host '是否保存该 Token 到本地，下次免输入？(y/n)'
        if ($save -eq 'y') {
            [System.IO.File]::WriteAllText($tokenFile, $Token.Trim(), (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("  已保存到: " + $tokenFile) -ForegroundColor Gray
        }
    }
}
$Token = $Token.Trim()

if ($DryRun) {
    Write-Host ''
    Write-Host '  [DryRun] 不做实际写入。' -ForegroundColor Yellow
    exit 0
}

$headers = @{
    Authorization          = "Bearer $Token"
    'User-Agent'           = 'ios-signing-pusher'
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# ---------- 获取仓库公钥 ----------
Write-Host ''
Write-Host '  正在连接 GitHub...' -ForegroundColor Gray
try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 30
    Write-Host ("  已认证为: " + $me.login) -ForegroundColor Green
} catch {
    Write-Host ("  Token 无效或网络不通: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

try {
    $pkResp = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/secrets/public-key" -Headers $headers -TimeoutSec 30
} catch {
    Write-Host ("  读取仓库公钥失败（仓库是否存在？Token 是否有 repo 权限？）: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$pubKey = [Convert]::FromBase64String($pkResp.key)
$keyId  = $pkResp.key_id
Write-Host ("  仓库公钥 key_id: " + $keyId) -ForegroundColor Gray
Write-Host ''

# ---------- 逐个写入 ----------
$ok = 0
$fail = 0
foreach ($p in $pairs) {
    try {
        $enc = Seal-ForGitHub -PublicKey $pubKey -PlainText $p.Value
        $body = @{ encrypted_value = $enc; key_id = $keyId } | ConvertTo-Json -Compress
        $uri = "https://api.github.com/repos/$Repo/actions/secrets/$($p.Name)"
        $null = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 60
        Write-Host ("  ✓ {0}" -f $p.Name) -ForegroundColor Green
        $ok++
    } catch {
        Write-Host ("  ✗ {0}  =>  {1}" -f $p.Name, $_.Exception.Message) -ForegroundColor Red
        if ($_.ErrorDetails) { Write-Host ("      " + $_.ErrorDetails.Message) -ForegroundColor DarkRed }
        $fail++
    }
}

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ("  完成: 成功 {0} 个, 失败 {1} 个" -f $ok, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ("  仓库: https://github.com/$Repo/settings/secrets/actions") -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
