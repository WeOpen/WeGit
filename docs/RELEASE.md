# WeGit 分发与发布操作

> 2026-10-16 更新：用户仅选择 GitHub Releases＋项目网站，无商店/无开发者账号。新增 `scripts/package-release.sh --adhoc`，采用正式 Bundle ID、明确未公证状态和来源校验；Developer ID／公证改为未来可选。本文件下方较早的签名公证要求保留其历史时点，以 [当前 CI/CD 发布流程](GITHUB_WORKFLOW.md#5-无开发者账号的-cd)为准。

用户已选择 **MIT + Developer ID 签名、公证后直接分发**。当前版本仍为 `0.1.0` 开发预览，尚未完成 Beta 或正式发布。

## 1. 打包前验证

```bash
scripts/verify.sh
scripts/verify.sh --ui
scripts/build.sh Release
scripts/benchmark.sh
scripts/benchmark-ui-launch.sh
```

UI 与启动性能测试需要可交互的 macOS 登录会话。后台、启动与完整界面测量的边界见 [性能记录](PERFORMANCE.md)。启动性能测试之后应再次运行 `scripts/build.sh Release`，移除 XCTest 附加的签名权限，再打包。签名、公证不能替代功能、UI、兼容性和真实使用验收。

## 2. 本地开发包

```bash
scripts/package-release.sh --preview
```

该模式打包已构建的 Release 应用，核对构建时写入的 `build-source.json` 与当前应用源码、版本和 Bundle ID，再检查签名完整性、AskPass、MIT 许可证及测试入口排除。构建回执随应用签名；缺失回执、源码已变化、包含测试程序或带有调试/自动化签名权限时拒绝打包。输出 ZIP、SHA-256 与源码清单，位于 `.build/releases/package-*`。

预览包仍使用开发 Bundle ID 和本机 ad-hoc 签名，不是已经公证的外部分发包。清单如实记录未提交源码状态，不伪造 Git 版本号或发布记录。

2026-10-10 最新本机开发包为 `.build/releases/package-YwQYPM/WeGit-0.1.0-development.zip`，其来源、校验和及解包验证见 [开发记录第 19 节](DEVELOPMENT.md#19-plan-复核推送未知结果与恢复)。该包对应通过 165 项核心和 25 项原生 UI 功能回归的实现，包含推送未知结果与恢复；辅助访问审查仍未通过，不能代替 Beta 或正式发布验收。此前包的证据继续保留在对应历史章节。

## 3. Developer ID 与公证

先在本机配置可用的 Developer ID Application 证书及对应私钥，再配置 `notarytool` 的 Keychain profile。项目不保存 Apple 密码、私钥或公证密钥。

设置以下本地环境变量：

| 变量 | 内容 |
| --- | --- |
| `WEGIT_TEAM_ID` | Apple Developer 团队 ID |
| `WEGIT_SIGNING_IDENTITY` | 已存在证书的完整 `Developer ID Application: …` 名称 |
| `WEGIT_BUNDLE_ID` | 可省略；默认并校验正式标识 `com.willxue.WeGit` |
| `WEGIT_NOTARY_PROFILE` | 已在 Keychain 中配置的 notarytool profile 名称 |

```bash
# 重新构建并签名；不提交公证
scripts/package-release.sh --sign

# 重新构建、签名、提交 Apple 公证、装订票据、执行 Gatekeeper 检查
scripts/package-release.sh --notarize
```

脚本不会将失败的签名降级为 ad-hoc，也不会绕过 Gatekeeper。公证模式只有在 Apple 返回 `Accepted`、票据装订及验证、Gatekeeper 检查全部成功后才产出带 `notarized` 名称的包；随后重新压缩以包含票据。

签名和公证路径尚未在当前环境执行。2026-10-10 检查只发现 Apple Development 身份，未发现可用的 Developer ID Application 身份。

## 4. CI 与来源追溯

远端仓库为 `WeOpen/WeGit`。2026-10-10 检查时尚无默认分支提交，也没有注册的 Actions Runner。当前工作流要求 `wegit-macos27` 自托管标签。

当日 [GitHub 托管镜像清单](https://github.com/actions/runner-images)列出了 macOS 26，未列出满足本项目目标的 macOS 27 镜像；因此没有改用不匹配的托管系统来伪报兼容通过。Runner 注册和首次推送应在配置明确后完成。工作流不运行 fork PR，避免把不受信任代码放到个人自托管环境。

每个安装包保留校验和、版本、Bundle ID、签名/公证状态、Git 提交（若存在）与源文件摘要。发布时应使用通过验证的同一份源码和安装包，保留 CI 与测试结果包。

构建、测试和打包期间保持应用源码稳定。修改源码后重新构建；不要把旧 Release 目录与新源码清单拼成一个交付包。

## 5. Beta 与正式发布门槛

- 在干净的目标系统上安装和运行公证包，验证完整日常流程。
- 使用获准的测试账号验证 GitHub/GitLab 与通用 Git 服务的 HTTPS/SSH；不把测试凭证加入仓库。
- 获得真实 Beta 用户反馈，记录复现、影响、修复与回归；目前未发送邀请或收集反馈。
- 完成最小窗口、浅色/深色、键盘、VoiceOver 与性能验收。
- 写明版本说明、已知限制、帮助入口与首版数据迁移策略，再发布经过验证的包。

应用默认不上传仓库数据。诊断摘要由用户主动导出，包含版本和命令结果，不包含代码、Diff、提交消息、仓库路径或凭证。Beta 反馈优先引用该摘要和可复现步骤。

## 6. 开发预览的数据位置

最近仓库记录保存在专属本机数据库 `~/Library/Application Support/WeGit/Repositories.store`，不使用 CloudKit。此前默认 SwiftData 数据库未被移动或删除；上次仓库仍可恢复，其他旧最近条目可重新打开添加。

草稿和页面偏好按仓库实体记录。旧版按路径保存的草稿保留，可在提交设置中明确核对后恢复。开发 Bundle ID 与将来的正式 Bundle ID 使用不同偏好域，正式交付前应单独验证开发预览数据的导入方案；首次正式发布不存在既有正式版本的数据库迁移。
