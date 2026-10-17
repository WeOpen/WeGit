# Git 兼容性与测试隔离

> 总览更新：2026-10-16；历史验证记录保留原日期。运行环境：macOS 27.0.1（26A434）、Xcode 27、Swift 6.4、Apple Silicon Mac16,8。

## 1. 最低能力要求

WeGit 要求 **Git 2.46 或更新版本**。启动时除版本号外，还实际检查以下能力：

- `GIT_CONFIG_SYSTEM`、`GIT_CONFIG_GLOBAL` 和 `GIT_CONFIG_COUNT` 的读取与覆盖顺序。
- 空 `remote.<name>.url` / `pushurl` 值能清除继承的地址列表，使一次推送只使用选定目标。

探针仅在私有临时目录中创建配置，通过 `config --get-all` 和 `remote get-url` 读取；不连接远端，不改写用户配置。版本号符合但能力不符的可执行文件同样被拒绝。

此前的 Git 2.31 声明不准确，现已撤回。2.31.8 实测忽略全局/系统配置隔离变量，不支持 SSH 签名，也不具备当前远端实现所需的 URL 列表重置行为。Git 官方 v2.45.0 与 v2.46.0 的 `remote.c` 对比显示，该重置行为从 2.46 起具备；最低版本以完整实际回归补充验证。

## 2. 已执行矩阵

| 可执行文件来源 | 版本 | 范围与结果 |
| --- | --- | --- |
| 系统 `/usr/bin/git` | Apple Git 2.54.0 | 183 项核心测试、32 个套件全部通过；最新应用已在 PR #15 远端验证 |
| Git 官方源码，项目目录内独立编译 | 2.46.0 | 同一套 183 项核心测试、32 个套件全部通过 |
| Git 官方源码，项目目录内独立编译 | 2.31.8 | 不受支持；隔离修复后在任何仓库命令前拒绝，配置文件校验值保持一致 |
| Xcode 内 Git | 与当前 Xcode 配套 | 用于原生 UI 夹具，独立执行配置隔离探针；UI 结果见开发记录 |
| Homebrew Git / GPG | 当前未找到 | 尚未验证，不能用其他来源的结果代替 |

核心矩阵覆盖真实临时仓库、SSH 临时密钥签名、Hooks、配置编辑、差异写入、历史与分支、多个本地 Bare Remote、Lease、Pull/Rebase 冲突与取消。GitHub HTTPS/SSH 的真实写入已通过，见第 6 节；GitLab、交互认证完整矩阵、GPG、干净机器与当前无账号正式安装验收仍需补齐。

最新系统 Git 日志：`/tmp/wegit-v1-status-core-system-final.log`；2.46 日志：`/tmp/wegit-v1-status-core-git246-final.log`。此前 156 项的地址固定回归记录分别为 `/tmp/wegit-system-git-pinning-full.log`、`/tmp/wegit-git246-full.log`；不受支持版本的拒绝记录为 `/tmp/wegit-git231-isolation-rejection.log`。日志路径为本机验证产物，并非随仓库分发的测试数据。

## 3. 复现与隔离约束

```bash
# 默认使用系统 Git
swift test

# 仅测试进程使用指定的独立 Git；不修改 PATH 或用户配置
WEGIT_TEST_GIT="$PWD/.build/toolchains/git-2.46.0/install/bin/git" swift test
```

`WEGIT_TEST_GIT` 仅由测试辅助代码读取，生产应用不读取此变量。独立工具链放在被忽略的 `.build/toolchains/` 下；不替换系统 Git、不全局安装，也不改写 `HOME`。

核心测试的每个 Git 引擎默认使用 `/dev/null` 隔离全局和系统配置。所有夹具命令在首次执行前共享一个只读能力探针，失败结果也会缓存，避免并发测试绕过检查。全局配置编辑测试必须显式提供刚创建的私有文件；测试执行器将 `--global` 转成 `--file <私有文件>`，并检查目录身份及文件类型。缺少文件、文件被换成符号链接或请求系统配置时，直接拒绝执行。原生 UI 夹具使用统一执行器，同样先验证隔离，并禁止全局/系统作用域写入。

切换 Git 版本时，验证前后比较实际全局配置文件的校验值和相关键值；不要在隔离不确定的情况下继续整套测试。

2.46.0 工具链来源记录：

