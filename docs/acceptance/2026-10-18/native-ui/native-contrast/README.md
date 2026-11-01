# 内置语义色与设置名称修正

来源：main `bcca7f3` 的 [59 条实际审查](../current-audit/README.md) 与设置原生层级。用户已明确允许调整现有语义色的明度到 4.5:1，保持色相和布局。修正前数据不改写，新候选需独立 UI 验证与最终源码回归。

## 实现范围

- 从当前原生 NSAppearance/sRGB 解析系统色；不足的文字色沿黑/白方向调整明度，不旋转源色相。普通次要/状态文字检查 canvas、增删行和非焦点选择表面，语法文字另检查真正使用的词级高亮层。
- 保留原生表面、边界、字体、字号与布局。内置 primary/destructive/selection 填充使用足够的白字反差余量，选中行计数的 9% 白色胶囊也独立检查。
- 根控件保留原生 accent；填充按钮使用 primaryAction，带彩色文字的菜单单独使用 accentText，选中行使用 selectionBackground。品牌 Logo 的原生蓝不变。自定义主题仍使用用户保存的原色与既有告警，不自动重绘。
- 原生动态色缓存以实际解析组件、背景、词级上下文和目标反差为 key，最多 128 项；外观或系统色改变会产生新的 key，不以外观名称单独缓存。
- 主题、列表密度、代码字体的选择器补明确本地化名称和稳定标识；现有主题/字号用例增加原生名称断言。

## 测得色对

以下为本机只读解析相同 AppColors 后的 alpha 合成比值；实际候选截图、控件与完整回归另行记录。主要文字保持原色，SHA 的自动报告不能靠这张表自动豁免。

| 模式 | 色对 | 修正前 | 修正后 |
| --- | --- | ---: | ---: |
| light | secondary/canvas | 3.9494 | 6.8566 |
| light | positive/added | 2.0583 | 6.3573 |
| light | negative/removed | 3.1409 | 6.0330 |
| light | selected-sidebar | 3.5201 | 6.0000 |
| dark | secondary/canvas | 5.8901 | 8.8315 |
| dark | positive/added | 6.8916 | 7.3812 |
| dark | negative/removed | 4.3822 | 7.9693 |
| dark | selected-sidebar | 3.2337 | 6.0000 |

完整组件值在 `native-pairs-before.json` / `native-pairs-after.json`，计算代码为 `native-color-probe.swift`。该程序只在自身进程解析 Aqua/Dark Aqua，不切换系统设置。

## 验证与当前边界

新增回归在原配色上实际失败，次要文字/canvas 为 3.9494396480:1（`before-regression.txt`）。修正后本机 278 项主题行为检查通过：既有 34 项保留，216 个真实角色/背景色对以及 28 个源色相检查通过；覆盖浅/深与增强对比度的四种 NSAppearance。`local-theme-checks.json` 保留全部名字和值；这不等于切换系统增强对比度已验收。

Swift 6 的 build-for-testing 与严格格式检查通过，本机没有执行 XCTest。一次 1000 次重复颜色解析的 Debug 微测记录在 `local-debug-resolution.txt`，只用于检查新增解析的局部开销，不作为 Release、P95 或完整性能签收。

中间候选 e21b3b7 的托管主题/字号单项均为 smoke 1/1 加 focused 1/1 通过，运行分别为 [39122773595](https://github.com/WeOpen/WeGit/actions/runs/39122773595)（89.502 秒）与 [39123700485](https://github.com/WeOpen/WeGit/actions/runs/39123700485)（45.511 秒）。截图复核发现根 tint 使用填充色会使深色菜单文字变暗，因此撤回该全局用法，针对菜单引入文字角色并追加菜单截图反差断言。上述中间用例通过不构成最终候选通过；最终候选 UI、必需 CI、稳定源码完整功能与独立审查需要重新运行。字号用例仍要求 24pt 字形高度和名称。没有添加辅助访问忽略规则，没有修改系统授权或关闭既有发布门槛。
