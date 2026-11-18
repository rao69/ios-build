# =====================================================================
# iOS 签名信息提取工具（零依赖，纯 PowerShell）
# 输入: .p12 证书 + .mobileprovision 描述文件
# 输出: 证书/描述文件全量信息、匹配校验、推荐 export method、
#       可直接填入 GitHub Secrets 的全部值
# =====================================================================

param(
    [string]$P12Path,
    [string]$P12Password,
    [string]$ProfilePath,
    [string]$BundleId,
    [string]$OutDir,
    [switch]$Copy
)

$ErrorActionPreference = 'Stop'

# ---------- plist 递归解析 ----------
function ConvertFrom-PlistNode {
    param($node)
    if ($null -eq $node) { return $null }
    $name = $node.LocalName
    switch ($name) {
        'dict' {
            $h = [ordered]@{}
            $kids = @($node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
            for ($i = 0; $i -lt $kids.Count - 1; $i += 2) {
                $k = $kids[$i].InnerText
                $h[$k] = ConvertFrom-PlistNode $kids[$i + 1]
            }
            return $h
        }
        'array' {
            $arr = New-Object System.Collections.ArrayList
            foreach ($c in $node.ChildNodes) {
                if ($c.NodeType -eq 'Element') { [void]$arr.Add((ConvertFrom-PlistNode $c)) }
            }
            return ,$arr.ToArray()
        }
        'string'  { return $node.InnerText }
        'integer' { return [int64]$node.InnerText }
        'real'    { return [double]$node.InnerText }
        'true'    { return $true }
        'false'   { return $false }
        'date'    { return $node.InnerText }
        'data'    { return $node.InnerText }
        default   { return $node.InnerText }
    }
}

function Format-DateInfo {
    param([string]$DateStr)
    if (-not $DateStr) { return '未知' }
    try {
        $dt = [DateTime]::Parse($DateStr)
        $days = [int]($dt - (Get-Date)).TotalDays
        $state = if ($days -lt 0) { '已过期' } elseif ($days -lt 30) { "警告：仅剩 $days 天" } else { "剩余 $days 天" }
        return ("{0:yyyy-MM-dd}  ({1})" -f $dt, $state)
    } catch { return $DateStr }
}

function Resolve-CertType {
    param([string]$Subject)
    if ($Subject -match 'Apple Development')            { return 'Apple Development（开发证书）' }
    if ($Subject -match 'Apple Distribution')           { return 'Apple Distribution（分发证书）' }
    if ($Subject -match 'iPhone Distribution')          { return 'iPhone Distribution（旧版分发证书）' }
    if ($Subject -match 'iPhone Developer')             { return 'iPhone Developer（旧版开发证书）' }
    if ($Subject -match 'Apple Push Services')          { return 'Apple Push Services（推送证书）' }
    if ($Subject -match 'Developer ID')                 { return 'Developer ID（Mac 分发证书）' }
    return '未知类型'
}

# ---------- 交互输入 ----------
if (-not $P12Path) { $P12Path = Read-Host '请输入 .p12 证书路径' }
$P12Path = $P12Path.Trim('"').Trim("'")
if (-not (Test-Path -LiteralPath $P12Path)) { Write-Host "找不到 p12: $P12Path" -ForegroundColor Red; exit 1 }

if (-not $P12Password) { $P12Password = Read-Host '请输入 p12 密码' }

if (-not $ProfilePath) { $ProfilePath = Read-Host '请输入 .mobileprovision 路径' }
$ProfilePath = $ProfilePath.Trim('"').Trim("'")
if (-not (Test-Path -LiteralPath $ProfilePath)) { Write-Host "找不到描述文件: $ProfilePath" -ForegroundColor Red; exit 1 }

if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'Desktop\ios-signing-output' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------- 解析 p12 ----------
Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '  证书 (.p12)' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan

try {
    $certChain = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certChain.Import($P12Path, $P12Password, 'DefaultKeySet')
} catch {
    Write-Host "p12 打开失败：密码错误或文件损坏 -> $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$leaf = $null
foreach ($c in $certChain) {
    if ($c.HasPrivateKey) { $leaf = $c; break }
}
if (-not $leaf) { $leaf = $certChain[0] }

$leafType   = Resolve-CertType $leaf.Subject
$teamFromP12 = if ($leaf.Subject -match 'OU=([A-Z0-9]{10})') { $Matches[1] } else { '' }
$cnMatch    = if ($leaf.Subject -match 'CN="([^"]+)"') { $Matches[1] } elseif ($leaf.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $leaf.Subject }

Write-Host ("  证书类型   : {0}" -f $leafType)
Write-Host ("  证书名称   : {0}" -f $cnMatch)
Write-Host ("  Team ID    : {0}" -f $(if ($teamFromP12) { $teamFromP12 } else { '未识别' }))
Write-Host ("  有效期     : {0}" -f (Format-DateInfo $leaf.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')))
Write-Host ("  含私钥     : {0}" -f $(if ($leaf.HasPrivateKey) { '是 ✓' } else { '否 ✗（无法签名！）' }))
Write-Host ("  SHA1 指纹  : {0}" -f $leaf.Thumbprint)

# ---------- 解析描述文件 ----------
Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '  描述文件 (.mobileprovision)' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan

$raw = [System.IO.File]::ReadAllBytes($ProfilePath)
$text = [System.Text.Encoding]::UTF8.GetString($raw)
$si = $text.IndexOf('<?xml')
$ei = $text.IndexOf('</plist>')
if ($si -lt 0 -or $ei -lt 0) { Write-Host '描述文件不是 XML plist，无法解析' -ForegroundColor Red; exit 1 }

[xml]$doc = $text.Substring($si, $ei - $si + 8)
$plistNode = $doc.DocumentElement
$pp = ConvertFrom-PlistNode $plistNode.FirstChild

$ppName      = $pp['Name']
$ppTeam      = @($pp['TeamIdentifier'])[0]
$ppUuid      = $pp['UUID']
$ppAppIdEnt  = $pp['Entitlements']['application-identifier']
$ppAppIdName = $pp['AppIDName']
$ppExpire    = $pp['ExpirationDate']
$ppDevices   = $pp['ProvisionedDevices']
$ppGetTask   = $pp['Entitlements']['get-task-allow']
$ppPlatforms = @($pp['Platform'])
$ppCerts     = @($pp['DeveloperCertificates'])

$isWildcard = $ppAppIdEnt -match '\.\*$'
$appIdBare  = ($ppAppIdEnt -replace ("^" + [regex]::Escape($ppTeam) + "\."), '')

$ppType = if ($ppGetTask -eq $true) { 'Development（开发/调试）' }
          elseif ($ppDevices -and @($ppDevices).Count -gt 0) { 'Ad Hoc（分发给登记设备）' }
          else { 'App Store（上架分发）' }

$recommendMethod = if ($ppGetTask -eq $true) { 'development' }
                   elseif ($ppDevices -and @($ppDevices).Count -gt 0) { 'ad-hoc' }
                   else { 'app-store' }

Write-Host ("  描述文件名称 : {0}" -f $ppName)
Write-Host ("  UUID         : {0}" -f $ppUuid)
Write-Host ("  Team ID      : {0}" -f $ppTeam)
Write-Host ("  App ID       : {0}{1}" -f $ppAppIdEnt, $(if ($isWildcard) { '  （通配符，可签任何 ' + ($ppAppIdEnt -replace '\*','xxx') + '）' } else { '' }))
Write-Host ("  App ID 名称  : {0}" -f $ppAppIdName)
Write-Host ("  类型         : {0}" -f $ppType)
Write-Host ("  有效期       : {0}" -f (Format-DateInfo $ppExpire))
Write-Host ("  设备数       : {0}" -f $(if ($ppDevices) { @($ppDevices).Count } else { '无（App Store 类型）' }))
Write-Host ("  支持平台     : {0}" -f ($ppPlatforms -join ', '))
Write-Host ("  推荐 method  : {0}" -f $recommendMethod)

# ---------- 证书匹配校验 ----------
Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '  匹配校验' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan

$ppCertThumbs = @()
Write-Host '  描述文件绑定的证书:'
foreach ($c64 in $ppCerts) {
    try {
        $der = [Convert]::FromBase64String($c64)
        $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $der)
        $ppCertThumbs += $x.Thumbprint
        $t = Resolve-CertType $x.Subject
        $cn = if ($x.Subject -match 'CN="([^"]+)"') { $Matches[1] } elseif ($x.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $x.Subject }
        Write-Host ("    - {0}  [{1}]" -f $cn, $t)
        Write-Host ("      SHA1: {0}" -f $x.Thumbprint) -ForegroundColor DarkGray
    } catch {
        Write-Host ("    - 证书解析失败: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

$matched = $ppCertThumbs -contains $leaf.Thumbprint
Write-Host ''
if ($matched) {
    Write-Host '  ✓ 匹配：你的 p12 证书在描述文件的可签证书列表中，可以直接使用' -ForegroundColor Green
} else {
    Write-Host '  ✗ 不匹配：你的 p12 证书不在描述文件的证书列表里，签名会失败！' -ForegroundColor Red
    Write-Host '    解决：' -ForegroundColor Yellow
    Write-Host '      1) 换用描述文件里列出的那几张证书对应的 p12（需要含私钥），或' -ForegroundColor Yellow
    Write-Host '      2) 去 developer.apple.com 重新生成描述文件，勾选当前这张证书' -ForegroundColor Yellow
}

$teamMismatch = ($ppTeam -ne $teamFromP12) -and $teamFromP12
if ($teamMismatch) {
    Write-Host ("  ⚠ Team ID 不一致：证书={0} / 描述文件={1}" -f $teamFromP12, $ppTeam) -ForegroundColor Yellow
}

# ---------- 生成 Secrets 值 ----------
Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '  GitHub Secrets（复制到仓库设置）' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan

$p12B64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($P12Path))
$ppB64  = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ProfilePath))

$secretMap = [ordered]@{
    'BUILD_CERTIFICATE_BASE64'      = $p12B64
    'P12_PASSWORD'                  = $P12Password
    'PROVISIONING_PROFILE_BASE64'   = $ppB64
    'KEYCHAIN_PASSWORD'             = 'Passw0rd_ci'
    'TEAM_ID'                       = $ppTeam
    'PROFILE_NAME'                  = $ppName
    'BUNDLE_ID'                     = $(if ($BundleId) { $BundleId } elseif (-not $isWildcard) { $appIdBare } else { '<你的具体 Bundle ID，如 com.megmt.projectA>' })
}

foreach ($k in $secretMap.Keys) {
    $v = $secretMap[$k]
    if ($v.Length -gt 60) {
        Write-Host ("  {0} = <{1} 字符 Base64，已写入文件>" -f $k, $v.Length) -ForegroundColor White
    } else {
        Write-Host ("  {0} = {1}" -f $k, $v) -ForegroundColor White
    }
}

# 写文件
$b64Path = Join-Path $OutDir 'certificate.p12.base64.txt'
$ppB64Path = Join-Path $OutDir 'profile.mobileprovision.base64.txt'
[System.IO.File]::WriteAllText($b64Path, $p12B64, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($ppB64Path, $ppB64, (New-Object System.Text.UTF8Encoding($false)))

# JSON 汇总
$summary = [ordered]@{
    certificate = [ordered]@{
        type      = $leafType
        name      = $cnMatch
        teamId    = $teamFromP12
        expiresAt = $leaf.NotAfter.ToString('o')
        hasKey    = $leaf.HasPrivateKey
        sha1      = $leaf.Thumbprint
    }
    profile = [ordered]@{
        name           = $ppName
        uuid           = $ppUuid
        teamId         = $ppTeam
        appId          = $ppAppIdEnt
        appIdName      = $ppAppIdName
        type           = $ppType
        expiresAt      = $ppExpire
        deviceCount    = $(if ($ppDevices) { @($ppDevices).Count } else { 0 })
        platforms      = $ppPlatforms
        recommendMethod = $recommendMethod
        boundCerts     = $ppCertThumbs
    }
    check = [ordered]@{
        certMatched = $matched
        teamMatched = (-not $teamMismatch)
    }
    secrets = $secretMap
}
$jsonPath = Join-Path $OutDir 'signing-info.json'
[System.IO.File]::WriteAllText($jsonPath, ($summary | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

# ExportOptions.plist
if ($BundleId) {
    $exportPlist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$recommendMethod</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$ppTeam</string>
    <key>signingCertificate</key>
    <string>$(if ($leafType -match 'Distribution|分發|分发') { 'Apple Distribution' } else { 'Apple Development' })</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BundleId</key>
        <string>$ppName</string>
    </dict>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
"@
    $exportPath = Join-Path $OutDir 'ExportOptions.plist'
    [System.IO.File]::WriteAllText($exportPath, $exportPlist, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("`n  已生成 ExportOptions.plist: {0}" -f $exportPath) -ForegroundColor Green
}

Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host ("  输出目录: {0}" -f $OutDir) -ForegroundColor Green
Write-Host '    - certificate.p12.base64.txt' -ForegroundColor Gray
Write-Host '    - profile.mobileprovision.base64.txt' -ForegroundColor Gray
Write-Host '    - signing-info.json' -ForegroundColor Gray
Write-Host '=========================================' -ForegroundColor Cyan

if ($Copy) {
    Set-Clipboard -Value $ppB64
    Write-Host '  描述文件 Base64 已复制到剪贴板' -ForegroundColor Green
}

Write-Host ''
if (-not $matched) {
    Write-Host '  提醒：证书与描述文件不匹配，先修好再配置 Secrets。' -ForegroundColor Red
} else {
    Write-Host '  一切正常，可以按上面的值配置 Secrets 了。' -ForegroundColor Green
}
