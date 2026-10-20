<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/wegit-v2/mark-dark.png">
    <img src="branding/wegit-v2/mark.png" width="104" height="104" alt="WeGit 标志">
  </picture>
  <h1>WeGit</h1>
  <p><strong>为 macOS 打造的原生 Git 工作台。</strong></p>
  <p>清晰阅读改动，从容整理提交，让日常 Git 操作自然顺手。</p>
  <p>
    <img src="https://img.shields.io/badge/status-public_release-green?style=flat" alt="公开版本">
    <img src="https://img.shields.io/badge/version-1.0.0-blue?style=flat" alt="版本 1.0.0">
    <img src="https://img.shields.io/badge/macOS-27%2B-111111?style=flat&amp;logo=apple&amp;logoColor=white" alt="macOS 27 或更新版本">
    <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat&amp;logo=swift&amp;logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/badge/Git-2.46%2B-F05032?style=flat&amp;logo=git&amp;logoColor=white" alt="Git 2.46 或更新版本">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3DA639?style=flat" alt="MIT 许可证"></a>
  </p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
  <p><a href="https://github.com/WeOpen/WeGit/releases">📦 版本下载</a> · <a href="https://github.com/WeOpen/WeGit/issues">🐛 问题反馈</a> · <a href="docs/README.md">📚 项目文档</a></p>
</div>

---

## 👋 认识 WeGit

WeGit 使用 SwiftUI 构建，围绕日常开发流程组织界面：阅读差异、选择改动、暂存提交、浏览历史、管理分支与同步远端。

它复用已有的 Git 安装、配置、Credential Helper 和 SSH Agent。原生窗口、键盘快捷键、菜单栏快捷面板，以及浅色、深色和独立自定义主题，让 Git 工作流融入 macOS。Git 核心没有第三方运行时依赖。

