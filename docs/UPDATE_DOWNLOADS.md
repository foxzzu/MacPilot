# 更新包下载源

MacPilot 下载本项目 GitHub Release 安装包时，按以下顺序尝试：

1. Xget：`https://xget.xi-xu.me/gh/misswell/MacPilot/releases/download/...`
2. GHFast：`https://ghfast.top/https://github.com/...`
3. GH-Proxy：`https://gh-proxy.org/https://github.com/...`
4. GitHub 原始下载地址（最终兜底）。

首次按上述顺序尝试，后续优先使用上次下载并通过 SHA-256 校验的镜像，其余镜像保持默认顺序，直连始终最后。上次只有直连成功则恢复默认镜像顺序。偏好仅限内置域名，不接受任意地址。网络变化导致镜像失效时自动继续尝试其他源；这不是实时测速排序。单个源连续 15 秒没有网络响应、请求失败、HTTP 状态不是 200，或下载文件的 SHA-256 不匹配时，会自动尝试下一个源。正常持续传输不受 15 秒空闲超时限制。用户取消请求时停止，不继续切换源。所有源失败后显示更新失败，并在诊断日志记录各源失败原因。

版本信息和预期 SHA-256 仍由 GitHub 直接提供；检查更新阶段目前仍需要能够连接 GitHub。Xget 只传输安装包，不能改变预期摘要。下载成功后仍执行应用版本、Developer ID 团队和签名身份校验。第三方地址及其他仓库不会被自动改写为镜像地址。

Xget 地址规则：https://github.com/xixu-me/Xget

GHFast：https://ghfast.top/

GH-Proxy 地址规则：https://gh-proxy.com/docs/github-accelerator
## Stable / Beta 通道

设置 → 软件更新中选择更新通道。正式安装和缺少 `updateChannel` 的旧配置均使用 Stable；纯 Debug 新配置默认 Beta。启用 Beta 需要确认，切回 Stable 不需要确认。About/设置版本区域显示的是安装包通道，与订阅偏好分开。

Stable 使用 GitHub `/releases/latest`，拒绝 draft、prerelease 及预发布版本标签。Beta 分页读取 `/releases`，只选 `prerelease=true`、`-beta.N` 且存在适配 CPU 的校验安装包的最高 SemVer。没有 Beta 时显示已是最新版本。目标版本小于或等于当前版本均不提示更新；Beta 切回 Stable 后须等更高的正式版，不自动降级。切换通道会清除旧结果，正在进行的旧查询不会覆盖新通道结果。Beta API 限流会报错，不回退到 Stable 网页。

构建示例：

```sh
MACPILOT_CHANNEL=stable MACPILOT_VERSION=1.6.0 ./Scripts/build-app.sh
MACPILOT_CHANNEL=beta MACPILOT_VERSION=1.7.0-beta.1 ./Scripts/build-app.sh
```

未显式指定版本时，Stable 的版本推导忽略 Beta 标签；Beta 在没有可用预发布基线时生成下一个 patch 的 `-beta.1`。CI 发布始终使用触发标签的精确版本。

脚本验证通道与版本一致后生成编译期 `BuildInfo.swift`，退出时恢复开发源码；Info.plist 同时嵌入 `MacPilotUpdateChannel` 与完整 `MacPilotVersion`；Apple 的 `CFBundleShortVersionString` 保留纯数字核心版本，界面和安装校验均读取完整版本。Bundle ID、签名 designated requirement、Helper 和权限身份共用原有值。

`release.yml` 负责正式 tag，`release-beta.yml` 负责 beta tag，均调用 `release-common.yml` 执行主分支 CI 门禁、Developer ID 签名、公证和装订。Beta 发布使用 `--prerelease --latest=false`，正式发布使用 `--latest`。每次发布含 arm64/x86_64 更新 ZIP 和通用 `MacPilot-<version>.dmg`，DMG 也签名、公证和装订。

版本排序遵循 [SemVer 2.0.0](https://semver.org/)，API 通道约定见 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases)。权限延续仍需在实际升级后人工确认 Accessibility、屏幕录制、FinderSync 和 Helper；签名身份测试不能代替系统授权验收。
