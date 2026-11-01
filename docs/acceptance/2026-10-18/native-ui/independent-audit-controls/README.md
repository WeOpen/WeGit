# 独立 SDK 辅助访问审查对照

[39137541735](https://github.com/WeOpen/WeGit/actions/runs/39137541735)，固定源码 `5a38d6b565174cb79331cae8680386a9384fe99b`，macOS 27.0.1 arm64 / Xcode 27.0（27A266a），新的 hosted VM。与 WeGit 完整功能不同 VM、不同 bundle ID、无 WeGit UI/模型/主题/仓库依赖；只有 hosted 对照导入 SwiftUI。检查器/键盘修正后的 WeGit 完整功能仍独立运行。

| 独立控制 | 实际测试数 | 通过 | 失败 | 跳过 | 命令耗时 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Reordered 启动回归 | 1 | 1 | 0 | 0 | 9.551 秒 |
| AppKit 标准控件审查 | 1 | 0 | 1 | 0 | 21.260 秒 |
| SwiftUI 标准控件审查 | 1 | 0 | 1 | 0 | 22.119 秒 |

两个审查用例都实际完成 Light/Dark，每轮在审查前已通过：恰好一个可点击窗口、打开标准 scope 选择器并选择 Current branch、点击 Activate 并读到 Activated。不是编译通过或启动前置失败。每个用例的失败与全部回调保留；没有把诊断失败改成预期通过，没有添加忽略回调。

## 原始回调

| 控制 | Light | Dark | 类型 |
| --- | ---: | ---: | --- |
| AppKit | 3 | 1 | 2 个 Light 文字对比度，2 个 Disabled TouchBar 说明 |
| SwiftUI | 6 | 4 | 2 个 Light 文字对比度，4 个标准 Picker/Menu 动作，2 个 Group 说明，2 个 Disabled TouchBar 说明 |

合计 14 个回调，不等于 14 个独立产品问题。每条说明、元素路径、子树和 PNG 分别在 native/issues、hosted/issues，完整层级和四张窗口截图也保留。

## 21:1 的文字被报告失败

两个控制均对 Light 的 `control-ready`（Native SDK controls ready）和 `control-sha`（40 位十六进制）报告 Contrast failed。实际原图中四个 ROI 的背景均为 RGB(255,255,255)，字迹主体均有至少 13 个 RGB(0,0,0) 像素；sRGB 比值为 **21.0:1**。详细 ROI/重复像素数和算法见 pixel-probes.json，原图包含完整反锯齿边缘。两种控制字体均为系统等宽 11pt，绘制表面为原生 controlBackgroundColor、文字为 textColor；没有引用 WeGit 颜色代码。

这构成独立对照中的具体对比度误报证据，说明部分现象可在标准 SDK 控件复现。SwiftUI 原生 Picker/Menu 的动作报告和框架 Group/Disabled TouchBar 说明也独立复现；不据此自动豁免全部 WeGit 报告。尤其鼠标可用不能代替 VoiceOver；产品的 55 条仍保留逐项判定与实际辅助技术路径要求。

普通 PR 场景默认恢复为只运行 reordered。两个新审查对照保留显式选择（合入后 `--controls audit-native,audit-hosted`）；本次失败不无变化自动重跑。它们的设计就是保留真实系统审查结果，失败不建立产品或发布通过结论。所有 runner 的 sandbox 元数据、原始 SIP disabled / Gatekeeper enabled 和显示模式恢复见 report/display-session；没有修改 OS 授权或系统保护。本机仅 build-for-testing 与独立工具检查，没有本机 XCTest。
