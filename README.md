# iOS 构建仓库（Unity → IPA → TestFlight）

在 **Windows** 上开发 Unity，把 iOS 编译和签名交给 GitHub Actions 的 `macos-26` runner
（Apple Silicon + Xcode 26），产出已签名 `.ipa` 并自动上传 TestFlight。

> 背景：本机黑苹果虚拟机 macOS 14.7 的 Xcode 版本太老，装不了新 SDK，编译链已断。
> 所以不再依赖本地 macOS，全部搬到这里。

## 整体流程

```
Unity → File → Build Settings → iOS → Build（导出 Xcode 工程到本地目录）
        ↓
publish-xcode.ps1（Windows 本地，一键）
        压缩 zip → 上传到 GitHub Release（tag: <项目名>-latest）
        ↓
GitHub Actions（手动触发，macos-26）
        下载 zip → unzip → 导入 p12 + mobileprovision
        → xcodebuild archive → xcodebuild -exportArchive
        ↓
Artifacts 里的 ios-ipa-<n>.zip + 自动上传 TestFlight
```

## 为什么不用 git push 工程

Unity 导出的 Xcode 工程实测 **1064 个文件 / 844 MB**，其中：

- `Libraries/libiPhone-lib.a` **321 MB**
- `Libraries/libil2cpp.a` 67 MB

GitHub 仓库单文件硬限制 **100 MB**，直接 push 必然被拒；用 Git LFS 免费额度只有 1 GB/月，
一次就占满。

**Release asset 支持 2 GB/文件，且不占用仓库体积**，所以改成「压缩上传 Release，CI 下载解压」。
实测压缩率约 25%（844 MB → 213 MB），压缩 33 秒、上传 59 秒。

## 一次性配置：10 个 Secrets

### 签名（7 个）

| Secret | 内容 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `.p12` 的 Base64 |
| `P12_PASSWORD` | p12 导出密码 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 Base64 |
| `KEYCHAIN_PASSWORD` | 任意字符串（CI 内部用） |
| `TEAM_ID` | 10 位 Team ID |
| `PROFILE_NAME` | 描述文件的 **Name**（不是文件名） |
| `BUNDLE_ID` | 应用 Bundle Identifier |

用 `ios-signing-helper.ps1` 生成 → `push-secrets.ps1` 自动写入，不用手工粘贴。

### TestFlight 上传（任选一种，不配也能构建）

#### 方式 A：Apple ID + App 专用密码（不需要 Account Holder 开权限）

如果你的账号只是 Admin、没有 API 访问权限，走这条最快：

1. 打开 <https://appleid.apple.com>，用你**开发者团队里的那个 Apple ID** 登录
2. **登录和安全 → App 专用密码 → 生成**（名字随便，如 `ios-ci`）
3. 得到一个 16 位密码，形如 `abcd-efgh-ijkl-mnop`
4. 加两个 Secret：

| Secret | 内容 |
|---|---|
| `ASC_USERNAME` | 你的 Apple ID 邮箱 |
| `ASC_PASSWORD` | 上面那个 App 专用密码（**不是** Apple ID 登录密码） |

#### 方式 B：App Store Connect API Key（推荐，最稳定）

前提：账户必须已经开通 API 访问权限，而**首次开通只有「账户持有人（Account Holder）」能做**
（用户和访问 → 集成 → Request Access，勾选条款提交）。Admin 看不到这个入口是正常的。

开通后，Admin 也能生成 Team Key：

1. 用户和访问 → **集成** → App Store Connect API → **Team Keys** → 生成密钥
2. 权限选 **App Manager** 或 **Admin**
3. 记下 **Key ID** 和页面顶部的 **Issuer ID**，下载 `.p8`（只能下一次）
4. 加三个 Secret：

