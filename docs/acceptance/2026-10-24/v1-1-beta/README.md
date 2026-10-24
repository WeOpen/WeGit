# v1.1 Beta 1 制品与性能收尾

应用源码固定为 `835b8c4f5861b0f32844f13985a4742efb46b261`，标签 `v1.1.0-beta.1`，版本 1.1.0 / build 3。四项必选已实现，完整功能回归 **54/54、0 失败、0 跳过**，阅读矩阵 **144 张截图**；[原始功能证据](../../2026-10-23/v1-1-final/README.md)保留失败与修复过程。功能完成、Beta 草稿制品和稳定版发布验收分别记录；#35 保持开放。

## 可复核的 Beta 草稿

[构建 39984951536](https://github.com/WeOpen/WeGit/actions/runs/39984951536) 成功生成[预发布草稿](https://github.com/WeOpen/WeGit/releases/tag/untagged-9db93d5ca0a0525d748b)，没有公开发布或更改稳定版网站下载。实际下载包核对结果见 [package-verification.json](package-verification.json)。

- ZIP：`WeGit-1.1.0-beta.1-macos-arm64-adhoc.zip`，9,190,557 bytes。
- SHA256：`13018dc037edf617adc41407427fa7b1f547fe8aa96ff5f664d3ec093b7a067f`，与下载的 `.sha256`、manifest 和 release.json 一致。
- 签名完整性 `codesign --verify --deep --strict` 通过；ad-hoc，无 Developer ID，未经 Apple 公证。要求 macOS 27+ / arm64。
- 包内 `build-source.json` 的原始字节哈希与 manifest 一致。分别核对 manifest 的 256 项发布输入及应用回执的 140 项输入，全部与固定标签一致。两个清单范围不同，不能直接要求字典相等。
- 普通 Release、空额外 Swift 条件、正式 Bundle ID `com.willxue.wegit`，没有 XCTest bundle 或 `get-task-allow`。仅解包检查，未覆盖本机用户安装。
- 干净受保护 Mac 的 HTTPS 下载、首次系统提示、实际安装、迁移/回退与真实 Beta 反馈待验。自托管交互 runner 本次查询为 0，稳定版同标签 Full acceptance 未完成。

## 托管 VM：保留了失败的完整证据

[39985999719](https://github.com/WeOpen/WeGit/actions/runs/39985999719) 使用 `7277adb`，140 项应用输入与 Beta 源码一致。新保留流程成功导出小报告和原始制品；[hosted-performance.json](hosted-performance.json) 保存原报告哈希、所有有效原始测量与环境。essential 制品 12517991856，SHA256 `d352c73b8defe3919ae368fe0cba3946690a9642dd172c99e8cb75dd5bf35134`；原始制品 12517658627，SHA256 `bf1f9bc084d768a35bfc37e57f6b222f1b6419d597a3a26be8c51218ed8e6184`。

同一 VirtualMac2,1 / 7 GiB / macOS 27.0.1 / Xcode 27.1，串行新进程、暖文件系统缓存；控制版本固定 v1.0.0 `2d1cb2a`，只覆盖测量工具，应用输入核对一致。

| 普通仓库 p95 ms，均 30 次 | v1.0 | Beta 1 | 既有预算 | Beta 结果 |
| --- | ---: | ---: | ---: | --- |
| 外壳 | 748.74 | 1542.34 | 500 | 失败 |
| 状态 | 804.50 | 1430.35 | 300 | 失败 |
| Diff | 331.03 | 524.17 | 150 | 失败 |
| 历史 | 758.96 | 1282.64 | 300 | 失败 |
| 外部更新 | 602.26 | 652.52 | 1000 | 通过 |

大型仓库 30 次已完成，外壳/状态/Diff/历史/外部更新 p95 为 803.08/1312.02/533.57/1973.82/1316.27 ms；其原来没有普通仓库那组硬预算，保留实际值。不能因为旧版也失败而豁免新版，不能将回退全部归因于 VM。

启动 XCTest 用例报告通过，但第 22 次出现 `Received unexpected number of metrics: 0 in iteration with index 22`，只导出 29 个有效样本。汇总器按 30 个要求拒绝通过，没有删除或填造样本；采集随即停止，滚动未运行。这是缺失证据，不能称启动达标或滚动通过。旧 run 39942623653 的 ENOTFOUND 无制品失败继续保留。

## 实体 Mac：补充对照，不能替代 Full acceptance

[physical-diagnostic.json](physical-diagnostic.json) 保存两版各 30 次完整测量、全部样本及源文件哈希。Mac16,8 / 24 GiB / macOS 27.0.1 / Xcode 27.1，普通仓库 1000 文件 / 1000 提交 / 20 改动，历史首屏 200 条。使用 Cua 驱动原生界面，没有运行本地 XCTest；每次核对实际 Diff、历史与外部事件，结束后验证 HEAD、porcelain 状态及索引字节未改变。

| p95 ms，均 30 次 | v1.0 | Beta 1 | 既有预算 | Beta 结果 |
| --- | ---: | ---: | ---: | --- |
| 外壳 | 324.70 | 359.52 | 500 | 通过 |
| 状态 | 300.74 | 386.38 | 300 | 失败 |
| Diff | 322.74 | 195.32 | 150 | 失败 |
| 历史 | 469.25 | 402.34 | 300 | 失败 |
| 外部更新 | 881.43 | 750.09 | 1000 | 通过 |

峰值 RSS 为 v1.0 270.95 MiB、Beta 262.88 MiB。Diff 与历史较控制组改善，状态较慢；三项预算仍未满足。

控制组第 17/18 次间因用户中断相隔约四小时，第 18 次部分记录单独保留并重新采集；第 28 次在历史后中断，核对同进程和夹具后继续。候选第 1 次最初因旧 Cua 闭包绑定命中错误宿主，被夹具保护拒绝，部分记录保留，另启新进程完成正式样本。pilot 和未完成记录按协议排除，不按耗时筛选。所有完成样本纳入计算；这些条件及不同驱动使本组只能作为补充诊断。

## 后续验收

性能仍未验收通过。下一步以调用栈和读取/渲染分段证据定位状态、Diff、历史耗时，另补完整启动与滚动测量；不调整预算或减少用例掩盖失败。Beta 草稿保留已知限制。受保护安装、迁移/回退、真实反馈和稳定版 Full acceptance 仍待完成；Cherry-pick/Revert 按既定计划后移。
