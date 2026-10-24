# 太极 Loading 提交与编译验证

2026-10-24，应维护者要求将原检出的 Loading 代码提交，对齐 main `a41095a`。代码提交为 `9a71b8d`，需求 [#54](https://github.com/WeOpen/WeGit/issues/54)。本记录只声明实际完成的检查；旧 Beta `835b8c4` 的 54/54、性能和制品结果不覆盖这次新应用输入。

## 行为

- 完整太极图匀速旋转，每圈 2.8 秒；统一于工作区的 `ProgressViewStyle`，覆盖现有窗口、设置、Sheet、认证和菜单栏面板的共享呈现入口。
- 有 `fractionCompleted` 时显式使用原生线性进度，保留克隆百分比。
- 无 label 的不定进度保留“读取中…”辅助访问名称；尊重应用动效偏好和系统减少动态效果，隐藏或非活动场景暂停 Timeline。

## 本轮实际完成

- `swift format lint --strict` 检查新增两个 Swift 文件及 AppStyle 通过；`git diff --check`、工程 plist 语法通过。
- `xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/loading-commit-validation build-for-testing` 退出 0，日志含 `TEST BUILD SUCCEEDED`；没有执行本地 XCTest。
- 按 CONTRIBUTING 重新 `xcodegen generate`，结果与已提交工程一致，没有附加工程差异。
- 包内 Debug 来源回执逐项核对当前应用输入，结果见 [build-verification.json](build-verification.json)。原始日志和 DerivedData 保留在 `.build/`，不整体提交。

## 既有预览与未完成范围

HANDOFF 的 2026-10-23 独立 NSHosting 预览记录确认浅深色、mini/small 控件、关闭动效、busy indicator 名称和确定进度 `0.42`。此次保留该实现；预览文件与 AX 原文位于 `.build/loading-preview/`。这是独立组件预览的历史证据，不是本轮最终应用的托管交互结果。

新源码的托管运行、整套功能回归、Release 实际性能、受保护 Mac 安装和 Beta/稳定版签收仍分别跟进。此次没有生成或发布新包，既有 Beta 标签与制品保持原来源。

## 首次 CI 的独立检查器编译失败

[40052796726](https://github.com/WeOpen/WeGit/actions/runs/40052796726) 的应用 Debug 和 Apple / Git 2.46 两套各 204 项、37 suites 核心回归已通过；独立文件历史、Tag、Remote、Stash、同步计数、文件夹树和变更地图检查通过。随后主题检查在编译时报告 AppStyle 找不到 `YinYangLoadingStyle`，不是主题断言或应用构建失败。后面的签名、Homebrew 核心、UI 编译及 Release 包步骤未执行，原 run 保持失败。

本机 `scripts/verify-themes.sh` 在修复前重现同一编译错误。检查器使用手写 `swiftc` 源文件清单，只包含旧 AppStyle 依赖；补齐 `YinYangLoadingGlyph.swift` 和 `YinYangLoadingStyle.swift` 后重跑。修复只改检查器清单，142 项应用输入与本记录的 Debug 回执保持一致。

修复后独立主题检查退出 0，实际执行并通过 290 项。Shell 语法、仓库策略与差异检查通过；142 项应用输入重新逐项核对，零差异。托管重跑结果单独按实际 run 记录，首次失败不改写为成功。
