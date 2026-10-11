# WeGit 技术架构设计

| 项目 | 说明 |
| --- | --- |
| 目标平台 | macOS 27+，以 Phase 0 工具链验证为准 |
| 技术栈 | Swift / SwiftUI / Swift Concurrency / SwiftData / Git CLI |
| 文档修订版 | v1.1 |
| 更新日期 | 2026-10-06 |
| 状态 | 目标架构；当前实现与差异见 [开发进度](DEVELOPMENT.md)，示意类型不等同于源码 |
| 关联文档 | [文档索引](README.md) · [PRD](WeGit_PRD.md) · [UI/UX](WeGit_UI_UX_Spec.md) · [执行计划](PLAN.md) |

## 1. 架构目标与边界

架构需要保证 Git 语义正确、界面响应、外部工具兼容、可观测性和可测试性。功能版本以 [PRD 第 2 节](WeGit_PRD.md#2-版本范围) 为准；以下扩展接口不代表要求首版一次实现全部能力。

核心约束：

- UI 通过领域意图调用服务，不构造 Git 参数或启动进程。
- 领域服务依赖 `GitEngine`，引擎不持有 UI 状态。
- Git 仓库、索引和工作区是事实来源；缓存和 SwiftData 只能存放可丢弃派生数据或应用数据。
- Git 执行、文件 I/O、解析和提交图布局不在 MainActor 上进行。
- Git 写操作通过明确的异步排队机制串行执行；Actor 隔离本身不足以保证这一点。
- 参数、路径、标准输入、输出、取消、超时和错误均有明确契约。

## 2. 分层与目录

```text
SwiftUI / 局部 AppKit 组件
          ↓
WorkspaceState / Feature State
          ↓
Domain Services / Commands
          ↓
RepositoryOperationCoordinator → GitEngine
                                    ↓
                               GitEngine
                                    ↓
                               ProcessRunner
                                    ↓
                             Git / SSH / Helpers
```

`RepositorySession` 聚合仓库运行时状态；Watcher 与刷新协调器负责数据更新，持久化、Keychain 和日志通过基础设施接口注入。

建议工程结构如下，按实际功能逐步创建：

```text
WeGit/
├── App/                  # Scene、环境注入、命令、窗口协调
├── Features/             # Welcome、Changes、Diff、Commit、History、Branches 等
├── Domain/
│   ├── Models/           # 领域模型的唯一声明位置
│   ├── Services/
│   ├── Commands/
│   └── Errors/
├── GitCore/
│   ├── GitEngine.swift
│   ├── GitEngine.swift
│   ├── GitCommand.swift
│   ├── GitCommandResult.swift
│   ├── GitEnvironment.swift
│   ├── Parsers/          # CLI 输出到领域模型的转换
│   └── Operations/       # 命令构造与能力适配
├── Repository/           # Session、身份、队列、刷新、Watcher
├── Infrastructure/       # Process、FileSystem、Keychain、Persistence、Logging
├── DesignSystem/         # Components、Diff、Graph、Typography、Icons
└── Resources/
WeGitTests/
├── Unit/
├── Integration/
├── Fixtures/
└── Performance/
WeGitUITests/             # UI 与必要的视觉检查
```

不在 Domain 和 GitCore 重复定义同一套 Commit/Branch 模型。AppKit 包装限于需要的差异或提交图组件，通过 `NSViewRepresentable` 接入。

## 3. 应用、窗口与仓库状态

| 类型 | 职责 | 不承担的职责 |
| --- | --- | --- |
| `AppState` | 全局偏好、Session 注册表、应用级流程 | 唯一的全局「当前仓库」和文件选择 |
| `WorkspaceState` | 每个窗口的仓库选择、路由、文件/提交选择和面板宽度 | Git 命令、进程管理 |
| `RepositorySessionStore` | 规范化身份、共享 Session、生命周期引用计数 | 具体页面状态 |
| `RepositorySession` | 仓库快照、操作状态、服务与刷新入口 | Shell 拼接、Keychain 细节 |
| `RepositorySnapshot` | 带代次和读取状态的不可变聚合数据 | 通过后台逐字段修改 UI |
| Feature State | 复杂页面的筛选、加载、选择与请求标识 | 复制完整仓库状态 |

UI 状态使用 `@Observable` 和 `@MainActor`，配合 `@State`、`@Environment`、`@Bindable`。简单页面直接组合 Session 与局部状态，复杂页面才增加 ViewModel。

即使 P0 只有单窗口，也不把 `selectedRepositoryID` 固定在全局单例中。后续多窗口可共享仓库 Session，但保持窗口选择独立。

## 4. 仓库身份与路径解析

`RepositoryID` 是应用记录的稳定标识，不等于仓库锁标识。多个别名路径、符号链接或重复打开记录应映射到同一活动仓库协调器。

仓库发现由 Git 完成，至少取得：工作区根目录、实际 Git 目录、Common Git 目录、是否 Bare、HEAD 状态。可使用 `rev-parse` 的 `--show-toplevel`、`--absolute-git-dir`、`--git-common-dir`、`--is-bare-repository` 等机器接口，并验证版本支持。

不得假定 `.git` 一定是目录。它可能是指向实际 Git 目录的文件；内部状态路径通过 `git rev-parse --git-path <name>` 等接口解析。linked worktree 的索引/HEAD 与共享 refs 可能在不同目录。

P0 识别未支持的布局并给出说明；V1.2 支持 Worktree 时，协调器须同时覆盖每个工作区的索引/文件和 Common Git 目录中的共享引用写入。

### 4.1 路径模型

内部路径是仓库相对路径，展示文本与执行标识分离。NUL 分隔解析必须保留空格、Tab、换行、Unicode 和原始路径信息，不用按空格拆分的方式解析整个记录。

`--` 只结束选项，不能关闭 Git pathspec 的通配语义。对用户选中的确切路径，采用 Git 的 literal pathspec 模式（如全局 `--literal-pathspecs`）或经能力验证的 NUL pathspec 输入。不能把 `*.swift` 等合法文件名误解释为一组文件。

Swift 进程参数需要字符串，无法无损表示的路径编码不能用替代字符后继续写入；应显示明确限制并禁用相关写操作，或在专门实现原始字节执行路径后再开放。

打开外部文件前验证路径来源、仓库边界与符号链接语义，避免把拼接字符串当成安全校验。

## 5. 核心领域模型

以下是模型契约，具体字段可随实现细化，但必须保留所列语义。

| 模型 | 必须表达的内容 |
| --- | --- |
| `GitCommitID` | 完整对象 ID；不硬编码只能有 40 个字符，按对象格式验证 |
| `GitRefName` | 完整引用名、展示短名和引用类型，避免同名分支/Tag 歧义 |
| `GitHEAD` | Attached、Detached、Unborn 三种状态 |
| `GitIdentity` | 姓名、邮件及必要的显示信息 |
| `GitCommit` | ID、父提交、作者/提交者、两类时间、标题、正文、指向此提交的 refs |
| `GitBranch` | 完整 ref、本地/远端类型、目标提交、上游、当前标记、领先/落后及已知状态 |
| `GitRemote` | 名称、Fetch URL 和 Push URL 集合；不要假定只能有一个 URL |
| `GitFileChange` | 路径、原路径、索引状态、工作区状态、类型和冲突信息 |
| `WorkingTreeStatus` | 已暂存、未暂存、未跟踪、冲突和分支状态 |
| `GitDiffFile` | 新旧路径/模式、二进制标识、差异块和比较基准 |
| `GitDiffHunk` | 稳定块标识、新旧起点与行数、原始补丁信息和行列表 |
| `GitDiffLine` | Context/Addition/Deletion、新旧行号、原始内容及无末尾换行标记 |
| `RepositorySnapshot` | HEAD、状态、refs、Remote、同步状态、序列操作状态、代次和读取时间 |

P0 不要求预先实现全部 Tag/Stash 模型；后续版本需要时添加。UI 使用稳定的对象身份，不能在每次刷新时为同一差异块随机生成 UUID 导致选择丢失；稳定身份也必须包含比较基准，避免把旧块误认成新块。

## 6. GitEngine 与命令契约

V1.0 使用具体的 `GitEngine: Sendable`，通过 `any ProcessRunning` 注入进程执行器。当前没有独立的 `GitCLIEngine` 实现，不为名称一致而增加空协议或别名。

引擎入口接受参数数组、目录、可选 `Data` 标准输入、命令允许的退出码、超时和输出上限；可按需指定磁盘输出与运行时配置。返回 `ProcessResult`，保留原始输出与实际执行结果。测试替换 `ProcessRunning`，不在应用中开放模拟 Git 行为。

调度与风险判断由领域服务及 `RepositoryOperationQueue` 承担：

- 本地写入、Fetch 和 Push 在同一仓库队列内执行；写许可跨 `await` 保留，排队取消不启动命令。
- 需要一致视图的快照、配置写入的预检/读取和远端目标核对，同样在相应领域操作的队列内完成。普通独立读取不自动升级为写操作。
- 同一实体仓库共用队列；引擎不再次获取同一队列，避免领域操作中的嵌套命令死锁。配置服务另以全局队列协调应用内的全局配置写入。

读取、本地写入、网络获取、远端写入的区别体现在这些领域入口、可用性和恢复行为中；当前不以推测命令首词的类别枚举替代真实互斥约束。

引擎负责定位已选 Git、构造受控环境、调用 `ProcessRunner`、汇总结果和记录脱敏活动。具体领域服务负责命令参数与成功语义。例如 `diff --exit-code` 的退出码 1 表示存在差异，不能被引擎统一当成执行故障。

所有 Git 命令使用可执行路径和参数数组；消息、补丁等内容通过标准输入传入。禁止借助 `/bin/sh -c` 或 `/bin/zsh -c` 拼接 Git 操作。数组参数仍需处理选项注入、ref 校验、pathspec 语义和目标重验。

UI、菜单、快捷键和命令面板共享 `DomainCommand` 执行入口与 `CommandAvailability`，其中包括可用状态和禁用原因。避免与系统 `AppIntent` 类型同名造成概念混淆。

## 7. ProcessRunner

进程层不理解 Commit、Branch 等领域概念。请求包括 executable、arguments、cwd、environment、stdin、timeout、输出策略和取消策略；结果包括原始 stdout/stderr、退出原因、退出码、耗时及输出是否截断。

必须满足：

1. 异步启动，不在主线程使用 `waitUntilExit()` 等阻塞调用。
2. 并发读取 stdout/stderr，避免某个 Pipe 填满导致死锁。
3. 写完 stdin 后关闭写端，让 Git 或子进程能正常结束输入。
4. 输出按任务设置上限；大输出流式消费，不无限拼接 Data。
5. 解析输入被截断时显式失败或进入大文件流程，不把不完整记录当成完整结果。
6. Clone/Fetch/Push 的进度通常来自 stderr，处理回车更新，并保留阶段而非伪造总百分比。
7. 每次请求只完成一次 continuation；取消、超时和正常退出竞态均有测试。
8. 区分启动失败、非零退出、信号终止、超时、用户取消和输出超限。

### 7.1 取消与超时

排队任务取消后应移出队列，不启动进程。运行中任务先请求终止，等待短暂宽限期后再按策略处理；Git 可能派生 SSH、Credential Helper、Hook 和签名工具，必须验证子进程清理，不能只终止父进程就宣告完成。

Git 写操作取消后，先确认进程结束，再刷新实际仓库和序列操作状态。取消不等于回滚；Push 可能已经在服务端生效，网络断开时结果也可能未知，需要重新核对远端。

不得自动删除不明来源的 `.lock` 文件或用 Hard Reset 清理取消状态。无法安全取消的阶段可以暂时禁用 Cancel，并解释原因。

## 8. 并发与仓库操作队列

### 8.1 操作分类

| 类别 | 示例 | 调度要求 |
| --- | --- | --- |
| 读取 | Status、Diff、Log、Show、Refs | 有限并发；与写入协调，结果带代次 |
| 本地写入 | Add、Restore、Commit、Switch、Merge、Rebase、Stash、引用/配置修改 | 同一仓库排队执行 |
| 网络获取 | Fetch、Pull 的获取阶段 | Fetch 会写对象和远端跟踪引用，也必须进入写队列 |
| 远端写入 | Push | 显式目标并排队；可能同时更新本地跟踪信息 |
| 仓库创建 | Clone | 独立协调器，按目标目录互斥；完成后创建 Session |

Status 可使用 `--no-optional-locks` 降低可选索引更新，但不能因此假定所有读命令都绝无写入副作用。

### 8.2 Actor 重入与显式互斥

Swift Actor 在 `await` 挂起时允许处理其他消息。仅在 Actor 方法中调用 `try await operation()`，并不能防止两个 Git 写操作同时运行。

`RepositoryOperationCoordinator` 必须持有跨挂起点仍有效的队列状态或异步许可：

```text
提交操作 → 进入 FIFO 队列 → 获得唯一写许可
        → 重验仓库/分支/目标 → 执行完整操作
        → 等待进程退出 → 刷新状态 → 释放许可 → 下一个操作
```

许可覆盖整个多步骤操作，包含预检、Git 命令、结果核对和必要刷新。失败、取消和超时均须释放；嵌套服务调用不能再次获取同一不可重入许可造成死锁。

读任务在写入开始时取消或等待；已完成但属于旧代次的读取结果丢弃。必要的写后读取由持有许可的操作内部执行。

该队列只能协调 WeGit 自身。Terminal 等外部工具仍可能同时写入，必须依赖 Git 自身锁和返回状态，在执行前重验期望的 HEAD/ref/index，遇到变化时停止并刷新，不能声称具有跨进程事务隔离。

## 9. Git 可执行文件与环境

检测优先级：用户明确选择 → `/usr/bin/git` → 经验证可用的 Xcode Git → Homebrew 常见路径 → 受控 PATH。记录路径、版本和能力，不只判断文件是否存在。

当前最低为 Git 2.46。隔离的只读探针验证全局/系统/运行时配置的优先级及远端 URL 列表重置能力，版本号满足但能力不符时同样拒绝。测试夹具还必须在任何仓库命令前验证隔离，全局配置测试明确写入私有文件；具体版本矩阵及隔离失效事件见 [兼容性记录](COMPATIBILITY.md)。

Phase 0 决定最低 Git 能力要求。Porcelain v2 等基础能力缺失时，应明确提示升级或选择其他 Git；`switch`/`restore` 可在有专门测试的情况下兼容旧命令，不能无验证地扩展支持范围。

环境构造要求：

- 保留实际用户的 HOME、有效 PATH、SSH Agent 等必要上下文；GUI 启动不保证继承 Terminal 的 Shell 配置。
- 对机器解析优先使用稳定格式；必要时固定 Git 诊断语言，验证对 Hooks、编码和辅助工具的影响。
- 非交互任务设置明确的终端提示策略，如 `GIT_TERMINAL_PROMPT=0`；这不能代替对 SSH、Pinentry 和 Helper 的超时管理。
- 不盲目继承外部 `GIT_DIR`、`GIT_WORK_TREE`、`GIT_INDEX_FILE` 等会改变仓库目标的变量。
- 日志只记录脱敏环境摘要，不能输出完整环境。
- 预览 Diff 默认禁用外部 Diff 与 Textconv；提交、合并等操作尊重已配置的 Hooks/Driver，并让用户可见其失败。

## 10. Git 服务划分

| 版本 | 服务 | 职责 |
| --- | --- | --- |
| P0 | `GitRepositoryService`、`CloneCoordinator` | 仓库发现、打开校验、克隆 |
| P0 | `GitStatusService`、`GitDiffService` | 状态、差异、补丁和文件级暂存 |
| P0 | `GitCommitService`、`GitHistoryService` | 提交、Amend、历史与提交读取 |
| P0 | `GitBranchService`、`GitMergeService` | 分支与合并 |
| P0 | `GitRemoteService`、`GitConfigService` | 同步、认证衔接与配置作用域 |
| P0 | `GitSequencerService`、`GitConflictService` | 检测进行中操作、冲突索引、Merge/Pull Rebase 继续与中止 |
| P0 | `GitSearchService` | 提交查询及与 UI 本地筛选的协调 |
| V1.1 | Tag、Stash、Reset、Cherry-pick、Revert 服务 | 对应操作及恢复流程 |
| V1.2 | Rebase 编辑、Blame、Worktree、Submodule、LFS 服务 | 高级能力，复用已有序列操作基础 |

## 11. 状态解析

推荐机器接口：

```bash
git --no-optional-locks status --porcelain=v2 -z --branch
```

按记录类型解析普通项 `1`、重命名/复制项 `2`、未合并项 `u`、未跟踪项 `?` 和分支头信息。使用固定字段边界加 NUL 路径记录，正确消费重命名项的第二个路径。索引状态和工作区状态分别保存。

冲突来自 unmerged index entries，不来自搜索文件中的冲突标记。二进制或删除冲突可能没有文本标记；包含字面冲突标记的正常文件也不一定冲突。

HEAD 解析须区分 Unborn 和 Detached。未诞生仓库的空历史属于正常状态，不是通用 Git 错误。

## 12. 差异与部分暂存

### 12.1 读取和模型

工作区与暂存区差异使用明确模式，示例命令用于说明读取方式：

```bash
git diff --no-ext-diff --no-textconv --no-color --patch --find-renames
git diff --cached --no-ext-diff --no-textconv --no-color --patch --find-renames
```

实际调用使用参数数组和 literal pathspec。文件清单采用 `--raw -z`、`--name-status -z` 等机器格式辅助获取，不从人类可读 patch header 猜测所有路径。

解析覆盖重命名、复制、模式变化、符号链接、二进制、CRLF、无末尾换行、零行范围和非 UTF-8 内容。无末尾换行标记不是普通上下文行。显示文本不得反向用于重建精确补丁。

未跟踪文件需单独读取；普通 `git diff` 不返回它们。提交差异明确指定父提交；根提交按仓库对象格式取得空树基准，不硬编码 SHA-1 空树 ID。Merge 提交默认第一父提交比较并允许切换。

### 12.2 补丁应用

P0 基于保留上下文的标准补丁，通过 stdin 应用：

```bash
git apply --cached --check -
git apply --cached -
```

取消块级暂存使用对已暂存差异的反向补丁，经过相同校验。不要把 `--unidiff-zero` 作为默认方案；缺少上下文会削弱误应用检测。

差异请求记录 HEAD、索引/文件版本和原始比较模式。应用前在写队列中重新检查基准，再校验与应用。`--check` 和实际应用并非跨外部进程的原子事务，实际执行仍可能失败，必须保留用户内容并刷新。

忽略空白、词级高亮和折叠显示只改变呈现，不能修改应用补丁。无法保证补丁正确的二进制、模式变化或复杂重命名退回文件级操作。

### 12.3 文件级操作和 Unborn

普通文件暂存使用 `git add -- <path>` 的参数形式，结合 literal pathspec。常规取消暂存使用 `git restore --staged` 或经过能力适配的等价命令。

Unborn 分支没有可用 HEAD，不能直接走依赖 HEAD 的 restore/reset。可采用经过验证的仅从索引移除路径方案，保持工作区文件完整；该分支必须有独立集成测试，不能通过强制删除工作区实现。

默认 Discard 的来源是索引，仅还原未暂存内容；同时清除暂存内容须独立意图和确认。未跟踪文件删除走文件系统回收策略。块级 Discard 与 Stage 一样需要版本校验和原始补丁。

## 13. 提交、Hooks 与签名

提交消息建议通过 `git commit --file=-` 的 stdin 传递，不加入日志。配置、Hook 和签名失败不自动绕过。

提交成功以实际结果和 HEAD 核对为准，不能因为 stderr 有文字就判失败。正确处理以下情况：

- 普通提交需要暂存内容；Amend 可只改消息，但必须已有 HEAD。
- 正在 Merge 时的提交与普通提交使用不同可用条件。
- `pre-commit`、`prepare-commit-msg`、`commit-msg` 等影响结果，`post-commit` 等输出不能套用相同失败语义。
- Hook 或外部进程可能改变索引，成功/失败后都重新读取状态。
- Commit & Push 是两个步骤，分别记录结果；Push 失败只重试 Push。
- 不确定结果时先核对 HEAD，不能盲目重试创建提交。

P0 兼容已有 GPG/SSH 签名环境。专门的签名设置 UI 在 V1.1；签名工具、Pinentry 和环境继承在所选分发方式下实测。

## 14. 历史分页与提交图

历史查询明确 refs 范围和排序，建议使用拓扑顺序，首批最多 200 个提交。每轮查询固定起始对象 ID 和查询参数；后续分页不得每次重新以已变化的分支名称为起点。

`--skip` 可用于首版简单分页，但必须在同一固定范围内，避免外部提交造成重复或漏项。大型历史的增量遍历与游标另行验证，不把单个末尾 SHA 当成完整多分支图的通用游标。

不要解析默认 `git log` 文本。字段输出须有明确边界；作者和消息可能包含控制字符，不能无条件相信自选的分隔符。可先获取机器格式 OID/父关系，再通过 `git cat-file --batch` 的长度协议读取对象内容；协议必须有恶意/异常输入 fixture。

`CommitGraphLayoutEngine` 在后台把拓扑数据转换为节点、列、边和分页边界状态。分页间保留 lane 状态；未加载、不可达和浅克隆边界分别表达。自动测试普通链、分支、合并、多父提交、相同时间戳及浅历史。

渲染优先评估 SwiftUI Canvas 与虚拟化行，必要时采用局部 AppKit/Core Graphics。Lazy 容器本身不是性能通过证明。

## 15. 分支、Pull、Push 与序列操作

### 15.1 引用与目标

分支使用完整引用身份，创建名通过 `git check-ref-format --branch` 等规则验证。用户输入的 revision 先解析为有效对象，并处理选项注入与歧义；不同命令的 `--`/`--end-of-options` 支持不能混用。

创建、切换、重命名、删除和合并在写队列内再次核对当前 HEAD、目标引用和工作区。合并检查不能仅依据弹窗打开时的状态。

### 15.2 Pull 与 Push

Pull 策略显式映射：Merge 使用 `--no-rebase` 并遵循明确的快进策略；Rebase 使用 `--rebase`；仅快进使用 `--ff-only`。裸 `git pull` 可能受用户配置改变语义，不可直接等同于 Merge。

Push 使用明确 Remote 与 refspec。Force Push With Lease 固定用户确认时的预期远端 OID，使用 `--force-with-lease=<ref>:<expected-oid>` 等明确条件。仅依赖会被后台 Fetch 更新的跟踪引用，可能削弱用户确认时的保护。

同时固定确认时解析出的有效地址。每条命令使用独立、完整匹配的临时别名做一次 URL 解析，并清空继承的地址列表，防止确认后重写规则变化或多个 pushurl 改变目标。Lease 查询和实际传输采用相同的固定方式；本地换行路径通过编码后的 file URL 保持语义。

认证失败或远端拒绝不得自动重试为强制推送。没有上游时进入目标选择流程；Detached HEAD 不自动猜测推送分支。

### 15.3 冲突与继续/中止

通过实际 Git 目录中的 MERGE_HEAD、rebase 状态目录、CHERRY_PICK_HEAD、REVERT_HEAD 及索引等信息联合判断。不能只解析 stderr。

P0 需要 `none / merge / rebase / cherryPick / revert / unknown` 等可见状态；其中 Merge 与 Pull Rebase 可继续和中止，其余按版本能力提供控制或 Terminal 入口。

「标记已解决」是用户显式把结果写入索引，执行后重新查询未合并项。Continue 依据当前序列类型调用相应 Git 流程，不能用普通 Commit 按钮代替所有 Continue。重命名、删除和二进制冲突也须支持安全的外部解决路径。

## 16. Watcher、刷新与缓存

监听工作区、实际 Git 目录和适用的 Common Git 目录，关注 HEAD、index、refs、packed-refs、配置和序列操作状态。采用 FSEvents、100～300 ms 防抖及事件合并；事件丢失、目录替换或恢复应用焦点时进行完整校验。

刷新范围使用可合并的集合，而非不能组合的单一枚举：

| 事件 | 最低刷新范围 |
| --- | --- |
| 工作区文件或索引变化 | Status、当前 Diff、命令可用性 |
| HEAD 变化 | HEAD、Status、Refs、History、Diff、同步与序列状态 |
| refs / packed-refs 变化 | Refs、History、Tracking |
| Merge/Rebase 等状态变化 | Sequencer、Conflicts、Status、命令可用性 |
| 配置、事件丢失或不明变化 | 有效配置或 Full Refresh |

每个刷新请求携带仓库身份、刷新代次和查询标识。UI 发布前校验：Session 仍活动、对象选择匹配、结果未过期。并发读取并非 Git 原子快照；关键引用读取前后变化时丢弃并重新获取，写入前仍要重验。

自发文件事件在写操作期间合并，不直接忽略；这样同时到来的外部变化不会丢失。写入结束后做一次权威刷新，有新事件则继续下一轮。

缓存按数据类型定键：

- 已提交内容使用仓库身份、对象 ID、父提交和显示参数。
- 工作区差异使用路径、索引/文件版本、请求代次和比较模式，不能仅凭 HEAD 定键。
- 提交图使用固定 refs 集合、查询范围和布局参数。
- 作者头像是可丢弃缓存，远程获取需符合隐私设置。

所有缓存有容量和失效策略。刷新失败可以保留旧数据，但必须标明过期状态。

## 17. 持久化、Sandbox 与认证

SwiftData 保存最近仓库、收藏、窗口状态和每仓库 UI 偏好；轻量全局设置可使用独立偏好存储。Git 身份和策略通过 Git Config 读写，明确 system/global/local 等有效来源与写入作用域。

不把全量 Git 状态作为 SwiftData 权威数据，不明文存储 Token。应用自己的 Token/PAT/OAuth Secret 放入 Keychain；优先复用系统 Helper 和 SSH Agent，不保存 SSH 私钥副本。

Phase 0 已由用户选择 Developer ID 签名、公证后直接分发，当前不启用 App Sandbox。外部 Git、SSH、Hooks、GPG、Helper、仓库外配置和文件访问仍需完成兼容性验证。若后续另行选择 Sandbox 路线，需使用 Security-scoped Bookmark，处理过期和权限撤回，并按 Session 引用计数配对开始/结束访问；书签不能代替外部工具兼容性验证。

图形认证流程需受控 AskPass/Helper 通道：凭证不进入命令行、日志或普通临时文件，交互可取消且有限时。SSH 未知/变更主机密钥需说明验证方式，不自动关闭主机校验。

会话除规范化路径外，还固定根目录、实际 Git 目录及 `.git` 标记的实体身份。普通 Git 写入可更新目录内容，不改变其实体；移动、替换或 Git 标记改指向则要求重新发现仓库。关键写入点与补丁预检后再次核对实体及 HEAD/分支，避免把旧会话的操作施加到同路径的新仓库。重新打开时创建匹配新实体的 Session，并对仍在运行的旧操作保留互斥和错误反馈。

## 18. 错误、日志与恢复

统一错误模型区分 Git、仓库、认证、文件系统、持久化、取消和结果未知。Git 错误包含退出原因、脱敏命令、诊断输出、分类和恢复建议。

常见类别包括认证失败、冲突、非快进拒绝、脏工作区、仓库无效、引用无效、Hook/签名失败、权限不足、锁占用、工具缺失和未知错误。结构化状态优先于错误字符串，语言固定只作为诊断辅助。

`OSLog` 分类建议为 app、git、repository、process、persistence、ui、performance；使用 signpost 覆盖打开、Status、Log Page、Diff、Parse、Graph Layout、First Render。

Activity Store 与系统日志分开，记录操作 ID、仓库、命令摘要、时间、耗时和结果。stdout/stderr 可能包含代码、消息、路径或凭证，详情、持久化和导出均需脱敏和容量限制；不能只脱敏参数而原样保存所有输出。

恢复点记录操作前 HEAD/ref、目标与时间。Reset/Rebase/分支删除的提交恢复信息，不代表未提交文件可恢复；远端操作也不能承诺一键 Undo。修复入口必须与实际可恢复数据相符。

## 19. UI 性能与搜索

Git、解析、语法高亮和 Graph Layout 使用明确的后台执行边界。`Task {}` 可能继承 MainActor 隔离；不能仅因代码写成 async 就认定它在后台运行。具体执行器和隔离规则按所选 Swift 工具链验证。

语法高亮与 Diff Parser 分离，未知语言回退纯文本。大差异先取摘要，分段解析并可取消；TextKit/NSTextView 封装与 Git 层解耦。内存、输出大小与首屏阈值通过性能 fixture 校准并写入配置。

当前读取策略分为自动预检、内存快照与磁盘快照。`DiffReadBudget` 保留自动读取 512 KiB、补丁内存读取 8 MiB、未跟踪预览内存读取 2 MiB 和 100,000 行限制；用户显式加载后超过这些限制时转入 `DiskDiffSnapshot`。`DiskDiffBudget` 对磁盘数据设置 256 MiB、2,000,000 行和 100,000 个区间的上限，超出后保留摘要并解释限制。

磁盘模式将 stdout 流式写入独占创建的私有文件，首次只建立差异块、增删区间和稀疏行偏移索引。分页通过 seek/pread 读取所需区间，并仅保留当前页的文本与高亮。长行只保留有标识的显示前缀，完整数据可导出；显示前缀不能用于重建应用补丁。写操作重新捕获完整差异并比较 HEAD、SHA-256、大小及块成员，再从原始字节范围生成补丁进行预检和应用。

缓存目录按进程区分并限制为当前用户访问。释放快照时异步清理，启动时只回收已不存在进程留下的合法缓存目录；不删除活跃进程、未知命名或符号链接条目。取消和失败只清理本次创建且身份仍匹配的输出。文件读取、索引和复制使用专用后台队列，避免在 MainActor 执行大文件 I/O。

搜索区分已加载数据的本地过滤与 Git 历史查询，采用 150～300 ms 防抖、取消和查询标识检查。日期内部保留绝对时间，UI 按本地时区显示相对时间并提供完整日期提示。

全部性能预算与测量口径引用 [PRD 第 16 节](WeGit_PRD.md#16-性能目标与测量口径)，不维护另一组数字。

## 20. 生命周期

### 20.1 打开

```text
选择目录 → 获取必要权限 → Git 发现与校验 → 规范化身份
        → 复用/创建 Session → 显示外壳 → 建立 Watcher
        → 初始读取 → 发布带代次快照 → 处理读取期间积累的事件
```

Watcher 与初始读取交接不能留下事件空窗；初始加载后至少校验期间是否有变更。数据读取失败不销毁已显示的外壳，应允许重试。

### 20.2 关闭

```text
阻止新操作 → 处理活动写入与等待队列 → 取消读取
          → 停止 Watcher → 持久化 UI 状态
          → 释放权限 → 释放 Session
```

同仓库仍有其他窗口使用时不关闭共享 Session。进行中的写入先提供等待或适用的取消路径，进程结束前不释放必需资源。应用退出也遵循此规则。

### 20.3 克隆

Clone 在无 Session 状态下由独立协调器执行。预先记录目标是否存在、本次创建的目录和操作 ID；完成后校验仓库，再进入打开流程。失败或取消只允许清理由本次操作创建且确认无额外用户内容的目录，并取得删除确认。

## 21. 测试与完成标准

| 层级 | 必测内容 |
| --- | --- |
| Parser 单元测试 | NUL 路径、特殊字符、Unborn、双重状态、重命名、冲突、模式、CRLF、二进制、截断输出 |
| ProcessRunner 测试 | 双 Pipe 大输出、stdin 关闭、退出码语义、超时、子进程、取消竞态、输出上限 |
| 队列测试 | 操作挂起期间第二个写入不启动、排队取消、异常释放、多 Session 别名路径、读结果代次 |
| 临时仓库集成测试 | 部分暂存、Unborn 取消暂存、Amend、Merge/Rebase 冲突、失败保留、Hook、同步和 Lease 拒绝 |
| 历史与图测试 | 固定范围分页、根提交、Merge、多父提交、浅克隆、refs 移动和分页 lane |
| UI 流程测试 | 打开、克隆、暂存、提交、切分支、同步、失败恢复、基础冲突闭环与键盘操作 |
| 性能测试 | PRD 基准、100,000+ 文件/提交、长行、大二进制、多分支、内存与取消响应 |

集成测试使用隔离的临时仓库、测试身份、配置和本地 Bare Remote，避免依赖个人 Git 配置或真实账号。认证兼容性在单独授权的测试环境验证，不把密钥写入 fixture。

每项实现完成必须有适配风险的验证证据。核心状态解析、写操作和并发契约必须自动化验证；无需为简单静态布局机械增加镜像实现的测试。

## 22. 扩展与实施约束

Hosting Provider 独立于 GitEngine，处理账户、PR/MR、元数据和托管平台 URL。AIService 独立处理用户明确选择的内容，不直接调用写操作队列；对外发送代码内容前遵循对应用户授权与数据设置。

实现顺序统一见 [PLAN](PLAN.md)。首版架构验收需确认：所有 Git 入口集中、写队列跨 `await` 有效、快照无过期覆盖、外部修改可见、凭证不泄露、取消可恢复、核心流程经真实 Git 验证。

实现时应对照所选版本的官方语义：

- [Git Status Porcelain 格式](https://git-scm.com/docs/git-status)
- [Git Rev-parse 与路径发现](https://git-scm.com/docs/git-rev-parse)
- [Git Apply](https://git-scm.com/docs/git-apply)
- [Git Push 与 Force With Lease](https://git-scm.com/docs/git-push)
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
