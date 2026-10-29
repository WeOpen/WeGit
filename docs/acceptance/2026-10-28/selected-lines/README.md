# 选中行暂存/取消暂存开发证据

需求 #70；功能分支 codex/v1.2-selected-lines。固定原始差异、HEAD/分支、索引与目标工作文件，私有对象目录和临时索引生成候选；执行持有 index.lock、重验并原子安装，回执不确定时不自动重写。

- 独立检查重新执行 99 项：72 个逐字节选择组合（零/三行上下文、CRLF、无末尾换行、Unicode、多块）、13 个预演/陈旧快照/索引锁/并发写入、14 个新增删除/未诞生分支/转换守卫。
- 原生 CUA 确认预览和 Escape 取消保持原索引字节；Unified 单选 B 仅使 index 为 a/B/b/c/d；修复分组身份后，Split 只取消 B，index 回到 a/b/c/d。工作文件 a/B/C/d 和 HEAD 保持原样。专用预览空闲 CPU 0%，RSS 106128 KiB 的单次诊断；不是 Release 完整性能验收。
- DiffTextSelection 的弱引用登记不参与 Observation，保留首次 100% CPU 失败采样。适用差异的动作区固定高度，避免跨行拖选途中代码纵向位移。
- swift build --build-tests 与 xcodebuild build-for-testing 已成功；本机未执行 XCTest。新增核心/原生用例仍需托管实际执行。
- 可信 main 的 selected-lines 白名单通过独立 PR #72 集成，只允许一个固定方法，必须先实际 smoke 通过。

本批不包含选中行丢弃、工作文件编辑或跨文件批量写入。二进制、符号链接、gitlink、mode/rename、split index、clean filter 或无法逐字节重现的转换保留文件级入口。完整最终回归、Release 开销和发布门禁继续跟进，不能把开发构建或本机 CUA 当作托管验收。


- 首轮托管 run 40806321814：smoke 实际 1/1、0 失败/跳过；selected-lines 专项实际 1 项、0 通过/1 失败/0 跳过，在部分暂存后的 checkbox.value 字符串强转断言失败，后续步骤未执行。已有原生用例与控件使用数值 1/0，现保持相同状态断言并改为 Int；不删检查或放宽结果。
- 必需 CI 40806104965 在 OnlyOneTrailingClosureArgument 格式检查处失败，后续核心/构建步骤未执行。该规则不会由自动格式化全部修复；显式 operation 参数后重新执行严格 lint。旧运行和原始 xcresult 保留，修复后的托管验收仍待真实结果。
