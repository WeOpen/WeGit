# 003 — 验证有效动效数据，再决定是否优化实现

- **Status**: TODO
- **Commit**: 应用基线 `01d8f93dae51e86b236ca2d5d53e0e9745b49d70`；方案整理 HEAD `a0ab2ba3` 只差 HANDOFF 文档。
- **Severity**: HIGH 发布门禁；尚无证据证明太极绘制造成性能问题。
- **Category**: Performance。
- **Estimated scope**: 3–5 个测量/汇总入口、有效性校验和必要的诊断；产品动画修改取决于实测。

## Problem

`/Users/willxue/will/WeOpen/WeGit/WeGitPerformanceTests/LargeReadingPerformanceTests.swift:50–61` 使用 30 次滚动测量，末尾只确认内容存在：

```swift
let options = XCTMeasureOptions()
options.iterationCount = 30
measure(
    metrics: [
        XCTOSSignpostMetric.scrollingAndDecelerationMetric,
        XCTMemoryMetric(application: app), XCTCPUMetric(application: app),
    ], options: options
) {
    for _ in 0..<4 { content.scroll(byDeltaX: 0, deltaY: -400) }
    for _ in 0..<4 { content.scroll(byDeltaX: 0, deltaY: 400) }
}
XCTAssertTrue(content.exists)
```

`/Users/willxue/will/WeOpen/WeGit/scripts/ci/native_performance.py:84` 没给滚动 scope 配置可验证的汇总报告：

```python
("scripts/benchmark-ui-large-scroll.sh", [str(fixture / "large")], "large-scroll", None, None)
```

最新交接记录的滚动专项虽为 1/1、导出 30 次，动画帧数/帧率/卡顿指标全部为 0，且属于 diagnosticOnly。工作流成功不能证明帧数据可用，更不能宣称 60 fps。

同时，普通 Beta 的 Status、Diff、历史存在超预算结果。它们需要独立定位；不把局部动画当成未经测量的根因。

`YinYangLoadingStyle.swift:70` 的固定旋转由 60 Hz Timeline 驱动，每帧重绘 Canvas。12–40 pt 图形的成本可能很小，隐藏/非活动已有暂停保护；目前只记录成本风险，不能据此替换已确定的 Loading。

## Target

滚动和局部动效报告必须分开记录「执行完成」「采集有效」「预算通过」。新增稳定汇总如 `.build/ui-benchmarks/large-scroll-*/scroll.json`，至少包含：

```json
{
  "schemaVersion": 1,
  "diagnosticOnly": true,
  "source": {},
  "environment": {},
  "fixture": {},
  "scenario": { "kind": "scrolling", "expectsFrames": true },
  "expectedSampleCount": 30,
  "samples": [],
  "metrics": {},
  "validation": {
    "collectionComplete": false,
    "frameDataValid": false,
    "withinBudget": null
  }
}
```

每个样本记录序号、有效观察时长、场景、绘制计数、CPU/RSS；预期滚动/运动的区间另记录手势时长、有效帧数、帧耗时/帧间隔及来源、卡顿比例。JSON 示例是目标结构，空数组和 false 并非通过样本。

- 预期产生滚动/运动的测量区间必须得到 30 个有效样本；无穷、NaN、缺字段、零有效帧/零有效时长均为无效，不填造/删选样本。
- 静止、隐藏、非活动和空闲对照声明 expectsFrames=false，以有效观察时长、采集器自检、绘制计数及 CPU/RSS 验证；零重绘可以是正确结果。此时 frameDataValid/帧预算为 null，不从静止对照宣称 FPS 达标。
- **卡顿比例可以为 0**，但必须同时证明有效帧与测量时长存在；不能把「零卡顿」和「根本没有采到帧」混为一谈。
- 原始采集器若不支持当前 macOS/VM，报告 unavailable/diagnosticOnly 并保持未通过；不将所有零值改为成功。
- 原生首屏/启动预算沿用总方案；只有测量定义、刷新率和采集器自检明确后，才对帧数据作结论。视频导出 60 fps 不作为性能指标。

