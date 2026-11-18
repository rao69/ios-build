# 生成 iOS 签名文件 Base64，可直接粘贴到 GitHub Secrets
# 用法: .\make-base64.ps1 -CertPath "C:\path\cert.p12" -ProfilePath "C:\path\profile.mobileprovision"

param(
    [Parameter(Mandatory = $false)]
    [string]$CertPath,

    [Parameter(Mandatory = $false)]
    [string]$ProfilePath
)

function Convert-FileToBase64 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "文件不存在: $Path"
        return $null
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $b64 = [Convert]::ToBase64String($bytes)
    return $b64
}

if (-not $CertPath) {
    $CertPath = Read-Host "请输入 .p12 证书完整路径（直接回车跳过）"
}

if (-not $ProfilePath) {
    $ProfilePath = Read-Host "请输入 .mobileprovision 完整路径（直接回车跳过）"
}

if ($CertPath -and (Test-Path -LiteralPath $CertPath)) {
    $b64 = Convert-FileToBase64 -Path $CertPath
    Set-Clipboard -Value $b64
    Write-Host "`n[证书] Base64 已复制到剪贴板，长度 $($b64.Length) 字符" -ForegroundColor Green
    Write-Host "        粘贴到 Secret: BUILD_CERTIFICATE_BASE64" -ForegroundColor Yellow
}

if ($ProfilePath -and (Test-Path -LiteralPath $ProfilePath)) {
    $b64 = Convert-FileToBase64 -Path $ProfilePath
    Set-Clipboard -Value $b64
    Write-Host "`n[描述文件] Base64 已复制到剪贴板，长度 $($b64.Length) 字符" -ForegroundColor Green
    Write-Host "          粘贴到 Secret: PROVISIONING_PROFILE_BASE64" -ForegroundColor Yellow

    # 尝试解析出 Team ID 和 Profile Name
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        Write-Host "`n[描述文件信息]" -ForegroundColor Cyan
        $code = "import plistlib;d=plistlib.load(open(r'$ProfilePath','rb'));print('  Team ID     : '+d['TeamIdentifier'][0]);print('  Profile Name: '+d['Name']);print('  App ID      : '+d['Entitlements'].get('application-identifier',''))"
        & python -c $code
    }
}

Write-Host "`n完成。记得把 P12_PASSWORD / KEYCHAIN_PASSWORD / TEAM_ID / PROFILE_NAME / BUNDLE_ID 也一并配置上。" -ForegroundColor Green
