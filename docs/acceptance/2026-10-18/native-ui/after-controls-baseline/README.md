# 控件查询修正后的完整功能基线

[Run 39119370087](https://github.com/WeOpen/WeGit/actions/runs/39119370087)，实际源码 `bcca7f3498d9019e2c0576fa081f82d9a17a800a`，工作区干净。原 smoke 1/1 通过；完整功能执行 45、通过 43、失败 2、跳过 0，命令耗时 3452.972 秒。全部 120 项应用输入已与该 Git 提交逐文件核对。原始 xcresult、日志与附件在 Actions artifact 和本地 `.build/ui-functional-bcca-39119370087` 保留；这里保存完整摘要、45 项结果、失败原文/视频和关键截图。

## 阅读矩阵已实际完成

ReadingMatrix 用例通过，1982.344 秒。144 张成功 PNG 与预期笛卡尔集合逐项一致：内存/磁盘 × 11/17/24pt × 舒适/紧凑 × 浅/深 × 980/1360/1460 宽 × 统一/分栏。内存、磁盘各 72 张；无缺失或重复。`reading-144-index.json` 保留全部原始名称、导出文件名及 SHA-256，四张边界示例随此目录保存，其余原图保留在上述 artifact/本地结果。

这表示 bcca7f3 的阅读组合完成，不等于完整套件通过，也不能替代后续应用输入变化后的统一回归。

## 两处失败

- `InspectorRestorationTests/testOpenInspectorRestoresAcrossBothSplitWorkspaces`：恢复到历史和打开检查器成功，缩小窗口后停在 `window.frame.contains(mainContent.frame)`。需要区分原生 Outline 内容范围与可见 viewport；原报告/视频保留，尚不据此宣称产品布局错误。
- `InterfacePolishTests/testSearchClearKeepsInputFocusAndKeyboardCommitInBothThemes`：清除搜索和重新输入通过，点击统一后 RightArrow 未使分栏值变为 1；尚未运行到后面的键盘提交步骤。需要保留点击/焦点状态定位，不能把它记为提交数据失败。

不提高测试预算、不跳过失败、不重复无变化完整失败回合；先用有界单项处理这两处，再对新的稳定源码跑完整功能与独立审查。
