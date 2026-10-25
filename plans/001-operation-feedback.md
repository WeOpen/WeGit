# 001 — 准确表达操作结果，并限制反馈动画范围

- **Status**: TODO
- **Commit**: 应用基线 `01d8f93dae51e86b236ca2d5d53e0e9745b49d70`；方案整理 HEAD `a0ab2ba3` 只差 HANDOFF 文档。
- **Severity**: HIGH，结果表达；动画范围风险为 LOW。
- **Category**: Accessibility、Cohesion、Performance。
- **Estimated scope**: 约 8–11 个应用文件及有意义的状态/UI 回归；不修改 Git 服务。

## Problem

`/Users/willxue/will/WeOpen/WeGit/WeGit/DesignSystem/Components.swift:181–195` 对所有非空 notice 使用绿色对勾和单行文本，并把动画挂在可变布局容器上：

```swift
} else if notice != nil {
    Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(colors.positive).accessibilityHidden(true)
        .transition(.opacity)
}
Text(busy ? activity + "…" : notice ?? fallback).lineLimit(1)
    .contentTransition(.opacity)
```

`/Users/willxue/will/WeOpen/WeGit/WeGit/App/AppState.swift:334–352` 只接收 String?：

```swift
operation: @escaping @Sendable (RepositoryService) async throws -> String?
// …
notice = try await operation(pinned) ?? L10n.text("\(name)完成")
```

这会把非完全成功路径也归入成功视觉：

- `/Users/willxue/will/WeOpen/WeGit/WeGit/App/SyncState.swift:197–218` 无论 `result.matches` 是否成立都返回 `result.message`。`WeGitCore/Domain/RemoteModels.swift:118–121` 的非匹配消息明确表示无法判断此前是否推送成功。
- `/Users/willxue/will/WeOpen/WeGit/WeGit/Features/StashBrowser.swift:280–283` 的 `.appliedNeedsReview` 返回「内容已应用，记录列表或删除结果需要核对，请勿重复恢复」及多行原因。
- `/Users/willxue/will/WeOpen/WeGit/WeGit/Features/TagsView.swift:171–182` 的标签核对使用 void `session.perform`；matches/absent/different 都不抛错返回，通用适配会写入成功 notice。`TagSheets.swift:168–173` 的 `TagPushOutcomeUnknown` 另保存 pendingTagPush，必须保持待核对语义。

Stash 的 `.appliedNeedsReview` 不保证记录仍存在。`scripts/StashChecks.swift:357–377` 分别覆盖 beforeDrop/afterDrop：两种情况都保留已应用内容，剩余列表则按真实删除结果呈现。

另有独立状态问题：`AppState.swift:366–401` 的 `commit()` 开始时没有像 `performResult()` 一样清除旧 notice；提交失败/取消后可重新显示前次暂存成功。错误 Banner 仍存在，底层核对和恢复机制仍保留；问题在展示层表达不一致。

尚未运行这些失败场景，不能宣称实际截断位置、用户误读比例或布局掉帧已经证实。

## Target

以明确、可发送的展示结果替代纯字符串；名称建议 `OperationFeedbackResult`，放在应用层，例如 `WeGit/App/OperationFeedbackState.swift`：

```swift
enum OperationFeedbackResult: Equatable, Sendable {
    case success(message: String)
    case needsReview(message: String, details: String?)
    case failure(message: String, details: String?)
    case cancelled(message: String)
}
```

busy 继续来自真实 `session.isBusy` 和 `activityLabel`；idle 使用既有 fallback。结果状态不可由本地化文字匹配或「没有 throw」推断。

| 状态 | 外观与行为 |
| --- | --- |
| busy | 太极 busy indicator + 当前操作文字；不显示旧结果 |
| success | 绿色 checkmark + 本次完成信息 |
| needsReview | 提醒色/核对符号 + 简短结果；完整原因与既有核对入口可达，不能一行裁掉唯一恢复说明 |
| failure | 错误符号/语义色；保留原生 Banner 和错误详情，不显示前次成功 |
| cancelled | 中性取消反馈；写入是否已生效由既有回执/刷新核对，不能宣布「没有修改」 |
| idle | 中性既有状态，不带成功符号 |

仅图标与文本使用现有 `AppMotion.feedback = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.16)` 的 opacity 转场。图标区域预留 12×12 pt；反馈文字容器不动画化 width/height、提交区或 Diff 布局。应用关闭动效或系统减少动态效果时直接显示，保留正确语义。

## Repo conventions to follow