## Repo conventions to follow

- 继续使用 `.github/workflows/native-performance.yml`、可信 main 的脚本、固定候选 SHA、实际 smoke 和私有 fixture。
- `native_performance.py` 已严格重算有效原始样本与预算；新增滚动有效性保持同等强度，不用任意 continue-on-error。
- 原有普通/大型/启动/滚动完整入口保留；独立 scope 明确标为诊断，不替代完整矩阵。
- 不覆写此前失败/缺样本回合，不降低既有延迟预算，不把旧 Beta 输入冒充新 Loading/样式输入。

## Steps

1. 在实施固定源码上读取既有 Scroll.xcresult、metrics 导出和环境回执，核对真实 schema、指标含义和单位。确定是采集器无支持、手势未产生目标指标还是汇总缺字段；不从当前全零值推断产品卡顿。
2. 用私有简单原生滚动控制验证采集器能记录非零帧/时长，再测实际大型 Diff。若 XCTOSSignpostMetric 在此环境不可用，选择可验证的原生帧采集/性能 trace，保留原证据并说明范围差异。
3. 在 `scripts/benchmark-ui-large-scroll.sh` 导出后增加汇总/有效性校验入口，例如 `scripts/ci/verify_scroll_metrics.py`；绑定 build-source、fixture 和准确原生测试计数。
4. 给 `native_performance.py` 的滚动 scope 配置报告路径，并强制检查 frameDataValid。采集或交互无效时停止扩大范围，保留错误；预算失败保持失败，不能仅凭脚本 exit=0 认定通过。
5. 增加解析器的有效/缺字段/NaN/预期运动却全零帧/30 次中缺 1 次/有效零卡顿/有效静止零绘制样例验证；测试的是采集门禁，不是逐个常量镜像。
6. 对同一候选 Release 源码做动效开/关对照，分别覆盖普通更改/Diff/历史、10 次分段反向选择、1 个与多个真实忙指示器、隐藏/非活动窗口及空闲回落。两个设置条件在隔离偏好域内，不修改用户全局设置。
7. 同设备、同 fixture 比较固定基线与候选：至少 30 个有效首屏/启动样本，记录 p95、CPU/RSS、帧数据及上下文。先定位数据读取、原生文本布局、材质绘制等具体成本，避免在已有未通过基线上盲目增加效果。
8. 只有 Canvas 固定旋转的成本确为相关瓶颈时，才比较静态图形加层级旋转等局部实现；视觉必须仍是完整太极匀速每圈 2.8 秒，确定进度与静态/AX 分支保持。无稳定收益则保留现有实现。

## Boundaries

- `scripts/benchmark-ui-large-scroll.sh` 执行 xcodebuild test，**只能用于托管环境，不在本机运行**。
- 不修改真实用户仓库、全局 Git 配置、用户偏好、系统显示/辅助访问/安全设置或一般 GPG 服务。
- 不关闭实际用户 WeGit；诊断包通过完整路径选择，保持源码/包身份独立。
- 不把本机 CUA 采样替代托管 XCTest，不跨缺样本拼出一轮有效 30 次。
- 不因为控制版也失败而豁免候选，不修改太极时序来降低成本。
- 产品修改只在测量明确之后进行；本计划不会直接添加第三方动画引擎。

## Verification

实施阶段可在本地验证报告解析器、编译应用与性能目标；本地不运行 XCTest。新增报告门禁先通过私有数据的独立解析验证，再正常经 PR/CI 集成至可信托管入口。

Feel check：在真实原生窗口观察滚动、快速反向选择、加载出现/消失与场景切换，使用正常速度和慢放/逐帧。确认代码可读、焦点/选区稳定、没有额外循环时钟；视频只支持视觉检查，性能结论使用采集器数据。

Done when：采集器自检有效，最终源码拥有完整有效的运动样本及静止对照、明确预算结论；预期运动却零帧、缺样本、控制/候选差异均可审计；隐藏/非活动 Loading 没有持续绘制。若环境仍无法提供有效帧指标，保持未通过并记录限制，不伪造「流畅」结论。
