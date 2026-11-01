# WeGit 分发与发布操作

## v1.0.0 发布决定（2026-10-19）

维护者已明确要求“跳过辅助功能这块吧，直接上线发布 v1.0”。本次按 **v1.0.0 单次发布例外**执行：保留常规受保护 PR、同提交 main CI、干净正式标识构建与完整制品校验，人工创建草稿并核对后公开发布。完整验收没有通过，`acceptanceRun` 保持 `null`；默认稳定版 workflow 的同提交完整验收要求不修改。

功能、安装、开发预览数据、回退、签名与所有未完成验证以[1.0.0 版本说明](releases/v1.0.0.md)为准。辅助功能暂缓不等于通过，最终性能、受保护目标机安装、Beta 和剩余兼容性也不标记完成。GitHub Releases 与网站使用同一份版本化 ZIP、校验和与来源清单。

以下为此前各时点的操作与证据，历史“尚无 Release / 0.1.0 开发预览 / 发布前置”表述不代表本次发布状态。

当前决定（2026-10-16，覆盖此前签名公证前置要求）：**MIT＋GitHub Releases＋项目网站直接分发，不发布到商店，不使用 TestFlight，目前没有 Apple Developer Program 账号**。项目网站采用 [GitHub Pages](https://weopen.github.io/WeGit/)，仓库已公开但没有 Release。版本仍为 `0.1.0` 开发预览，尚未完成 Beta 或 V1.0 发布。

当前路线使用 ad-hoc 完整性签名、无 Developer ID、未公证；Developer ID／公证为未来可选，不能再将账号/证书/profile 缺失列为本路线的前置阻塞。ad-hoc 不提供开发者身份认证，macOS 可能阻止下载后的首启；必须按实际目标机器记录下载、系统提示、用户信任选择与核心流程。参考 [Apple 的 Developer ID 说明](https://developer.apple.com/developer-id/)及[安全打开说明](https://support.apple.com/zh-cn/102445)。当前 P0 汇总见 [发布清单](V1_RELEASE_CHECKLIST.md)。

仓库与 CI/CD 已在 PR #10/#14 落地，最新应用已由 PR #15 合并并关闭 Issue #12；静态网站独立部署，当前没有上传应用 Release。下方历次开发包证据保留原有时点的发布要求与结果。

## 1. 打包前验证

```bash
scripts/verify.sh
scripts/verify.sh --ui
scripts/build.sh Release
scripts/benchmark.sh
scripts/benchmark-ui-launch.sh
```

UI 与启动性能测试需要可交互的 macOS 登录会话。后台、启动与完整界面测量的边界见 [性能记录](PERFORMANCE.md)。启动性能测试之后应再次运行 `scripts/build.sh Release`，移除 XCTest 附加的签名权限，再打包。任何签名方式都不能替代功能、UI、兼容性和真实使用验收；不公证也必须完成实际下载/安装验证。

## 2. 本地开发包

```bash
scripts/package-release.sh --preview

# 正式标识的无账号 ad-hoc 制品（仍未公证）
WEGIT_SKIP_PROJECT_GENERATION=1 scripts/package-release.sh --adhoc
```

该模式打包已构建的 Release 应用，核对构建时写入的 `build-source.json` 与当前应用源码、版本和 Bundle ID，再检查签名完整性、AskPass、MIT 许可证及测试入口排除。构建回执随应用签名；缺失回执、源码已变化、包含测试程序或带有调试/自动化签名权限时拒绝打包。输出 ZIP、SHA-256 与源码清单，位于 `.build/releases/package-*`。

预览包仍使用开发 Bundle ID 和本机 ad-hoc 签名，未经公证。清单如实记录未提交源码状态，不伪造 Git 版本号或发布记录。

正式 ID `com.willxue.wegit` 的 `--adhoc` 构建/打包路径已实现并实测。最新应用已接入 CI；V1.0 仍需最终版本、开发域数据导入、公开版本命名和下载说明。现有 `--preview` 只是开发包入口，不能直接改名冒充最终正式包。网站应链接同一版本化 GitHub ZIP、SHA-256、manifest 与版本说明，避免两套独立构建来源。

2026-10-12 图标接入前的开发包为 `.build/releases/package-rbNdcN/WeGit-0.1.0-development.zip`，SHA-256 为 `931702d394e6befdbb10ee713817a0def0a5f0c42069d14f06dac0916bc49644`。该包的普通 Release 构建来源与已通过的 30 次性能源码摘要一致，ZIP CRC、签名完整性、AskPass、MIT 许可证及测试入口排除均通过；签名权限为空。核心两套 Git 各 176 项通过；原生联合回归为 36/37，长 Clone 路径输入有失败，专项复测被 XCTest 初始化阻塞。完整状态见 [验收汇总](acceptance/2026-10-11/final-validation.json)，历史包证据保留。

加入浅色/深色原生图标后的专项开发包为 `.build/releases/package-TP7DrV/WeGit-0.1.0-development.zip`，SHA-256 为 `c9b5af94bf779e8428dceaf8ce91fe527be1bf1dd33ea2dd5a191b76e1004255`。源码回执包含 AppIcon.icon 的 SVG/JSON，Info.plist 指向 AppIcon，包内包含编译后的 AppIcon.icns 和 Assets.car；Aqua/DarkAqua 堆栈与关于窗口显示通过。来源、签名、空权限、AskPass/许可证、测试入口排除与 ZIP CRC 再次通过，详见 [图标验收](acceptance/2026-10-12/app-icon.json)。此包没有执行新的完整功能/辅助访问或 30 次性能验收，继续使用开发 Bundle ID 和 ad-hoc 签名，尚未公证；manifest 如实记录未提交工作区，不能代替 Beta 或正式发布。

界面组件统一和动效收尾时的开发包为 `.build/releases/package-PKpJav/WeGit-0.1.0-development.zip`，SHA-256 为 `7459a2b8b7c2305ed3a026d5c504c680760919a01eeadf87e6e0f6ec2d2ca86a`。当前源码回执、签名、空权限、AskPass/许可证、测试入口排除与 ZIP CRC 通过；两套 Git 核心、格式及构建通过。原生回归仅编译，XCTest 初始化仍阻塞执行；手动检查范围、新源码性能与辅助访问的待验项见 [界面美化记录](INTERFACE_POLISH.md)。此前包保留其历史证据。当前仍为 0.1.0 ad-hoc 开发预览，尚未公证，不关闭 V1.0 发布门槛。

2026-10-13 启动恢复修复时的开发包为 `.build/releases/package-5YY9wu/WeGit-0.1.0-development.zip`，SHA-256 为 `928083347691a1eb877c4357d43142227db869ec5bdfe0c475240cf4d417463c`，应用源码摘要为 `4690bf492189d72babe57dec7f24a29cf2ad62e7d9b666baf90434fd2a2da3a4`。普通 Release 重新构建后核对源码回执、包内 AskPass/MIT、测试入口排除、签名完整性、空权限及 ZIP CRC，并通过正常用户状态下的实际启动。最终启动回归与 Release 使用同一应用源码；两套 Git 核心、格式、Debug/Release 和原生回归编译通过。新增 XCTest 行为用例执行、新源码完整性能和辅助访问仍待验；该包仍为 0.1.0 ad-hoc 开发预览，未公证。完整失败及通过证据见 [启动恢复验收](acceptance/2026-10-13/inspector-startup/README.md)，不能作为 V1.0 正式发布包。

第二轮界面设计时的开发包为 `.build/releases/package-tFvFLY/WeGit-0.1.0-development.zip`，SHA-256 `80787d0ca49cd0fa24cf8fc1cedd2c9a049d61a5779f953991d4b176bfd799ca`，应用源码摘要 `43c855caf7d1396f75649abec8375d373beeba3dd6bd60bfb55c4cf86a372f0b`。来源、空权限、签名完整性、AskPass/MIT、测试入口排除及 ZIP CRC 均通过，普通用户模式启动恢复 History/Inspector 通过。两套 Git 核心、格式与构建通过；6 种启动组合与局部实际界面检查有证据。增强后的原生用例只确认编译，完整原生、辅助访问与新源码性能待验。此包仍为 0.1.0 ad-hoc 开发预览，未公证，见 [第二轮界面优化](acceptance/2026-10-13/interface-identity/README.md)。

顶部/菜单栏实现时的开发包为 `.build/releases/package-OaCDAm/WeGit-0.1.0-development.zip`，SHA-256 `f1f2749e48f7e893b0d316167b43550a6ec33c5063519084c0eabe8bd8c507a4`，应用摘要 `151e20665007ee76ce8605b4a79605274937aec507f1bf69a6dc323920d0b4e4`。来源、签名、空权限、AskPass/MIT、测试入口排除、CRC 和普通用户恢复启动通过；核心两套各 176 项、构建和最终源码 6 种启动组合通过。新增原生编译和局部实际面板行为有证据，完整原生/辅助访问/性能仍待验。此包继续为 0.1.0 ad-hoc 开发预览，未公证，见 [工具栏与菜单栏验收](acceptance/2026-10-13/toolbar-menu-bar/README.md)。

液态玻璃按钮/Tabs 实现时的开发包为 `.build/releases/package-IDrILs/WeGit-0.1.0-development.zip`，SHA-256 `e334867c544782f80ad2a807c42bd8b27fddb4d992aac62b50a4d1c25cb1320e`，应用摘要 `b3d057695e3c4f5180aeebc8b71016cb35f3c6c1a4b823862492355fc9045adb`。普通 Release 的来源回执、签名完整性、空权限、AskPass/MIT、测试入口排除与 ZIP CRC 通过；两套 Git 各 176 项、严格格式、构建和最终源码启动 6 种组合通过。原生回归只确认编译，局部实际 Tabs/键盘/主题/窄窗口/菜单栏检查和偏好恢复有证据。完整原生、辅助技术及新源码性能仍待验，继续为 0.1.0 ad-hoc 开发预览，未公证，见 [液态玻璃控件验收](acceptance/2026-10-13/glass-controls/README.md)。

2026-10-14 原生中性色收敛时的开发包为 `.build/releases/package-M47FMn/WeGit-0.1.0-development.zip`，SHA-256 `75cf1834e848df38801b088882ed9804b83075c00e7e7c36446a8bf4a24b50f9`，应用摘要 `b5b9e32eeb997e1e091c509f6895fb3a6c1eb20601e16e602ef83c4fbcf0d866`。普通 Release 来源回执、签名、空权限、AskPass/MIT、测试入口排除和 CRC 通过；Debug/Release、格式、六种最终源码启动和浅深色局部检查通过。核心输入不变，本轮未重跑核心或完整原生回归；辅助访问、矩阵和新源码性能继续待验。开发标识和 ad-hoc 签名保持，尚未公证，见 [原生面板配色验收](acceptance/2026-10-14/native-surfaces/README.md)。

Tabs/主题/侧栏修复当轮的开发包为 `.build/releases/package-WqSoDF/WeGit-0.1.0-development.zip`，SHA-256 `78f6ab75211db8aaab2dfd034f1c1286d7e0a8a52beb268ab9b3c9adccaed598`，应用摘要 `26d0f892e51c1f4aa2edf95a01f3edcd45377af0b4663437c03c49e6432e9c4e`。Debug/Release、格式、增强原生编译及六种最终源码启动通过；来源、签名完整性、空权限、AskPass/MIT、测试入口排除和 CRC 核对通过。真实局部 UI 和失败修复证据见 [主题与焦点修复](acceptance/2026-10-14/theme-focus/README.md)。完整原生/辅助访问/性能及正式分发依赖仍未验，继续为未公证 ad-hoc 开发预览。

## 3. 未来可选：Developer ID 与公证

本节只保留未来取得开发者账号后的工具路径，不是当前无账号分发的待办前置项。先在本机配置可用的 Developer ID Application 证书及对应私钥，再配置 `notarytool` 的 Keychain profile。项目不保存 Apple 密码、私钥或公证密钥。

设置以下本地环境变量：

| 变量 | 内容 |
| --- | --- |
| `WEGIT_TEAM_ID` | Apple Developer 团队 ID |
| `WEGIT_SIGNING_IDENTITY` | 已存在证书的完整 `Developer ID Application: …` 名称 |
| `WEGIT_BUNDLE_ID` | 可省略；默认并校验正式标识 `com.willxue.wegit` |
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

仓库 [WeOpen/WeGit](https://github.com/WeOpen/WeGit) 已于 2026-10-16 按用户授权设为 public。[PR #10](https://github.com/WeOpen/WeGit/pull/10) 已合并 Issue/PR、托管 macOS 27 CI、元数据初始化和 Draft Release 框架；[PR #14](https://github.com/WeOpen/WeGit/pull/14) 已修复托管测试调度及工具链输出问题，[main 复验全绿](https://github.com/WeOpen/WeGit/actions/runs/38881671955)，保留失败回合。

常规 PR/main 在 GitHub `xcode-27` 托管 arm64 VM 运行，不再等待自托管 Runner。main 要求 PR policy、Repository policy、Native macOS，管理员也受约束；禁止强推/删除、要求会话解决、只允许 Squash。默认 GITHUB_TOKEN 只读，不允许 Actions 自行批准 PR，action 固定 SHA，checkout 不保存凭据。

完整 UI、辅助访问和 Release 性能单独由 `Full acceptance` 手动 workflow 在 main 的专用交互 Runner 执行，标签为 `wegit-macos27` / `wegit-interactive`，120 分钟、串行资源锁。该专用 Runner 仍未配置；不能把常规构建通过当作完整验收通过。

`Draft release` 手动解析已有 tag，检查同一 SHA 的 main CI；稳定标签另要求同一 SHA 的完整验收成功，随后重新构建显式 `--adhoc` 正式标识制品、验证清单/校验和并只创建草稿。干净机器、Beta 和最终公开发布由维护者核对，网站只引用同一版本资产。操作与限制见 [GitHub workflow 方案](GITHUB_WORKFLOW.md)。

当前应用、品牌和双语改动已通过 [PR #15](https://github.com/WeOpen/WeGit/pull/15) 合并并关闭 Issue #12；[对应远端 CI](https://github.com/WeOpen/WeGit/actions/runs/38924928448) 两套 Git 各 183 项、原生专项与构建通过。每个最终安装包仍须绑定版本、Bundle ID、实际签名/公证状态、提交与来源摘要，源码变化后重新构建。

## 5. Beta 与正式发布门槛

- 在干净的目标系统上，通过实际 HTTPS 下载同一版本化 ad-hoc／未公证包，验证校验、解压/安装、首次系统提示、用户信任选择、打开仓库和完整日常流程。
- 使用获准的测试账号验证 GitHub/GitLab 与通用 Git 服务的 HTTPS/SSH；不把测试凭证加入仓库。
- 获得真实 Beta 用户反馈，记录复现、影响、修复与回归；目前未发送邀请或收集反馈。
- 完成最小窗口、浅色/深色、键盘、VoiceOver 与性能验收。
- 完成公开可访问的 GitHub 下载渠道及项目网站，版本说明、未公证状态、校验和、已知限制、帮助入口与首版数据迁移策略完整后，再发布经过验证的同一份包。

应用默认不上传仓库数据。诊断摘要由用户主动导出，包含版本和命令结果，不包含代码、Diff、提交消息、仓库路径或凭证。Beta 反馈优先引用该摘要和可复现步骤。

## 6. 开发预览的数据位置

最近仓库记录保存在专属本机数据库 `~/Library/Application Support/WeGit/Repositories.store`，不使用 CloudKit。此前默认 SwiftData 数据库未被移动或删除；上次仓库仍可恢复，其他旧最近条目可重新打开添加。

草稿和页面偏好按仓库实体记录。旧版按路径保存的草稿保留，可在提交设置中明确核对后恢复。开发 Bundle ID 与将来的正式 Bundle ID 使用不同偏好域，正式交付前应单独验证开发预览数据的导入方案；首次正式发布不存在既有正式版本的数据库迁移。

侧栏布局与快捷面板调整当轮的开发包为 `.build/releases/package-Hna4A9/WeGit-0.1.0-development.zip`，SHA-256 `0c4d33e2b17b0dd0399a4082ee5a6b7cc9405752309e291763cecc33c06ef2e3`，应用摘要 `4d8d4d26236a88a7188a16401e372187352b7470bf97e7b727bc517fc55cec07`。普通 Release 来源、签名、空权限、AskPass/MIT、测试入口排除及 CRC 通过，实际恢复原仓库/History/Inspector 关闭通过；Debug/Release/格式/原生编译和六种恢复启动通过。系统菜单栏实际对比度、完整 XCTest/辅助访问/最终矩阵与性能及正式分发继续待验，详见 [侧栏与快捷面板调整](acceptance/2026-10-14/sidebar-layout/README.md)。

2026-10-15 主题与悬浮卡片修复当轮的开发包为 `.build/releases/package-C653bx/WeGit-0.1.0-development.zip`，SHA-256 `ec3e23b0c11bb5ab31c2d0cdb07f1f29cad07bf3b149e59ec82b1130c734e592`，应用摘要 `dbf169442292508368c91345850ea186b69777de516be7cdc1032fe2690cc34f`。Debug/Release/格式/原生回归编译、六种恢复启动及普通包恢复原用户工作区通过，包来源/签名/空权限/AskPass/MIT/测试入口排除/CRC 通过。实际系统明暗变化与显式主题、草稿、Add 有证据，原 Auto 配置与应用偏好已恢复。完整自动化、辅助访问、矩阵与性能及正式签名公证仍未验，见 [主题与悬浮卡片修复](acceptance/2026-10-15/theme-footer/README.md)。

2026-10-15 小写标识与 Diff 边界修复后的最新开发包为 `.build/releases/package-MXaett/WeGit-0.1.0-development.zip`，SHA-256 `707c83bc305fe7a11639a093a7bfb01656aaef6230a006892078d234a14dad77`，应用摘要 `861bbdd36a693f8914992c42a01ace7e72acd158c628078edf09ccdc29f99f17`。当前开发标识 com.willxue.wegit.development，正式默认与校验标识 com.willxue.wegit；旧域一次迁移，历史包/回执保留原标识。两套核心各 176 项、迁移 15 项、构建/格式/编译、六种启动及真实新域首次/再次启动通过，来源/签名/权限/测试入口排除/CRC 通过。仍为未公证 ad-hoc 开发预览，完整分发验收未完成，见 [标识迁移与 Diff 边界](acceptance/2026-10-15/bundle-layout/README.md)。

2026-10-15 侧栏蓝色与点击区域调整后的最新开发包为 `.build/releases/package-TUUrjW/WeGit-0.1.0-development.zip`，SHA-256 `224932210a6ed833b59ea84d7963093b33863080db09af82ec2a97a8cff08d3b`，应用摘要 `4a9ed24aaee2d3b39412d9a0a2aaeb8ae444d471c96e60c093d268adc105ac2d`。严格格式、Debug/普通 Release、六种恢复启动、实际浅深色行尾点击与快捷图标动作、原用户工作区恢复通过。核心输入不变，本轮未重跑核心与完整 XCTest。包来源、签名完整性、空权限、AskPass/MIT、测试入口排除和 ZIP CRC 通过；仍为未公证 ad-hoc 开发预览，完整发布门槛保持未完成，见 [侧栏蓝色与点击区域验收](acceptance/2026-10-15/sidebar-blue/README.md)。

2026-10-15 历史/分支页面修复后的最新开发包为 `.build/releases/package-Es87M6/WeGit-0.1.0-development.zip`，SHA-256 `0e0e1ad2a2c93442d7e919c7128c9bf91fa2dda0ba66f1f95f5d0bcfd416284b`，应用摘要 `37b9029e85d18f84c620c4037d26eff6a83001952223e3cd99c560e96b0b8b2f`。浅深色阅读底色、分支左侧输入、长名称、面板开关和 980/1292 pt 恢复宽度有实际证据；格式、Debug/Release、原生回归编译与六种恢复启动通过。来源、签名、空权限、AskPass/MIT、测试入口排除及 CRC 通过，普通 Release 恢复用户分支页。完整 XCTest、辅助访问/性能及正式分发仍待验，仍为未公证 ad-hoc 预览，见 [历史与分支页面修复验收](acceptance/2026-10-15/history-branches/README.md)。

2026-10-15 中英文与提交按钮统一后的最新开发包为 `.build/releases/package-l8oeCo/WeGit-0.1.0-development.zip`，SHA-256 `2aea6b787b7a90301023e54dde83e55e7ac5ef0846d2c434a7a1804a53a3dbf9`，应用输入摘要 `ca42e894d595190faf89793808f857b58a95159fdbb958d2287a8c76a23476d0`。两套 Git 各 182 项/32 套、严格格式、迁移 15 项、Debug/普通 Release、原生 UI 回归编译及 6 种恢复启动通过；中英文切换、Unicode/草稿保留、最小窗口与英文筛选布局有实际证据。包来源、签名、空权限、AskPass/MIT、测试入口排除、双语资源与 CRC 已核对，普通包已恢复用户原工作区。本轮未执行完整 XCTest，仍是未公证 ad-hoc 开发预览，完整辅助访问、矩阵/性能和正式分发继续待验，见 [中英文与按钮统一验收](acceptance/2026-10-15/i18n/README.md)。

2026-10-15 原生菜单语言应用后的最新开发包为 `.build/releases/package-tufzkw/WeGit-0.1.0-development.zip`，SHA-256 `c87fe973135aabf2da03fe8ab2b5fe4e72083310d0828f5cfed3b4eeb5fbb5a5`，应用输入摘要 `60e79ea8cfb5a921256c9a077550fae0c09dc7f33d223353f220f44aec1b13dd`。设置提供“重新启动并应用语言”，实际中英双向重启、系统菜单与草稿恢复通过；两套 Git 各 182 项、格式、Debug/Release、原生 UI 编译与 6 种恢复启动通过。来源、签名、空权限、AskPass/MIT、测试入口排除和 CRC 已核对，普通包以英文恢复用户原工作区。完整 XCTest、辅助访问、最终矩阵/性能及正式签名公证仍待验，仍为未公证 ad-hoc 预览，详见 [菜单语言验收](acceptance/2026-10-15/native-menu-language/README.md)。

2026-10-15 无重启菜单语言切换后的最新开发包为 `.build/releases/package-GQPxL0/WeGit-0.1.0-development.zip`，SHA-256 `33998882235be9e3e035784c078335e4d6eb0c349a18804b9ec68142a3ebdf3f`，应用输入摘要 `3704b58de5d6f2e2a52c9b0709e8d2505476ddccc3116584054395a1bca65fbe`。两套核心各 183 项、27 项原生菜单行为、格式、Debug/Release、原生 UI 编译及 6 种恢复启动通过；实际持续 Git 读取跨语言切换存活、草稿和窗口恢复通过。最终普通包在同一 PID 中完成 English → Follow system，原用户工作区与语言已恢复。来源/签名/空权限/AskPass/MIT/测试入口排除/CRC 通过，仍为未公证 ad-hoc 开发预览。完整 XCTest、辅助访问、最终矩阵/性能及正式分发待验，见 [无重启菜单验收](acceptance/2026-10-15/live-menu-language/README.md)。

## 确认框与 Inspector 修复后的开发包 · 2026-10-15

最新普通 Release 为 `.build/releases/package-36Yu9M/WeGit-0.1.0-development.zip`，SHA-256 `4d1574d123db04fd21db403343d530c76c23319ca2095836aec4ecaf74eff989`，应用输入摘要 `6844a5f7c0cda2aeb7b7693bfed0c8c45529d9803a0f612274bb822403ff646f`。来源回执、签名完整性、空权限、AskPass/MIT、测试入口排除、ZIP CRC 与校验和通过，普通包实际恢复原英文/System/Package.swift/Unified/Inspector 和空草稿。

Debug/Release/格式、27 项菜单行为、原生 UI 编译及 6 种恢复启动通过；核心输入与上轮逐文件一致，本轮未重跑核心。版本仍为 0.1.0、开发标识、ad-hoc 签名且未公证；完整原生/辅助访问/性能及正式分发继续未完成，见 [验收](acceptance/2026-10-15/alert-inspector/README.md)。

## 第二版品牌接入后的开发包（2026-10-16）

最新普通 Release 为 `.build/releases/package-Fg4E0i/WeGit-0.1.0-development.zip`，SHA-256 `fdefc5133bd4cadc058302096e1319242e8f73a112b09fd19f6b329a7e7adc79`，应用输入摘要 `abf032bdab6e609a41ae5710a14a25cc641abe8903bd12c950103e3036e54d32`。来源回执、签名完整性、空权限、AskPass/MIT、测试入口排除、ZIP CRC 与校验和通过，普通包已恢复原中文浅色工作区。第一版 67 个资源及历史包原样保留。

Debug/Release/严格格式、原生编译和 6 种恢复启动通过；核心输入未变，本轮未重跑核心。仍为 0.1.0、开发标识、ad-hoc 签名且未公证；完整验收与正式分发保持未完成，见 [第二版品牌接入验收](acceptance/2026-10-15/brand-v2/README.md)。

## Dock 图标主题同步后的开发包（2026-10-16）

最新普通 Release：`.build/releases/package-0QjAlo/WeGit-0.1.0-development.zip`，SHA-256 `3bdac66d22fa259b210031b6dfab4de15d01c8ebebd0d8f68a0b5b102ff9b1ca`，应用输入摘要 `bcedd0fcf7adfa767783a4e8b91539ab02356fa2448ed7eeaa3091d2bf59164e`。两份主题 ICNS 与源码逐字节一致，来源/签名/空权限/AskPass/MIT/测试入口排除/CRC/校验和通过，普通包恢复原工作区。两套核心各 183 项、16 项图标行为、27 项菜单、构建/格式/原生编译和 6 种启动通过。仍为 0.1.0 ad-hoc 未公证开发预览，完整发布门槛保持未完成，见 [Dock 图标主题同步修复](acceptance/2026-10-16/dock-icon-theme/README.md)。

## 独立自定义主题后的开发包（2026-10-16）

最新普通 Release 为 `.build/releases/package-MlXpuO/WeGit-0.1.0-development.zip`，SHA-256 `94698b5f1e75aac03e976f6cccfe5967225222e9b59988603f35da9927f334ec`，应用输入摘要 `9b8f7f77bc312b804d1d42c9429c695009fad10be91523ab972c8f6622e6ba1f`。来源回执与六种启动输入逐文件相同；签名完整性、空权限、AskPass/MIT、测试入口排除、主题 ICNS 字节匹配、ZIP CRC/校验和通过。两套核心各 183 项、34 项主题、16 项图标、27 项菜单、格式与 Debug/Release/原生编译通过。普通包已恢复原中文/Dark/Split/Inspector 关闭并打开外观设置；未向用户域保存测试主题。

仍为 0.1.0 开发标识、ad-hoc、未公证；未提交或推送，本轮保留所有原始改动。完整原生/辅助访问/最终性能与 Developer ID/干净机器/Beta 仍未完成，见 [原生底色与独立自定义主题验收](acceptance/2026-10-16/custom-themes/README.md)。

## Dock 尺寸与材质修正后的开发包（2026-10-16）

最新普通 Release：`.build/releases/package-mbWTnE/WeGit-0.1.0-development.zip`，SHA-256 `e6ef5c5c0300833c753982b216f849f98dd40f335ce35787b2e9205152d0450f`，应用输入摘要 `6fbcded9970a9bb44ea7383051f84a3f0cb515e0934f11e2494fa2990c2acbda`。18 项图标行为/尺寸、47 PNG、格式、Debug/Release、来源/资源/签名/空权限/AskPass/MIT/测试入口排除/ZIP CRC 通过，实际普通包已打开并保留本轮用户当前工作区。仍为 0.1.0 ad-hoc 未公证开发包；完整原生、辅助访问、性能与正式发行未完成，见 [Dock 比例与材质修正](acceptance/2026-10-16/dock-scale-material/README.md)。