- `AppColors` 已提供 positive、negative、modified、secondaryText；从这些角色派生，不新增主题 JSON 必填项。
- `Components.swift:168–198` 是当前共享反馈入口；稳定 identifier `operation-feedback` 保留。
- `AppState.swift:334–363` 的串行写入、锚定分支、fresh task 刷新与 onIdle 保留。
- `StashBrowser.swift:42` 的 perform 闭包、`StashView.swift:11–14` 的适配器与所有 `performResult` 调用点需同步签名。
- 输入、草稿、错误详情和原生可选择文本身份不因状态展示而重建。
- [004 的钤印](004-traditional-elements.md)仅由明确成功结果与操作上下文触发；品牌图形不表示签名/远端发布，待核对结果不落成功印。

## Steps

1. 固定实施 SHA，复核所有 `notice`/`performResult`/核对型 `perform` 引用。先用私有夹具记录「成功暂存→失败提交」「取消提交」「推送结果不匹配」「标签核对未匹配」「Stash 已应用但需核对」的现状。
2. 增加应用层结果类型；`RepositorySession` 用明确结果存储当前反馈。真实已完成的 void 写操作可映射 `.success`；返回核对结果的 void 调用必须迁移为明确结果，不能因未抛错统一判为成功。
3. 同步结果调用点：Remote `matches == true` 才显示已确认成功，不匹配/缺失保持 needsReview；标签核对只有 matches 为已确认成功，absent/different 保留目标信息与待核对入口。Stash 的 applied/popped 为 success，appliedNeedsReview 为 needsReview，原因保留在 details，并刷新真实剩余列表。
4. 审查所有 onSuccess 回调：结果未核对时不得因此清除 pending-push/pendingTagPush 或关闭核对界面；保留既有真实回执决定的业务处理，不从展示色彩反推结果。
5. `commit()` 与普通操作在开始时清空前次结果；错误/取消路径写入本次结果。取消分类复用 `CancellationError`、`ProcessFailure.cancelled` 等已有类型；已进入 `CommitOutcomeUnknown`/`PushOutcomeUnknown`/`TagPushOutcomeUnknown` 的结果优先保留待核对语义。
6. 更新 `OperationFeedback` 的类型与呈现。把 160 ms 淡化限制在图标/文字，容器和相邻布局即时；为需要核对的长原因提供既有详情面板/可达展开，而不是把所有状态都铺成长说明。
7. 更新中文/英文文案及 AX 名称；成功、需要核对、失败、取消均可区分。保留当前稳定 ID。
8. 只为上述真实状态链和快速切换添加回归，不给每个颜色或常量写镜像测试。新增源文件按现有 XcodeGen 工程规则接入；如共享独立 swiftc 检查依赖到新类型，同步其手写输入清单。

## Boundaries

- 不改变 Git 命令、锁、回执、Stash Apply/Pop 顺序或远端核对算法。
- 不自动重试、不自动 Stash、不清除未核对的 pending 数据。
- 不添加全局 toast 队列、通知中心、声音/触觉或第三方库。
- 不修改实际用户仓库、偏好、凭据或系统辅助访问设置；写入场景使用私有临时仓库与 bare remote。
- 源码若漂移，先重新核对引用与行为，不能照旧行号盲改。

## Verification

实施阶段可本地运行 `bash scripts/build.sh Debug` 编译应用；需要时运行 `bash scripts/verify-themes.sh` 的独立主题检查。不在本地执行 XCTest。

托管原生回归先实际 smoke 1/1，再覆盖：

- 成功暂存后提交失败/取消，提交区不重新显示旧成功。
- 远端核对 matches=false，警告和完整目标可见，pending 不被清除。
- 标签核对 absent/different，以及 TagPushOutcomeUnknown，呈现待核对结果和准确目标，pendingTagPush/核对入口保持。
- Stash 内容已应用但删除需核对，界面可读「不要重复恢复」及原因，已应用字节保持，列表与实际 Git 相同。beforeDrop 记录存在、afterDrop 记录已删除，分别验收。
- 两种主题/关闭动效下，feedback identifier、文字及正确状态均可读。

Feel check：正常速度与逐帧查看 busy→结果→下一次 busy；至少 10 次快速切换。图标/文字淡化不导致输入区、主按钮或 Diff 边界移动；长结果不裁掉唯一行动信息；动画期间输入和取消仍可用。

Done when：正常、警告、失败、取消各有正确本次反馈；原错误/恢复路径仍成立；托管计数、Git 核对、截图/录屏与最终源码匹配。动画是否改善手感以真实观察为准。