| 项目 | 值 |
| --- | --- |
| 官方仓库 | `https://github.com/git/git` |
| Tag 对象 | `75a062f03c1c151fb46427b44cc0c7d89a5fc73d` |
| 提交 | `39bf06adf96da25b87c9aa7d35a32ef3683eb4a4` |
| 源码压缩包 SHA-256 | `7cb9a19f08b44935fc0b6afc6fef1ae172a2e6113d704d5e867a2e095c122386` |
| 本地记录 | `.build/toolchains/git-2.46.0/source-provenance.json` |

该工具链用于最低版本的本地回归，未作为应用依赖或分发内容。用户应优先使用其安装渠道维护的更新版本。

## 4. 已确认缺陷与修复

| 问题 | 影响与修复 | 验证 |
| --- | --- | --- |
| 旧 Git 忽略配置隔离 | 旧测试误改全局提交者姓名和默认分支；已恢复既有姓名及用户确认的 `main`。增加只读探针、私有文件写入与路径检查 | 隔离回归通过；2.31.8 在夹具命令前拒绝；后续两个受支持版本完整测试前后全局配置一致 |
| 确认后 URL 重写变化 | 临时仓库测试复现 Push/Pull 可被重定向；执行时使用每次命令独立的别名，单次解析到确认时的有效地址 | 在实际 Push/Fetch 前注入重写配置，操作仍只使用确认的仓库 |
| 有效地址被二次重写 | Lease 查询拒绝原本合法的单次重写配置 | Lease 查询与写入使用相同的固定方式，双重匹配规则回归通过 |
| 地址列表清空与特殊路径 | 正确处理已有配置的空值重置；本地地址含换行时转为编码后的 `file://` 地址 | 多地址、清空后回退、绝对/相对换行路径回归通过 |
| 推送回执不完整 | 远端已更新后仍可能超时、取消或报告 remote failure。保留原计划并提供只读核对；重启后校验仓库实体与地址指纹，凭据/查询参数不进入保存记录 | 两套 Git 下实际更新后模拟丢失回执、目标变化及相对路径移动；核对不增加 Push 或 Commit 次数 |

以上错误目标测试只操作本次创建的临时仓库，没有向项目远端写入。它们是发布前必须通过的回归条件，不能通过跳过旧版本测试或放宽断言来标记完成。


2026-10-11 的完整回归日志为 `/tmp/wegit-v1-status-core-system-final.log` 和 `/tmp/wegit-v1-status-core-git246-final.log`。新增原文选区、磁盘块跳转与复制、UTF-8 截断及首批语言高亮覆盖通过。Homebrew 5.1.6 更新后仍无法为本机 macOS 27 安装 Git/GPG，实际错误是 `unknown or unsupported macOS version: :dunno`；不修改系统版本来制造渠道兼容结果。

## 5. 获准 GitHub 仓库的只读传输（2026-10-11）

仓库 `WeOpen/WeGit` 的 HTTPS 和 SSH 只读引用查询均成功。使用实际编译的 `GitEngine` 再次验证两个协议；`CloneCoordinator` 完成 HTTPS 克隆，`RepositoryService.status()` 核对空工作区且 HEAD 尚不存在。测试当时远端没有提交，因此这不替代有提交后的 Fetch/Push、Lease、分支写入、SSH Clone 或交互认证验收。

HTTPS 使用私有 0600 配置文件复用已有 gh 凭据辅助；SSH 使用已有身份和 `StrictHostKeyChecking=yes`，没有新增主机信任或密钥。测试目录在完成后清理，用户 Git 配置校验值保持原基线。临时验收源码与结果为 `/tmp/wegit-github-read-acceptance.swift`、`/tmp/wegit-github-read-acceptance.log`，调用现有领域服务，不增加生产接口。

## 6. 获准 GitHub 仓库的完整传输验收（2026-10-11）

在用户授权的 `WeOpen/WeGit` 私有仓库中，HTTPS 与 SSH 均通过现有 GitEngine、CloneCoordinator 与 RepositoryService 完成：独立 UUID 分支首次 Push 与原计划核对、Clone、再次 Push、Fetch、仅快进 Pull，以及过期 Force With Lease 拒绝并保留另一工作区的提交。只有本轮拥有的两条引用被清理，默认 main 在前后均为 c99aa80；最终只读 API 再次确认仅剩 main。完整成功记录见 [github-transports.log](acceptance/2026-10-11/github-transports.log)。

