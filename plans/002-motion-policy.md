# 002 — 按输入来源更新分段控件，并统一现有动效 token

- **Status**: TODO
- **Commit**: 应用基线 `01d8f93dae51e86b236ca2d5d53e0e9745b49d70`；方案整理 HEAD `a0ab2ba3` 只差 HANDOFF 文档。
- **Severity**: MEDIUM；token 归并为 LOW。
- **Category**: Purpose & frequency、Interruptibility、Cohesion。
- **Estimated scope**: 主要 2 个共享组件文件及分段控件行为回归。

## Problem

`/Users/willxue/will/WeOpen/WeGit/WeGit/DesignSystem/GlassControls.swift:243,268–270` 对每次 selection 变化应用 matched geometry 弹簧：

```swift
tabLens.matchedGeometryEffect(id: "selection", in: lens)
// …
.animation(
    reduceMotion || !preferences.interfaceMotion ? nil : .spring(response: 0.28, dampingFraction: 1),
    value: selection)
```

同文件 `TransparentSegments.keyDown`（346–362）立即发送新的 selection：

```swift
selectedSegment = next
sendAction(action, to: target)
```

键盘、鼠标和程序更新没有区分；设置分类、Diff 布局、搜索范围都复用此组件。选择和内容已经即时更新，不能称为键盘执行延迟；问题是高频方向键也驱动额外背景运动，实际显著程度还需录屏。

`/Users/willxue/will/WeOpen/WeGit/WeGit/DesignSystem/AppStyle.swift:15–18` 已有 feedback/reveal token；hover 的 `.easeOut(duration: 0.12)` 和选择 spring 仍各自内联。不同现有曲线是合理用途区别，不等于它们已经审美不一致。

## Target

保留当前已确定参数，在 `AppMotion` 中增加语义名：

```swift
enum AppMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let feedback = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.16)
    static let reveal = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.28)
    static let selection = Animation.spring(response: 0.28, dampingFraction: 1)
}
```

| 更新来源 | 模型/内容 | 选中背景 |
| --- | --- | --- |
| 鼠标直接选择 | 即时 | 允许时使用 AppMotion.selection，可中断接续 |
| 方向键/键盘激活 | 即时 | 即时 |
| 辅助访问激活 | 即时 | 即时 |
| 外部偏好/程序更新 | 即时 | 即时 |
| 关闭动效/减少动态效果 | 即时 | 即时，保留静态选择与焦点 |

`response: 0.28` 是弹簧响应参数，不是固定 280 ms 总时长。不要改成明显回弹，不增加全页转场。

## Repo conventions to follow

- 保留 `NSSegmentedControl`：它拥有命中、原生 AX radio、方向键和焦点；SwiftUI 只画轨道与 lens。
- 保留 `TransparentSegments` 现有键盘焦点描边、selection 下标保护和即刻 sendAction。
- 鼠标点击/AX/程序更新不能依赖延时猜测来源。用桥接层在 mouseDown/keyDown 调用栈内显式传递输入来源；来源缺省视为即时。
- WorkbenchAppearance 已对主题切换取消动画；菜单栏 popover 已 `animates = false`。不覆盖这些明确选择。
- 颜色、透明度、高对比度、稳定 identifier 及原生事件不改。

## Steps

1. 复核实施 SHA 的共享 Tabs 与使用点，记录 Diff、搜索范围、设置分类的鼠标/左右键现状。
2. 在 `AppStyle.swift` 扩展上面的 hover/selection token；把现有内联参数换成对应 token，保持数值不变。
3. 给 `TransparentSegments` 增加输入来源状态或明确回调参数。mouseDown 调用链标 pointer，keyDown 标 keyboard；调用结束恢复缺省 immediate。AX/程序事件没有 pointer 标记时必须即时。
4. 在 `GlassSegmentInteraction.Coordinator.select` 将来源传回共享 Tabs；业务 selection 的写入使用禁用动画的 Transaction，不能等 lens 移动后再写值。
5. 为 lens 单独维护展示选择或等价局部状态。只有 pointer 且动效允许时，用 `AppMotion.selection` 更新该局部状态；文本/业务内容仍按真实 selection 即时显示。移除目前覆盖整个 selection 的 blanket `.animation`，避免把业务写入 Transaction 重新动画化。
6. 外部 selection 变化、键盘、AX、关闭动效/减少动效时立即同步 lens。局部展示选择已经等于目标时不重复写入，避免 onChange 抵消同一次鼠标动画。
7. 连续鼠标反向选择使用原生持久弹簧接续，不用 Timer、固定关键帧或输入锁。该组件保持现有 init 参数和所有稳定 ID。
8. 审查当前自定义动效的偏好判定，保留 `interfaceMotion && !accessibilityReduceMotion` 规则；不为 token 归并改变欢迎、反馈或太极时序。

## Boundaries

- 不重写主窗口、检查器、Settings 容器或原生菜单。
- 不把程序更新/AX 当鼠标，也不通过局部时间窗口猜事件。
- 不添加重型状态管理、第三方 spring、循环背景、声音或触觉。
- 不为色彩/参数常量增加镜像测试；回归关注键盘、AX、模型状态和可中断性。
- 当前源码与引用若变化，先更新计划，不盲改旧代码。

## Verification

实施阶段可运行 `bash scripts/build.sh Debug` 以及依赖相关的 `bash scripts/verify-themes.sh`；只编译原生测试，本地不执行 XCTest。

Feel check（独立原生样册/私有夹具）：

- 鼠标左右连续选择至少 10 次：lens 从当前位置接续，无跳回起点、无回弹越界；内容始终对应最近一次选择。
- 按住左右方向键：焦点、选择、内容与 lens 同步，不出现拖尾，也不等待旧动画。
- 用 AX 激活及外部偏好更新：静态即时到位，radio 语义/名称/值正确。
- 动效开/关及减少动态效果分支：选择和焦点继续可见；不修改用户系统设置来造验证条件。
- 浅深色/减少透明度/高对比度：轨道与 lens 清楚，无双重焦点边框。

托管用例先实际 1/1 smoke，再验证三个真实使用点的键盘、点击和关闭动效行为；保留 AX、截图/短录屏与最终源码。逐帧检查可辨别即时 lens 更新；不以静态截图推断动画时长。

Done when：业务状态即时，只有明确的鼠标选择使用局部弹簧；反向操作连续；原生焦点/AX/快捷键不回退；没有新增参数漂移或持续时钟。
