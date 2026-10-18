# 完整自动原生功能通过

[39137123756](https://github.com/WeOpen/WeGit/actions/runs/39137123756)，固定 main `2c2533c1f0ef7e084f57eae3144f616416e4d608`，工作区干净。smoke 恰好执行/通过 1/1；随后完整自动功能 **执行 45、通过 45、失败 0、跳过 0、预期失败 0**。功能命令耗时 3234.532 秒。

45 个测试标识与此前 43/45 基线完全一致，没有移除失败用例、扩大时限或添加跳过。检查器恢复、搜索清除后的双向方向键和真实键盘提交已在完整回合通过；复制原始文本/补丁、历史/大差异分页、最小窗口、克隆拒绝/重试、两轮 Pull Rebase 冲突与 Abort 等原断言继续执行。全部结果在 case-results.json，原失败与有界修正记录分别保留。

## 阅读矩阵

ReadingMatrix 实际通过，1778.596 秒。全部 **144 个精确组合** 有 keepAlways PNG：内存/磁盘 × 11/17/24pt × 舒适/紧凑 × 浅/深 × 980/1360/1460 宽 × 统一/分栏。组合集合与预期逐项相等，无缺失/重复，内存、磁盘各 72。

reading-144-index.json 包含每张原图名称、导出文件名、组合及 SHA-256。四张边界示例随本目录保留；全部原图、日志和 xcresult 在 Actions artifact 与本地 `.build/ui-full-final-39137123756` 保留。artifact 大小 226422046 字节，元数据见 artifact-metadata.json；远端保留期限见该原始回执，本地结果不因此删除。

四张边界原图已人工复核。980 宽磁盘视图中，大型增删统计会折成两行；现有矩阵验证控件可达、阅读与数据行为，不包含所有排版偏好的视觉签收。该观察保留在原图，不能把 144 张成功截图扩展为全部视觉/可读性验收通过。

## 来源与环境

全部 120 项应用构建输入逐文件匹配 Git 提交和当前工作树。独立诊断/证据分支也核对 120 项应用输入及 21 项产品 UI 测试输入，与被测 2c2533c 一致，见 source-equivalence.json。该等价校核不宣称整个仓库不同 Git 提交的正式发布门槛已通过。

macOS 27.0.1 arm64 / Xcode 27；新 hosted VM，临时 1920×1080 1× 显示成功恢复原模式，没有权限变更。VM 原始 SIP disabled、Gatekeeper enabled，因此这轮是功能验证，不能代替受保护目标机器的安装签收。

另核对普通 Release CI 39138069932 的 120 项应用输入与该被测提交一致；回执和验证分别为 release-ci-build-source.json / release-ci-source-verification.json。Debug XCTest 通过不等于 Release UI、安装或性能通过。

## 保留的提示与其他门槛

xcresult 的用例节点包含 **9 条 Runtime Warning**，原始文字与对应测试在 runtime-warnings.json，均为 Internal 的 QoS 等待提示。缺少产品调用栈，不直接归因为 WeGit，也不把它改写成性能通过或失败；最终 Release 性能仍按既有预算独立验收。

自动功能与手动辅助访问范围分开：与 Full acceptance 一致，功能模式排除独立自动审查和 opt-in ManualAccessibilitySession，所选 45 项全部执行且无跳过。应用输入等价的 734b8e1 独立审查仍有 55 条待判定回调；其视图/审查源文件未改，原失败保留，不无变化重复失败或增加忽略。独立 SDK 对照的失败、细笔画观察、VoiceOver/完整键盘/系统显示选项及保护环境门槛另行保留。

本机仅编译、独立 checker 和工具测试，没有本机 XCTest。没有发布 Release、Tag 或 Beta 邀请；当前结果不表示 V1.0 发布完成。