2026-10-12 图标专项：macOS 27.0.1 / Xcode 27.0 / Icon Composer 27.0 下，Default/Dark 渲染、Debug/普通 Release 的图标编译及关于窗口显示通过。Assets.car 包含 Aqua、DarkAqua 和系统生成的 Tintable 堆栈；当前专项只验收 Default/Dark，不宣称已人工验收 Clear/Tinted。系统外观偏好未变化，其他 Git/服务环境的待验状态保留。见 [app-icon.json](acceptance/2026-10-12/app-icon.json)。

2026-10-12 界面美化：同一本机工具链下构建与两套 Git 核心通过，隔离手动检查了浅深色、统一/分栏、最小窗口及两种密度。系统显示辅助选项、其他机器/工具链与完整原生套件没有新增通过结论；未修改系统保护或全局 Git 配置。原生探针仍在自动化模式初始化时失败。记录见 [INTERFACE_POLISH.md](INTERFACE_POLISH.md)。

直连 GitHub 的连接超时回合保留在本机日志中。成功回合在临时私有配置中复用当时系统已启用的本地 HTTP/SOCKS 代理；没有修改系统代理或用户 Git 配置。SSH 保持 BatchMode 与 StrictHostKeyChecking=yes，未增加密钥或主机信任。HTTP 保持 TLS 验证。全局配置 SHA-256 与既有基线一致。该结果仅覆盖 GitHub 和现有身份，不能替代 GitLab、陌生主机、交互认证或其他网络条件。

2026-10-13 启动恢复专项：同一 macOS 27.0.1 / Xcode 27.0 环境中，系统 Inspector 与嵌套 HSplitView 的窗口约束循环已在最小应用和真实保存状态下复现。原生辅助分栏修复后，两套 Git 核心各 176 项通过；普通 Debug / Release 启动、6 种隔离恢复状态和窄窗口有实际证据。用户保存视图、非布局偏好和全局 Git 配置已核对，测试域与原窗口尺寸已恢复。新源码摘要 `4690bf492189d72babe57dec7f24a29cf2ad62e7d9b666baf90434fd2a2da3a4`；完整 XCTest、其他机器和缺失 Git/服务环境继续待验，见 [启动恢复验收](acceptance/2026-10-13/inspector-startup/README.md)。

2026-10-13 第二轮界面：macOS 27.0.1 / Xcode 27.0 下，新组件在浅深色、深色最小窗口与紧凑密度经过实际检查。⌥↩ 原生换行、⌘↩ 多段消息提交、草稿恢复和实际计数通过；两套 Git 核心各 176 项通过。新增代码不改变 Git/SSH/Helper 契约；正常全局 Git 配置摘要不变，私有测试域、原窗口及分栏状态已恢复。其他平台/服务及完整 XCTest 保留待验，来源 `43c855caf7d1396f75649abec8375d373beeba3dd6bd60bfb55c4cf86a372f0b`，见 [第二轮界面优化](acceptance/2026-10-13/interface-identity/README.md)。

2026-10-13 顶部/菜单栏：同一 macOS 27.0.1 / Xcode 27.0 下，原生状态项、弹层、工具栏窗口宽度观察、设置开关和重开行为有实际证据。普通 Release 恢复正常仓库及 Inspector 通过；Git 领域服务未改变，两套 Git 各 176 项通过。系统状态栏鼠标点击受当前工具宿主捕获限制，未冒充通过；其它环境及完整原生回归继续待验，见 [工具栏与菜单栏验收](acceptance/2026-10-13/toolbar-menu-bar/README.md)。

## 液态玻璃组件核对 · 2026-10-13

应用摘要 `b3d057695e3c4f5180aeebc8b71016cb35f3c6c1a4b823862492355fc9045adb` 在 macOS 27.0.1/Xcode 27.0 arm64 下完成 Debug/Release 与原生回归编译，两套 Git 各 176 项通过；原生实际核对浅深色、980×693 pt 恢复窗口、六类设置 Tabs、搜索和方向键。没有新增其他系统/架构环境的通过结论，Homebrew/GPG、GitLab 和其余缺失环境维持待验；详细证据见 [液态玻璃控件验收](acceptance/2026-10-13/glass-controls/README.md)。

## 原生面板配色 · 2026-10-14

最终摘要 `b5b9e32eeb997e1e091c509f6895fb3a6c1eb20601e16e602ef83c4fbcf0d866` 在 macOS 27.0.1/Xcode 27.0 arm64 下构建 Debug/Release 并通过六种启动；实际核对浅深色检查器、工作区和局部面板。Git 核心/构建输入与上轮核心通过的版本一致，本轮没有重跑核心或其他环境矩阵。其他系统/架构、Homebrew/GPG、GitLab 和缺失环境维持待验，见 [原生面板配色验收](acceptance/2026-10-14/native-surfaces/README.md)。

