# WeGit v1.2 开发与证据收口

本轮继续完成 V12-01～V12-09 的开发源码、可执行验证与正常 PR 集成。正式发布验收与下列延期条件保持独立；Issue 关闭原因区分 `completed` 和 `not_planned`。

## 用户确认延期的验收条件

2026-11-01，维护者确认 #3/#6/#7/#9，以及后续核对的 #4/#5 按延期归档处理。所有历史失败和未完成样本保留，不将缺少设备、账号、真实使用者或完整最终测量改写为通过。

| Issue | 延期条件与恢复时的标准 |
| --- | --- |
| [#3](https://github.com/WeOpen/WeGit/issues/3) | 完整 VoiceOver 朗读、焦点与辅助访问验收；必须在真实可控交互环境保留实际朗读/操作证据。已有 AX 名称、键盘和截图验证只覆盖各自记录范围。 |
| [#4](https://github.com/WeOpen/WeGit/issues/4) | 最终同源码普通 Release 至少30次原始样本；P95 外壳≤500ms、Status≤300ms、Diff≤150ms、History≤300ms、外部刷新≤1000ms、启动≤1000ms；十万级内存/滚动、复杂图、磁盘 Diff、取消与 Instruments 热点证据仍待完成。既有超预算或29个有效样本的结果保持失败/不完整。 |
| [#5](https://github.com/WeOpen/WeGit/issues/5) | 真实 Pinentry/硬件密钥、其他凭据 Helper、GitLab 与未覆盖服务组合；逐项记录实际 Git/工具版本、权限失效、取消/关闭/切换、权威状态及草稿。隔离临时 OpenPGP 密钥、GitHub 传输与本地 bare remote 不能代替这些组合。真实远端 LFS 服务与本地指针夹具分别记录。 |
| [#6](https://github.com/WeOpen/WeGit/issues/6) | 专用受控验收机和可复现的整版验证环境；托管 VM 和当前开发机上的专项结果不能自动成为实体发布验收。 |
| [#7](https://github.com/WeOpen/WeGit/issues/7) | 干净、受保护 Mac 上的签名/公证、安装、更新、数据迁移和回退；固定源码、包摘要、保护状态及实际步骤。开发包构建不覆盖此门禁。 |
| [#9](https://github.com/WeOpen/WeGit/issues/9) | 真实外部 Beta 使用者、实际反馈与关键问题处理；自动化测试或生成制品不能作为用户反馈。 |

上述项目以 `not_planned` 归档，并在重新安排验收时恢复跟踪。v1.1/v1.1.1 历史总任务中的发布与整版验收依赖同样保留在此表；开发实现、已执行验证及延期验收分别记载。

## 最终开发候选

V12-01～V12-09 的实现状态已在 [执行表](../../../../plans/V1_2_EXECUTION.md) 更新。已集成能力包括已有 Worktree 打开/切换/恢复、Worktree 管理、Cherry-pick/Revert、Blame、选中行暂存、三方冲突编辑器、独立 Rebase、Submodule 与 LFS 状态。最后的 Interactive Rebase 完整动作和 LFS 批量读取/固定对象获取合并为 [PR #87](https://github.com/WeOpen/WeGit/pull/87) 的同一候选，保留 PR #97 原始来源。

| 本轮实际证据 | 结果与范围 |
| --- | --- |
| 组合 Core 独立行为 | 75 Interactive + 39 Submodule/LFS，114项通过；私有真实Git夹具 |
| 编译 | Core测试目标与原生build-for-testing通过；本机未运行XCTest |
| Interactive Release Core | 普通、5000文件松散对象、打包对象各30，90有效；first P95 113.296/686.773/676.317ms，execute 1173.377/4399.962/3787.132ms，cancel均<1ms；[完整数组](../../2026-11-02/interactive-rebase/performance.json) |
| LFS Release Core | 同三种负载各30，90有效；first P95 94.420/689.663/326.827ms，cancel均<1ms；[完整数组](../../2026-11-02/lfs-reading/performance.json) |
| 精确性能输入 | 两份报告各94个实际输入逐SHA匹配组合Core；sourceRevision和workspaceDirty保留真实运行值 |
| Interactive 原生 | 最终UI输入38dca23，run41362241163；smoke/专项各1/1/0/0，74.719秒<120、summary78.620秒<180；194输入、2021CRC、六图六AX与显示恢复核验；[回执](../../2026-11-02/interactive-rebase/native-41362241163-verified.json) |
| LFS 原生 | 最终同源Submodule/LFS专项及成功截图/AX，随同本轮原生回执保存；早期bc1c06b的1/1/0/0记录保留各自来源 |
| 必需CI/开发包 | 当前head的PR policy、Repository policy、Native macOS、三套Git全Core、原始性能数组和固定源码开发包；只在当前结果通过且无未解决review后正常squash |
| main功能回归 | 由可信main执行smoke后完整functional，按实际计数、源码、xcresult与制品收口；排除官方functional范围已明确分开的手工/audit项 |

原2000ms读取、10000ms变基执行、500ms live取消、256/512MiB Core resident预算保持。Core测量的内存不包含子Git，专项性能不代替本页延期的最终整版UI性能。三项新性能result.json已加入CI制品白名单；必须核对真实数组，不能只引用步骤success。

## Issue、PR与分支收尾规则

- #59/#70 的开发能力和原生专项已正常集成；关闭原因使用 completed。其完整发布性能条件随 #4/#35 延期保留。
- #35/#57 的实现阶段与已执行证据保留；对应正式M5/整版验收条件按维护者确认归档为 not_planned，不宣称完成安装、完整VoiceOver或Beta。
- #86/#96 在最终候选通过当前门禁并正常合入main后完成；#97在源码已包含且逐项核对后关闭。
- 已完成分支先保存来源、核对已集成提交与HEAD/index/工作区，再清理。主检出的站点等改动和旧Rebase检出的三项修改/两份草稿保持；承载它们的两个分支保留。编译/原生证据目录不随分支删除而丢失。

最新CI、main functional计数、源码等价与清理回执由PR #87收口评论及项目HANDOFF记录。GitHub可选Workers Builds的失败另行保留；它不是上述三项必需检查，也不构成官网生产环境验收。