| Secret | 内容 |
|---|---|
| `ASC_API_KEY_ID` | Key ID（10 位） |
| `ASC_ISSUER_ID` | Issuer ID（UUID） |
| `ASC_API_KEY_BASE64` | `.p8` 的 Base64 |

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\AuthKey_XXXX.p8")) | Set-Clipboard
```

> workflow 会自动判断：配了 `ASC_API_KEY_BASE64` 走方式 B，否则配了 `ASC_USERNAME` 走方式 A。
> 两个都没配就跳过上传，ipa 仍可从 Artifacts 下载。

## 日常操作（三步）

### 1. 发布工程

双击 `发布Xcode工程.bat`，或：

```powershell
.\tools\publish-xcode.ps1 -ProjectPath "F:\UnityProject\TYDGYProject\Release\ET"
```

脚本会自动：校验工程结构 → 压缩 → 清理旧 Release → 建新 Release → 上传 → 打印构建参数。

项目名默认取目录名（`ET`），可覆盖：

```powershell
.\tools\publish-xcode.ps1 -ProjectPath "..." -ProjectName "TYDGY"
```

只压缩不上传（先看看体积）：`-NoUpload`

### 2. 触发构建

仓库 → Actions → **Build iOS IPA** → Run workflow：

| 参数 | 值 |
|---|---|
| `project` | 上一步的项目名，如 `ET` |
| `export_method` | `app-store`（TestFlight 分发必选） |
| `upload_to_testflight` | 勾选 |

约 15–25 分钟。产物在 run 页面底部 **Artifacts** → `ios-ipa-<n>`。

### 3. 看 TestFlight

App Store Connect → TestFlight，等 5–15 分钟构建处理完成即可分发给测试员。

## 多个项目

Release tag 是 `<项目名>-latest`，天然隔离：

```
ET-latest      → ET.zip
TYDGY-latest   → TYDGY.zip
```

每个项目各自发布、各自触发，构建时 `project` 填对应的名字。
**注意**：每个项目的描述文件不同，换项目前要先跑 `ios-signing-helper.ps1` +
`push-secrets.ps1` 把 Secrets 切到那个项目的描述文件（证书三个月续签时才需要换）。

## 签名相关的坑（踩过，记录备查）

### 1. UnityFramework 不支持 provisioning profile

报错：

```
UnityFramework does not support provisioning profiles,
but provisioning profile xxx has been manually specified.
```

原因：Unity 工程里 `UnityFramework` 是 framework target，不需要 profile。
如果命令行全局传 `PROVISIONING_PROFILE_SPECIFIER=xxx`，它会作用到所有 target。

正确做法是 **只传 `PROVISIONING_PROFILE_SPECIFIER_APP`**——因为 Unity 的主 target 用的是间接变量：

```
PROVISIONING_PROFILE_SPECIFIER = "$(PROVISIONING_PROFILE_SPECIFIER_APP)"
```

workflow 里已是这样：

```bash
xcodebuild archive ... \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER_APP="$PROFILE_NAME"
```

### 2. 不能用 Automatic 签名

CI runner 上没有登录 Apple ID，Automatic 会报：

```
error: No Accounts: Add a new account in Accounts settings.
```

所以 archive 一律 Manual。

### 3. 别传带方括号的 setting

这样写会解析错：

```bash
"CODE_SIGN_IDENTITY[sdk=iphoneos*]=Apple Distribution"   # ❌ 报 No certificate matching 'iphoneos*]=...'
```

只传基础的 `CODE_SIGN_IDENTITY="Apple Distribution"` 即可。

### 4. Build number 必须递增

TF 会拒绝重复的 `CFBundleVersion`。Unity Player Settings → iOS → Build 号，
或上传报 "bundle version must be higher than the previously uploaded version" 时去加 1。

## 常见失败排查

| 症状 | 原因 |
|---|---|
| `下载失败，请确认已用 publish-xcode.ps1 发布过项目 xxx` | project 名字写错，或还没发布 |
| `找不到 .xcworkspace 或 .xcodeproj` | zip 根目录不是工程根（压缩时多套了一层目录） |
| `No signing certificate "Apple Distribution" found` | Secrets 里的证书是 Development 那套 |
| `Provisioning profile doesn't include signing certificate` | 证书和描述文件不配套，重跑 helper 校验 |
| `altool` 上传报 403 / auth | ASC API Key 的 Key ID / Issuer ID 填错，或没有 App Manager 权限 |
| 卡在 "Repository not found" | Token 权限或仓库名不对 |

## 目录

```
.github/workflows/build-ios.yml   CI 主流程
scripts/ios-signing-helper.ps1    解析 p12 + 描述文件，校验匹配，生成 Secrets 值
scripts/push-secrets.ps1          自动写入 GitHub Secrets（libsodium 加密）
scripts/publish-xcode.ps1         打包 Xcode 工程并上传 Release
```