## 主题与焦点修复 · 2026-10-14

macOS 27.0.1/Xcode 27.0 arm64 的 Debug/Release、增强原生回归编译及最终源码六种启动通过。实际验证鼠标/键盘 Tabs、浅深色/系统模式、单个圆形侧栏及快捷键；未新增其他环境通过结论。完整原生、矩阵和缺失环境维持待验，源码 `26d0f892e51c1f4aa2edf95a01f3edcd45377af0b4663437c03c49e6432e9c4e`，见 [主题与焦点修复](acceptance/2026-10-14/theme-focus/README.md)。

## 侧栏与快捷面板调整 · 2026-10-14

在 macOS 27.0.1 / Xcode 27.0 arm64 验证源码 `4d8d4d26236a88a7188a16401e372187352b7470bf97e7b727bc517fc55cec07` 的 Debug、增强原生编译及六种恢复启动。当前 SwiftUI 侧栏 item 元数据由公开 NSToolbar API 读取并保留原生布局；匹配失败时保留系统按钮，其他 SwiftUI/系统版本仍待验。其他环境结论不扩展，见 [侧栏与快捷面板调整](acceptance/2026-10-14/sidebar-layout/README.md)。

## 系统主题与底部卡片 · 2026-10-15

macOS 27.0.1 / Xcode 27.0 arm64 的源码 `dbf169442292508368c91345850ea186b69777de516be7cdc1032fe2690cc34f` 构建与六种恢复启动通过。显式 Light/Dark/System 及真实系统明暗变化实际验证，原 Auto 恢复核对。其他系统、架构和缺失环境不扩展通过结论，见 [主题与悬浮卡片修复](acceptance/2026-10-15/theme-footer/README.md)。

## 命名空间与分栏补偿 · 2026-10-15

macOS 27.0.1 / Xcode 27.0 arm64 下验证新小写前缀及旧域一次迁移。Apple Git 2.54 与 Git 2.46 各 176 项通过，六种新标识启动通过；当前正式/开发标识分别为 com.willxue.wegit / com.willxue.wegit.development，旧包和历史证据维持原标识。缺失环境和新源码完整矩阵仍待验，见 [标识迁移与 Diff 边界](acceptance/2026-10-15/bundle-layout/README.md)。

## 侧栏命中与快捷图标留白 · 2026-10-15

macOS 27.0.1 / Xcode 27.0 arm64 下实际验证浅深色蓝色侧栏、A/B 仓库整行空白切换和原生快捷面板。Debug/普通 Release、格式及六种恢复启动通过；核心输入与上一轮一致。其他系统、架构、完整矩阵维持待验，见 [侧栏蓝色与点击区域验收](acceptance/2026-10-15/sidebar-blue/README.md)。

## 历史与分支页面边界 · 2026-10-15

macOS 27.0.1 / Xcode 27.0 arm64 下核对原生 Table/List 背景、分支页与侧栏边界及 Inspector 开关。浅深色与 980 × 693 / 1292 × 693 pt 恢复尺寸有实际证据；其他系统/架构与完整矩阵不扩展通过结论，见 [历史与分支页面修复验收](acceptance/2026-10-15/history-branches/README.md)。

## 中英文语言环境 · 2026-10-15

macOS 27.0.1 / Xcode 27.0 arm64 下验证简体中文、English 与跟随系统的实际切换，英文原生菜单重开、深浅色及 980/1292 pt 恢复宽度；两套 Git 各 182 项通过。未知系统语言回退英文，有支持的后续语言偏好时采用匹配语言。其他平台/架构与完整阅读矩阵仍待验，见 [按钮与中英文本地化验收](acceptance/2026-10-15/i18n/README.md)。

### 2026-10-15 原生菜单语言

macOS 27 当前交互会话实际中→英→中应用通过，含 File/Edit/View/Window/Help 与 Close/Copy 等系统项目；原生设置窗口标题也随进程语言变化。普通界面即时切换，系统菜单须经设置中的重启入口应用。系统外部服务/设备名称保留原文。详见 [验收](acceptance/2026-10-15/native-menu-language/README.md)，其他平台/服务兼容性状态保持原记录。

### 2026-10-15 无重启菜单语言

macOS 27.0.1 / Xcode 27.0（27A266a）下，中文系统进程中应用菜单可在中英间即时切换，含系统窗口排列项目；名称数据保留原文。普通界面和设置标题同步，移除重启应用方案。文件选择器、字符面板、外部服务等系统提供的界面仍可能沿用系统/启动语言；未验证其他系统版本。见 [验收](acceptance/2026-10-15/live-menu-language/README.md)。