> **WeGit 1.0.0** · [下载](https://github.com/WeOpen/WeGit/releases/tag/v1.0.0) · [项目网站](https://weopen.github.io/WeGit/zh/)。ad-hoc 签名，未经 Apple 公证；辅助功能暂缓验收，其他未完成验证见[版本说明](docs/releases/v1.0.0.md)。

## ✨ 核心功能

| | 可以完成的工作 |
| --- | --- |
| 📂 **仓库管理** | 打开、克隆或拖入仓库，在最近记录与收藏之间切换。 |
| 🔍 **差异阅读** | Unified / Split、语法高亮、词级差异、差异块导航、上下文展开，以及保留原文的选择与复制；大差异采用磁盘快照分页。 |
| 🧩 **整理提交** | 按文件或差异块暂存、取消暂存；确认后丢弃改动，支持 Amend 和按仓库保存的提交草稿。 |
| 🌿 **分支与历史** | 分页提交图、提交文件比较、复制 SHA、从提交创建分支和 Detached HEAD 检出。 |
| 🔄 **同步与冲突** | 明确目标的 Fetch / Pull / Push，选择 Merge、Rebase 或仅快进 Pull，继续或中止支持的冲突流程。 |
| 🛡️ **操作恢复** | 拒绝过期改动、协调仓库任务、失败时保留草稿，推送结果未知时先核对再重试。 |
| 🎨 **外观与配色** | 原生浅深色，或独立保存的 17 角色自定义配色；支持实时预览、对比度提示和 JSON 导入导出。 |
| ⌨️ **原生交互** | 键盘操作、仓库搜索、命令面板、可调整分栏与菜单栏快捷访问。 |
| 🌍 **双语界面** | 跟随系统、简体中文和 English 即时切换，无需重启。 |

范围与证据见 [产品需求](docs/WeGit_PRD.md)、[界面记录](docs/INTERFACE_POLISH.md)及[兼容性记录](docs/COMPATIBILITY.md)。功能已实现与发布验收已完成分别记录。

**开发分支 · 2026-10-20：** v1.1 M0 基线新增可折叠更改分组、暂存复选框、文件夹显示方式、多差异块内存阅读器的可点击变更地图、成对面板底色与 Pull/Push 上游提交数。这些改动仍待 PR/CI 集成，未包含在已发布的 1.0.0 下载包中；使用方法和验证范围见[界面记录](docs/INTERFACE_POLISH.md#v11-m0-baseline--2026-10-20)。

## 🖥️ 环境要求

- **macOS 27 或更新版本**。当前构建与验收覆盖 **Apple Silicon / arm64**。
- **Git 2.46 或更新版本**。启动时实际检测配置隔离与远端地址处理能力。
- 源码构建需要 **Xcode 27** 和 macOS 27 SDK；本机已验证 Swift 6.4 工具链。
- **XcodeGen 2.43+**：普通构建可选，修改 `project.yml` 后重新生成工程时需要；仓库已包含生成的 Xcode 工程。

## 📦 下载与分发

WeGit 通过 **GitHub Releases 和项目网站**分发，不计划上架 Mac App Store，也不采用 TestFlight。

下载 [WeGit 1.0.0](https://github.com/WeOpen/WeGit/releases/tag/v1.0.0)，同时获取 ZIP、SHA-256 与来源清单。网站引用同一份 GitHub 版本化资产。安装、数据与回退说明见[版本说明](docs/releases/v1.0.0.md)。

项目目前没有 Apple Developer Program 账号。公开版本使用 **ad-hoc 签名，未经 Apple 公证**。ad-hoc 签名不代表经过验证的开发者身份，macOS 可能拦截下载后的应用。对于自行确认可信的应用，可参考 [Apple 的安全打开说明](https://support.apple.com/zh-cn/102445)。在干净 Mac 上通过实际下载进行安装的闭环仍待验证。

## 🚀 构建与运行

```bash
git clone https://github.com/WeOpen/WeGit.git
cd WeGit
scripts/build.sh Debug
open .build-app/Build/Products/Debug/WeGit.app
```

也可以使用 Xcode 打开 `WeGit.xcodeproj`，选择 **WeGit** scheme 后运行。本地 ad-hoc 构建不需要 Developer ID 凭据。

生成本地 Release 预览包：

```bash
scripts/build.sh Release
scripts/package-release.sh --preview
```

打包脚本核对构建来源回执、AskPass、许可证、签名完整性和测试入口排除，输出 ZIP、校验和与 manifest，保存到 `.build/releases/package-*`。该命令只生成本地开发包，不会发布 GitHub Release。

## ⌨️ 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 打开仓库 | `⌘O` |
| 更改 / 提交历史 / 分支 | `⌘1` / `⌘2` / `⌘3` |
| 刷新 | `⌘R` |
| 提交已暂存内容 | `⌘↩` |
| 打开 Pull / Push 目标表单 | `⌘⇧L` / `⌘⇧U` |
| 菜单栏快捷面板 | `⌘⇧M` |
| 设置 | `⌘,` |

🌍 在 **设置 → 通用 → 界面语言** 切换语言。仓库名称、路径、分支、提交消息、代码和补丁保持原文。

🎨 在 **设置 → 外观 → 编辑自定义主题…** 创建完整配色方案，内置浅色与深色保持不变。

## 🧪 开发与验证

```bash
# 核心单元测试与使用真实临时仓库的集成测试
swift test

# 严格格式、迁移/本地化检查、核心测试及 Debug 构建
scripts/verify.sh

# 增加原生 UI、图标/菜单/主题检查及辅助访问审查
# 需要可工作的交互式 macOS 登录会话
scripts/verify.sh --ui
```

M0 之前的历史核心验证在 **Apple Git 2.54.0** 和私有构建的 **Git 2.46.0** 下分别通过 **183 项测试 / 32 个套件**。2026-10-18 记录包含 **278 项主题检查（含 216 个角色/背景对比度色对）**，此前另有 **18 项图标行为、27 项原生菜单行为和 6 种恢复启动组合**。各自日期与源码边界见[开发记录](docs/DEVELOPMENT.md)，不作为当前开发源码的验收结论。

[2026-10-20 M0 检查](docs/acceptance/2026-10-20/v1-1-baseline/README.md)通过 **14 项推拉数量、30 项文件树/暂存、13 项地图、290 项主题、18 项图标、27 项菜单检查**，以及 **30 项 Python 策略测试**。本地化覆盖 **1015 个字符串键、7 个复数键和 1325 个源字面量**。核心测试通过 `swift build --build-tests` 编译，Debug 与原生 UI 测试通过 `xcodebuild build-for-testing` 编译；本机未执行 XCTest，新增 `SelectionScopeTests` 仍待托管执行。

托管 smoke **1/1**、完整原生功能 **45/45**（零失败/跳过）和阅读矩阵 **144/144** 已在固定源码 `2c2533c` 的[运行 39137123756](https://github.com/WeOpen/WeGit/actions/runs/39137123756) 通过。这是所记录源码的功能证据，不是发行提交的同提交完整验收。辅助功能暂缓验收；最终源码性能、受保护 Mac 安装与真实 Beta 反馈继续未完成。保留范围见[版本说明](docs/releases/v1.0.0.md)及[当前清单](docs/V1_RELEASE_CHECKLIST.md)。

测试采用隔离配置、临时仓库与独立偏好。请勿把写入测试指向不能承受改动的仓库。

## 🗺️ 范围与路线图

V1.0 聚焦日常 Git 流程和差异阅读。**Stash / Tag 管理、内置冲突编辑器、Interactive Rebase、Blame、linked worktree / submodule 管理及 Hosting Provider 集成**保留在后续版本。当前不支持打开 linked worktree 和 Bare 仓库布局。

已授权的 [v1.1 计划](docs/V1_1_PLAN.md)以 Stash、Remote、Tag 管理，以及文件历史与定向搜索为四项必选。单提交 Cherry-pick/Revert 在必选闭环及恢复验收完成后评估。当前 M0 负责基线集成；M1–M5 仍待实施，Beta、版本号与发布验收属于后续交付。

冲突可以在外部编辑器中处理，再回到应用继续或中止支持的操作；当前没有内置三方合并编辑器。Homebrew Git 核心与隔离非交互 OpenPGP 已通过；GitLab、交互式 Pinentry/硬件密钥、其他 Helper 组合及未覆盖环境继续在[兼容性矩阵](docs/COMPATIBILITY.md)中保留待验状态。

## 📚 项目结构与文档

| 路径 | 内容 |
| --- | --- |
| `WeGit/` | SwiftUI 应用、状态、原生呈现、设计系统与功能页面 |
| `WeGitCore/` | Git 领域服务、进程、仓库队列、快照与监听 |
| `WeGitAskPass/` | 随应用打包的认证辅助程序 |
| `WeGitTests/` · `WeGitUITests/` | 核心/集成测试与原生 UI 回归 |
| `branding/` | 当前品牌源文件及保留的旧版资源 |
| `docs/` | 产品、界面、架构、执行计划与验收证据；主要使用中文 |

- 🧭 [文档索引](docs/README.md)
- ✅ [V1.0 发布清单](docs/V1_RELEASE_CHECKLIST.md)
- 🏗️ [技术架构](docs/WeGit_Architecture.md)
- 📈 [性能记录](docs/PERFORMANCE.md) · ♿ [辅助访问](docs/ACCESSIBILITY.md)
- 📋 [版本记录](CHANGELOG.md) · 📦 [发布操作](docs/RELEASE.md)

## 🤝 用 Issue 管理需求

先创建 [Issue](https://github.com/WeOpen/WeGit/issues/new/choose)、明确验收条件，再通过关联 PR 交付。标签、CI 与草稿发布门槛见 [贡献说明](CONTRIBUTING.md)和 [GitHub workflow 方案](docs/GITHUB_WORKFLOW.md)。

## 💬 反馈与贡献

请通过 [GitHub Issues](https://github.com/WeOpen/WeGit/issues) 提供复现步骤、应用/macOS/Git 版本、预期行为和实际结果。提交改动时，请在 PR 中说明对应工作流与验证证据。

🔒 诊断摘要仅在设置中由用户主动导出，不包含代码、Diff、提交消息、仓库路径或凭证。分享额外截图和日志前，请自行检查其中内容。

## 📄 许可证

[MIT](LICENSE) © 2026 WeOpen。
