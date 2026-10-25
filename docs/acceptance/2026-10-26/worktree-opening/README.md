# v1.2 · 已有 Worktree 打开首批

2026-10-26，任务 [#59](https://github.com/WeOpen/WeGit/issues/59)，分支 `codex/v1.2-development`。开发起点为 `main` / `db66556a1fcb42cded904f642894ab26526e41d5`，已从远端核对一致；开发版本更新为 1.2.0 / build 4。本记录不表示功能完整验收或版本发布。

## 实现

- 允许打开已有 linked worktree，同时校验其独立 Git 目录、共享 common directory、`.git` / `commondir` / `gitdir` 重定向。路径保持原始中文和换行；目录/重定向被替换后旧会话拒绝写入。
- 普通仓库原有持久身份算法不变。Linked worktree 使用根目录、私有 Git 目录及共享目录的实体身份，保持 HEAD、index、序列、草稿和页面独立。
- Git 服务和仓库设置默认复用 common identity 对应的 FIFO 队列；队列注册表只弱持有条目。共享 Remote 配置写入仍使用描述符锚定的锁与原子替换，工作区专属/继承 Remote 配置只读保留。
- 事件分类先匹配私有 Git 目录，兄弟工作区 index/序列事件不触发当前工作区刷新；兄弟 HEAD/登记变动刷新分支占用。活动会话单独监听，去除祖先已覆盖的监听路径，无定时 Status 轮询。

首批保守地串行化同一 common directory 的全部写入及一致性快照，独立只读查询仍可并发。长时间网络写入可能延后兄弟工作区的快照读取；细分锁域留待实际并发工作负载测量，当前不会为了并行增加嵌套锁顺序。

## 已执行验证

| 验证 | 结果与范围 |
| --- | --- |
| `scripts/verify-worktrees.sh` | 28 项通过，详见 [逐项结果和原始采样](worktree-checks.json)。私有主仓库、两个 linked worktree、本地 bare remote；独立暂存/提交、队列取消、Remote/Tag/Stash、工作区配置、FSEvents、替换/移除保护 |
| `scripts/verify-remote-management.sh` | [40 项通过](remote-regression.json)，包含配置原子性及陈旧确认保护 |
| `scripts/verify-file-history.sh` | [20 项通过](history-regression.json)，覆盖普通仓库既有历史读取 |
| `swift build --build-tests` | 核心测试编译通过，新增 5 个 Worktree 核心用例；没有执行 Swift Testing/XCTest |
| `xcodebuild ... build-for-testing` | 完整原生测试目标编译通过，新增 Worktree 切换/草稿/页面/暂存/重开用例；没有执行 XCTest |
| CI 工具与资源 | Python 53/53、本地化 1171 字符串/8 复数、格式和仓库策略通过 |

后台测量每种布局各 30 次，交替先后顺序，每次重新 discover 并读取首次完整快照，保留全部样本；夹具为两个提交、两个 linked worktree、一个小文本文件与本地 Remote。本次主仓库/Linked 的 p95 为 55.13/56.10 ms。2000 ms p95 是本批后台门槛，**不是**真实窗口首屏、启动、滚动或大型仓库性能验收。运行使用本机 Debug 核心，操作系统缓存未清空；完整应用仍沿用原有 Release 预算。

## 原生应用诊断

使用当前应用 Swift/资源构建的独立 Debug 预览，仅打开私有夹具。真实用户 WeGit 持续运行；预览退出后清理私有夹具并还原之前的专用 UITests 偏好。

1. [第一个 Worktree](screenshots/first-staged.png)：输入独立草稿，点击原生复选框完成暂存。
2. 打开 Detached Worktree，确认自己的未跟踪文件、空草稿及无暂存文件，然后输入第二份草稿。
3. 通过 ⌘K 的原生列表搜索切回，第一个 Worktree 的[历史页面](screenshots/first-restored-history.png)和[草稿/暂存状态](screenshots/first-restored-draft.png)恢复。
4. 退出后重新打开第二个 Worktree，[第二份草稿恢复](screenshots/second-relaunched.png)。[Git 回执](ui-git-state.json)确认三个 HEAD 全部保持起点，只有第一工作区的索引发生预期变化。

原生预览在版本元数据调整前运行；此后应用 Swift/资源未改，只更新开发版本号与新 UI 用例的列表定位。目录中的 [155 项源码输入](source-inputs.json)记录最终编译输入，不把版本调整前的预览宣称为最终制品验收。

## 保留的失败与待验

- 路径别名的独立 FSEvents 探针进一步复现普通文件修改被分类为 `.all`。新增精确 status+diff 检查在原实现失败；订阅时一次性建立 POSIX→Foundation 路径前缀映射后，[29 项检查全部通过](watcher-alias-checks.json)。原始 28 项结果和源码快照作为修复前历史保留；这次修复不对每个事件增加文件系统查询。
- 首轮托管 [40244094107](https://github.com/WeOpen/WeGit/actions/runs/40244094107) 在 `fcec684` 执行 209 项核心测试、38 suites：208 通过、1 失败。新增快照用例的分支占用路径比较遇到 `/private/var` 与 `/var` 别名；其 HEAD/index/序列断言及另外四个新用例通过。改为重新发现 Git 报告的目录并核对实体身份，后续托管重验。
- 独立脚本首轮因异步表达式位于 `&&` 自动闭包和 TagList 字段名称错误而未编译，修正脚本后执行；不把编译失败计作产品行为失败。
- 第一轮行为检查误拒绝普通主仓库：目录 URL 尾斜杠不同导致直接 URL 相等比较失败。修复为解析后的 path 比较，真实 inode/目录/指针保护保留，之后完整独立检查通过。
- 核心用例编译曾使用要求 Equatable 的具体错误匹配，已改为精确 catch。原生观察确认新版仓库切换器为 List；用例改用搜索及 Return，避免旧 Button 查询。所有本机 XCTest 执行计数均为 0。
- Xcode 报本机 iOS CoreSimulator 版本不一致和无 AppIntents 依赖的诊断；macOS build-for-testing 实际成功，无本机测试执行。
- 托管三套 Git 核心回归、原生 smoke 后的新专项与完整功能回归尚未取得本批实际结果；最近/收藏的持久化、长期后台操作与并发压力、真实冲突恢复组合和大型仓库仍待补证。
- 完整 Release 性能、Beta、受保护 Mac 安装和发布门禁继续按 #35 与 v1.2 计划跟进。Worktree 创建/移除和其他 v1.2 功能不属于本批。