## 原生确认框与 Inspector · 2026-10-15

macOS 27.0.1 / Xcode 27.0（27A266a）arm64 下实际核对浅深色 NSAlert 图标/主题、两主题底色、取消与确认重置。普通 Release 恢复原英文/System 工作区，6 种隔离恢复启动通过。未验证其他系统或增强对比度的实际切换，缺失环境状态保留，见 [验收](acceptance/2026-10-15/alert-inspector/README.md)。

## 第二版原生图标（2026-10-16）

macOS 27.0.1 / Xcode 27.0（27A266a）arm64 下验证第二版 Icon Composer 文档编译，Assets.car 含 Aqua、DarkAqua 与 Tintable 条目。实际浅深色界面、快捷面板、关于图标及普通包恢复通过；没有新增其他系统/架构的通过结论。系统图标外观选择与应用内容主题分别处理，见 [第二版品牌接入验收](acceptance/2026-10-15/brand-v2/README.md)。

## Dock 主题同步（2026-10-16）

macOS 27.0.1 / Xcode 27.0 arm64 下验证 AppKit applicationIconImage、应用 Light/Dark/System 和实际原生面板；System 明暗通知检查只改变检查进程自身外观。Apple Git 2.54.0 与独立 2.46.0 各 183 项通过。Finder/退出后的图标仍由系统样式管理，未扩展其他系统通过结论，见 [Dock 图标主题同步修复](acceptance/2026-10-16/dock-icon-theme/README.md)。

## 原生表面与自定义配色（2026-10-16）

macOS 27.0.1 / Xcode 27.0（27A266a）arm64 下验证内置 Light/Dark 与独立 Custom 即时切换、英文编辑器、原生颜色井、JSON 往返及持久化。Custom 明暗基底控制系统控件和运行图标，系统文件面板保留系统外观/语言。两套 Git 各 183 项与六种恢复启动通过；未扩展其他系统/架构或 Homebrew/GPG/GitLab 通过结论，见 [原生底色与独立自定义主题验收](acceptance/2026-10-16/custom-themes/README.md)。

## Dock 静态 ICNS 画布（2026-10-16）

macOS 27.0.1 / Xcode 27.0 arm64 下对比本机 Finder/Notes/Terminal 的静态图标底板 206/256；修正后运行图标 824/1024、原生编译图标 206/256。18 项图标生命周期/尺寸检查和构建通过；系统 Dock UI 访问超时，未扩展其他系统或动态反光效果通过结论，见 [Dock 比例与材质修正](acceptance/2026-10-16/dock-scale-material/README.md)。

最新应用的两套 Git 和原生专项/构建证据见 [PR #15 接入记录](acceptance/2026-10-16/application-integration/README.md)。没有新增 Homebrew/GPG/GitLab 或其他系统的通过结论。

## 隔离的 OpenPGP 验证入口（2026-10-17）

新增 `scripts/verify-gpg-compatibility.sh`，分别使用选中 Xcode 的实际 Git 与已安装的 Homebrew Git，通过现有 `GitEngine` / `RepositoryService` 执行真实签名、核对指定密钥、无效密钥拒绝及 HEAD/暂存内容保留、仓库覆盖和移除后恢复继承。每次使用独立 `mkdtemp`、Git 全局文件和 GNUPGHOME；结束只停止该目录的 GnuPG 服务并删除本次夹具，不改 HOME、用户密钥或原 Git 配置。源码摘要、实际 Git/GPG 版本、行为与清理结果独立归档。

常规 CI 增加串行签名与完整核心回归步骤，要求镜像已有 Homebrew Git/GnuPG；缺失即报错，不安装、不回退为 Apple Git 或 SSH 签名。核心回归通过现有 WEGIT_TEST_GIT 选择实际 Homebrew Git。仅编译可运行 `scripts/verify-gpg-compatibility.sh --compile-only`，不能记作签名通过。当前先记录实现与编译，远端实际行为结果待补。

该入口使用无口令的临时测试密钥，不覆盖真实 Pinentry、硬件密钥、账号或原生 UI。依据 [GnuPG 批量密钥接口](https://gnupg.org/documentation/manuals/gnupg/OpenPGP-Key-Management.html)；托管镜像软件清单只是前置参考，实际版本以本轮结果为准。相关完整矩阵保持各自范围。
