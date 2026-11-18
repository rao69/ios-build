# iOS 构建仓库（Unity → IPA，Windows 本地开发）

在 **Windows** 上开发，把 iOS 打包交给 GitHub Actions 的 `macos-26` runner（Apple Silicon + Xcode 26），
产出已签名的 `.ipa`。

## 工作流

```
Windows: Unity → Build Settings → iOS → Export（生成 Xcode 工程）
        ↓ git push 到本仓库
GitHub Actions (macos-26):
        导入 p12 证书 + mobileprovision
        xcodebuild archive
        xcodebuild -exportArchive
        ↓
产物: ios-ipa-<build号>.zip 中的 .ipa
```

## 一次性配置：7 个 Secrets

进入仓库 → **Settings → Secrets and variables → Actions → New repository secret**，逐个添加：

| Secret 名称 | 内容 | 怎么拿到 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | 你的 `.p12` 证书 Base64 编码 | 见下方「生成 Base64」 |
| `P12_PASSWORD` | 导出 p12 时设置的密码 | 你自己定的 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 Base64 编码 | 见下方 |
| `KEYCHAIN_PASSWORD` | 任意随机字符串（如 `Passw0rd_ci`） | 随便填，仅 CI 内部使用 |
| `TEAM_ID` | 10 位开发者 Team ID | 开发者后台 Membership 页，或从描述文件里读 |
| `PROFILE_NAME` | 描述文件的 **Name**（不是文件名） | 开发者后台 Profiles 列表里的 Name |
| `BUNDLE_ID` | 应用 Bundle Identifier | Unity Player Settings 里填的那个 |

### 生成 Base64（Windows PowerShell）

```powershell
# 证书
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\cert.p12")) | Set-Clipboard

# 描述文件
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\profile.mobileprovision")) | Set-Clipboard
```

也可用本仓库的 `scripts/make-base64.ps1`。

### 读取 TEAM_ID 和 PROFILE_NAME

描述文件本质是一个带签名的 plist，可以直接解出来（Windows 上把 `.mobileprovision` 改后缀为 `.plist` 用记事本打开，或用 Python）：

```powershell
python -c "import plistlib,sys;d=plistlib.load(open(r'profile.mobileprovision','rb'));print('Team:',d['TeamIdentifier'][0]);print('Name:',d['Name'])"
```

## 使用

1. Unity 导出 Xcode 工程到仓库目录，`git add . && git commit && git push`
2. 进入 **Actions → Build iOS IPA → Run workflow**，选导出类型：
   - `development`：真机调试包
   - `ad-hoc`：分发给测试设备（需在描述文件里登记 UDID）
   - `app-store`：上架
3. 构建完在 run 页面底部 **Artifacts** 下载 `ios-ipa-<n>`

## 注意点

- **路径配置**在 `build-ios.yml` 顶部 `env`：如果你的工程目录有前缀（比如 `ios/Unity-iPhone.xcodeproj`），改那里
- **用了 CocoaPods**：改 `env` 里的注释，切换到 `XCODE_WORKSPACE`
- **大工程**：Unity 导出的工程动辄几百 MB，建议开 Git LFS
- **Xcode 版本**：`macos-26` runner 默认 Xcode 26.6，如需固定版本，在 workflow 里加 `sudo xcode-select -s /Applications/Xcode_26.6.app`
- **构建时长**：首次会跑 Pods 和 Unity 脚本，约 15–25 分钟；后续增量会快一些
- **公开仓库**：Actions 免费且不限时长（macOS runner 也一样）
