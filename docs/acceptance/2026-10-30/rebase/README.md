# 独立 Rebase · V12-06 · #78

当前为功能候选，尚未完成托管 Core/原生专项或整版验收。可信入口 PR #79 已正常集成，main `507f03b4240d2fb8987cd214eed94d50ffda2d84` 只允许 smoke 实际通过后运行 `RebaseWorkflowTests/testFixedTargetReplayAndRecoverAcrossRelaunch`；120/180 秒原值保留。

从分支页选择目标，预览本地分支、HEAD、不可变目标、共同起点和待重放提交。已包含目标时不执行，快进保持分支名；普通重放保留空提交、显式控制合并结构，不自动 Stash、更新其他引用或 Force Push。已发布范围需要确认，后续推送仍走显式 Lease。

准备与确认均检查仓库身份、目标引用/对象、HEAD/分支、索引及全部目标/重放/父路径。忽略文件、未跟踪路径、特殊索引、目录替换及符号链接父节点不因干净 status 获得覆盖许可。私有预演对象和 index 不写入用户对象或 index；单次准备内有界缓存、原始 delta 更新合并树，不跨确认复用旧状态。普通双父线合并可保留；缺共同起点的合并、外侧父线、子模块及复杂结构冲突交给 Terminal。

执行先保留工作树对应的可达原 HEAD 引用，公共队列先于私有队列。取消、超时或失败之后从未取消的观察核对实际分支/HEAD、树、提交范围/作者/消息、index 和序列，不能只把 HEAD 变化当成功。恢复固定 Git 的 orig-head/head-name/onto/todo/done、其他状态文件、根 markers、rewritten refs 和索引；任意外部命令、未核对作者脚本或自动 Stash/其他 refs 更新不会自动执行。Merge 后端覆盖继续/中止；外部 Apply 后端当前为受限中止，不能宣称所有后端继续已验。

签名失败可能使同一 pick 同时出现在 done 和重新排队 todo，且已生成内容留在 index。显式继续仅在暂存树等于该重放的纯生成树时清理生成暂存并重放一次，额外手工编辑拒绝且保留；原 HEAD 不依赖会被 reset 改写的 ORIG_HEAD。正常冲突解决继续使用私有 index 验证，重开能读取真实操作；中止需确认撤回操作中的编辑。

42 项私有真实 Git 独立检查通过，包括真实签名失败/修复、双父合并、外部回执变化、执行中取消、全进程组退出、作者脚本/merge-driver 只读保护、增删/字面换行路径和可执行 mode。最新 Core 测试目标与原生方法 build-for-testing 编译成功；本机未运行 XCTest。

普通 10 文件/5 commit、大型 5000 文件/30 commit 各 30 有效 ordinary Release Core 样本，首次/稳态/取消后准备原预算 2000ms、启动 wrapper 与 child 后取消 500ms、RSS 256/512MiB。原大型首次 P95 3558.648ms 失败的 60 原样本保留；197 命令/122 ls-tree/41.9MB 独立定位后，单次准备复用元数据并采用原始 delta。新大型首次/稳态/恢复 P95 1725.879/1711.533/1724.315ms、cancel0.397ms、RSS104022016 bytes，全部 60 样本达标。wrapper 是隔离延迟诊断，不代表未改 Git 的大型算法取消，也不代表原生 UI 或整版性能通过。既有 Shell/Status/Diff/History/启动预算保留。

本机 CUA 返回 Mac 已锁定，需要手动解锁。隔离预览已正确编译/验证独立 suite 与 bundleID；其后来退出原因未确定，未自动按普通模式重开。六个受保护用户文件当前 SHA 保持。窄窗口/Tab/Return/Escape/焦点当前只有实际编写并编译的用例，没有 CUA 或托管通过结论。固定产品源码的托管 Core、真实 smoke/专项计数、完整 xcresult/制品/输入和截图、最新必需 CI/reviews及正常集成均待继续。

旧 internal String 外部脚本编译错误、async 自动闭包错误、私有 tree 引用写入原 index 的失败与 signing reschedule 失败日志/原夹具保留于主根 continuation 现场。v1.2 三方编辑器、Interactive Rebase、Submodule、LFS 和固定最终源码完整性能/安装/更新/迁移/回退/Beta/发布门禁保持开放。
