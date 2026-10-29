# Worktree 管理开发证据

Refs #75。列表保留 Git 原始 reportedPath 与同一发现机制的规范路径；创建固定已有提交、分支/登记列表及目标目录身份。移除固定目标工作树，采用 common→private 队列与同卷私有目录，保留工作文件和私有 Git 状态后只撤销缺失路径登记。

- 21项隔离真实行为检查通过，含三种创建、晚到 ignored 文件、原路径外来目录、锁定/脏/特殊索引/孤立提交保护；首次路径别名失败及夹具报告保留。
- 原生界面提供列表、预览、创建/移除确认、打开与保留目录检查；请求绑定固定会话和UUID。
- 本机严格格式、本地化1248字符串/8复数、完整build-for-testing通过，176应用输入逐项匹配；未执行XCTest。
- 固定原生方法由可信入口 #76 正常进入 main。候选 `8a60175` 的真实 smoke 和 Worktree 专项均为 1 总数 / 1 通过 / 0 失败 / 0 跳过，完整制品、xcresult、176 项输入和四张原生截图已核验；最终文档提交仍需核对最新头部必需 CI。

移除保留文件并撤销登记，首版不强制清理或删除用户工作树。带子模块、特殊索引、锁定、脏或无引用保护提交的目标明确受限。不自动重试不确定写入；此处不代表完整UI、安装、Beta或版本发布验收。

- Release CLI普通10文件/大型5000文件各30有效样本通过，均逐文件核对保留字节、源HEAD和索引。预设四项后台p95预算2000ms；5000文件prepareCreate118.55/create747.23/prepareRemove135.58/remove314.31ms，10文件33.71/126.51/55.08/98.49ms。全部原样本与源码绑定在release-cli-performance.json；不是UI或完整Release性能验收。

- 首次托管 `40835298431` 专项确切 1 总数 / 0 通过 / 1 失败 / 0 跳过，因超过 120 秒默认时限失败；其完整 ZIP、SHA256、全部 2121 条目 CRC 与 xcresult 已核验，失败记录保持。修正只减少已就绪状态的重复等待，保留所有行为断言及 120/180 秒可信时限。176 项应用输入不变，本机只编译且格式/策略通过。见 [原失败记录](hosted-40835298431-failed.json) 和 [等待修正编译记录](native-wait-recheck.json)。

- 新候选 `8a60175` 的原生运行 [40843285195](https://github.com/WeOpen/WeGit/actions/runs/40843285195) 通过；完整 63,060,610 字节 ZIP 的 GitHub SHA256 为 `091a51e1f2867c408a6c623a2f94df8fd87eabe5568f220f9ca63e7706467e82`，2041 条目 CRC 全过。直接读取两个 xcresult，smoke 与专项分别 1/1，0 失败/跳过；专项实际 103.931 秒。创建/取消/打开、独立草稿、锁定/脏/陈旧保护、保留字节/HEAD/index/分支和私有 Git 状态的原断言全部执行通过。
- 已实际检查四张截图：[中文浅色创建](screenshots/native-create-chinese-light.png)、[锁定移除禁用](screenshots/native-locked-removal-disabled.png)、[英文深色陈旧确认](screenshots/native-stale-removal-english-dark.png)、[撤销登记后的保留目录](screenshots/native-removed-registration-preserved-files.png)。原生 bundle、日志、环境和完整源码回执保留在工作树私有 `.build/ui-40843285195-artifacts/`；可复核摘要见 [成功记录](hosted-40843285195-passed.json)。
- 专项 xcresult 保留一条实际 QoS priority-inversion runtime warning。当前验收仅覆盖本专项，普通 Release/UI 性能、完整版本回归、VoiceOver、安装/更新/迁移/回退、Beta 与发布门禁仍独立开放。

## 读取消与窄窗口补验

新增源代码改变了 ProcessRunner 和工作树面板的焦点恢复。`8a60175` 的原生结果继续作为历史证据，新候选仍需可信 smoke/专项和最新必需 CI。

- [原读取消失败](read-performance-budget-failed.json) 保留三类各 30 个全部有效样本和原 250/500/250 ms 预算。先用未改 Core 的 [信号诊断](process-signal-before.json) 确认实际子进程屏蔽 SIGTERM：九次直接执行和 shell/child 取消均为 523–526 ms，trap 没有执行。生产修复仅给 posix_spawn 子进程设空信号掩码；父进程和系统信号保持。
- [修复后信号诊断](process-signal-after.json) 九次取消为 0.21–0.46 ms，shell trap 全部执行，进程组退出、容量恢复。[Release 读取消重验](read-performance-passed.json) 三类各 30 个有效样本全部达标；首次列表 P95 为 6.829/8.927/11.895 ms，取消为 0.518/0.562/0.426 ms，取消后列表为 7.385/8.118/12.363 ms。工作文件、HEAD、索引和分支引用逐字节保持。延迟 wrapper 仅用于实际执行中取消诊断，不作未经改动 Git 的大型仓库性能结论。
- [21 项 Worktree 行为重验](core-checks-after-signal-mask.json) 通过。托管核心新增真实 child 信号掩码与执行中 TERM/capacity 回归，预算保持 500 ms；本机只编译。
- [窄窗口实际证据](narrow-native-cua.json) 覆盖 980 宽布局、检查器开启时 1292 宽布局、长中文路径与长分支名、表单/预览、Return/Tab/Escape、英文深色重开。工作区最小高度 640 点；完整窗口截图还包含工具栏，不能把它的总高度写成 640 点。列表和预览未溢出，取消后 HEAD/index/refs/原文件均保持。
- [首个焦点失败](narrow-focus-first-failure.json) 保留了草稿仍在但实际输入没有回到编辑器的事实。面板现在弱引用原窗口及原生编辑控件，关闭时核对同一会话和控件仍存在，导航时丢弃旧恢复目标。修复后两次完整键盘流程直接续写草稿成功；筛选框也恢复原焦点。原生方法新增不重新点击编辑器的实际输入断言。
- 私有预览的测试 suite 与 bundle ID 必须不同。首次把两者设为同一值导致启动崩溃，CUA 随后按普通参数自动重开；已关闭该副本。数据库与 WAL 原 SHA 保持，SQLite shared-memory 索引发生缓存变化；共享 UITests 偏好也在旧选中行夹具上下文下更新，旧预览已退出，归因未确认。相关实际快照保留，不能宣称本段诊断的原五个用户文件全部未改。后续预览使用独立 suite、内存 SwiftData 与隔离 Git 配置，先核对 PID/argv/存活再绑定 CUA。

本段 CUA 与 Release CLI 仅为诊断。完整原生 XCTest、最终版本性能、VoiceOver、安装/Beta 和发布门禁继续按固定最终源码独立执行。
