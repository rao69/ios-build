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

## 签名信息提取工具（每次换描述文件时用）

`scripts/ios-signing-helper.ps1` —— 零依赖，纯 PowerShell，任何 Windows 直接跑。

```powershell
# 交互式（会依次提示输入路径和密码）
.\scripts\ios-signing-helper.ps1

# 一步到位
.\scripts\ios-signing-helper.ps1 `
  -P12Path "C:\path\cert.p12" `
  -P12Password "你的p12密码" `
  -ProfilePath "C:\path\projectA.mobileprovision" `
  -BundleId "com.megmt.projectA"
```

它会输出：

1. **证书信息**：类型（Development / Distribution）、Team ID、有效期、是否含私钥
2. **描述文件信息**：Name、UUID、App ID（是否通配符）、类型、有效期、设备数、支持平台
3. **匹配校验**（最关键）：你的 p12 证书是否在描述文件绑定的证书列表里
4. **推荐 export method**：自动判断 development / ad-hoc / app-store
5. **7 个 Secrets 的确切值**：base64 太长的写入文件，短值直接打印
6. 生成 `ExportOptions.plist` 和 `signing-info.json` 到 `桌面\ios-signing-output\`

### 换项目的标准流程

每个项目在后台生成不同的描述文件后，只需要两步：

```powershell
# 1. 解析并校验，生成 signing-info.json
.\scripts\ios-signing-helper.ps1

# 2. 自动写入仓库 Secrets（不用手工粘贴）
.\scripts\push-secrets.ps1 -Repo "rao69/ios-build" -Token "ghp_xxxx"
```

第 2 步也可以什么都不传，脚本会交互式提示仓库和 Token；
Windows 上直接双击 `填入GitHub Secrets.bat` 效果一样。

`push-secrets.ps1` 做的事：

1. 读 `%USERPROFILE%\Desktop\ios-signing-output\signing-info.json`
2. 校验 `check.certMatched`，不通过直接中止（避免白跑一次构建）
3. 用 libsodium 的 `crypto_box_seal` 按 GitHub 公钥加密每个值（GitHub 的强制要求）
4. 逐个 PUT 到 `/repos/{owner}/{repo}/actions/secrets/{name}`
5. 打印成功/失败清单，并给出 Secrets 页面链接

**依赖**：`libsodium.dll`（x64）必须和脚本放在同一目录。首次运行会问「是否保存 Token 到本地」，
选 y 会写到 `.github-token`，以后就不用再粘贴。

**参数**：

| 参数 | 说明 |
|---|---|
| `-Repo` | `owner/repo`，省略则提示，默认 `rao69/ios-build` |
| `-Token` | GitHub classic token（需 `repo` 权限），省略则读 `.github-token` 或提示输入 |
| `-InfoFile` | 指定 `signing-info.json` 路径，省略则用桌面默认位置 |
| `-DryRun` | 只打印将要写入的内容，不实际写入 |

### 证书三个月续签时

只需重跑一次 `ios-signing-helper.ps1`（换新 p12）→ 再跑一次 `push-secrets.ps1`，全量覆盖即可。


### 常见失败原因

| 症状 | 原因 |
|---|---|
| 工具报「不匹配」 | p12 是 Distribution 证书，但描述文件绑的是 Development 证书（或反过来），去后台重新生成描述文件时勾对证书 |
| 构建时报 `No profiles for 'xxx' were found` | `BUNDLE_ID` 和描述文件的 App ID 不匹配（通配符 Profile 才能签多个 App） |
| 构建时报 `Provisioning profile doesn't include signing certificate` | Secrets 里的证书和描述文件是两套，重跑工具校验 |
| 构建时报 `No signing certificate "iOS Development" found` | `ExportOptions.plist` 或 workflow 里的 `signingCertificate` 写错了，Distribution 证书要写 `Apple Distribution` |

## 注意点


- **路径配置**在 `build-ios.yml` 顶部 `env`：如果你的工程目录有前缀（比如 `ios/Unity-iPhone.xcodeproj`），改那里
- **用了 CocoaPods**：改 `env` 里的注释，切换到 `XCODE_WORKSPACE`
- **大工程**：Unity 导出的工程动辄几百 MB，建议开 Git LFS
- **Xcode 版本**：`macos-26` runner 默认 Xcode 26.6，如需固定版本，在 workflow 里加 `sudo xcode-select -s /Applications/Xcode_26.6.app`
- **构建时长**：首次会跑 Pods 和 Unity 脚本，约 15–25 分钟；后续增量会快一些
- **公开仓库**：Actions 免费且不限时长（macOS runner 也一样）
