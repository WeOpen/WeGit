# WeGit 开发交接

新任务先读本文件，再核对 Git 工作区、Issue/PR 与当前源码；历史结果只适用于其记录的源码。

## 目标与约束

- v1.1 四项必选：Stash、仓库级 Remote、Tag、文件历史与定向搜索。Cherry-pick/Revert 仅在恢复路径和回归具备证据后纳入，否则明确后移。
- 用户要求持续开发到完成。按仓库 Issue → 分支 → PR → 必需 CI 的流程集成，不能把创建 PR 当成版本完成。
- 本地不执行 XCTest。独立行为检查可运行；核心/UI 测试可以编译；实际 XCTest 放在托管环境。
- 所有 Git 写入验收使用私有临时仓库和本地 bare remote，隔离 global/system Git 配置。不能修改个人仓库、真实凭据或系统安全/辅助访问状态。
- Beta/发布需固定源码与制品来源，包含性能预算和实际测量。外部 Beta 反馈、受保护 Mac 安装与完整发布门禁不能用构建结果替代。
- UI 少用次级标签和重复解释；复杂阶段报告以 HTML 呈现。`answer-me-with-html` 已安装于 `/Users/willxue/.agents/skills/answer-me-with-html`；2026-10-23 验证 CLI 0.5.7，并成功生成 TCP 三次握手页面。搜索符号链接目录需用 `rg --files -L`，报告由其 `scripts/am.mjs` 生成。

## 已确认的陷阱

### Stash

- Stash 编号会随外部增删变化。确认时保存对象与列表快照，写入前重验。Pop 要先 Apply，成功才删除；冲突时保留记录。
- Git 全局 `--literal-pathspecs` 会影响 stash 内部的 untracked 清理。仅对没有路径参数的 stash 命令关闭该选项；其他调用保留默认保护。
- 普通 status 看不到 ignored 目录内的私有内容；不能用“工作区干净”证明可安全覆盖目录。特殊索引标记、文件/目录替换和符号链接父目录需单独检查。
- 外部删除非首条 stash 可能只改 `logs/refs/stash`。它必须触发列表刷新，不能和普通 logs 一起忽略。
- Apply 成功后删除超时，应返回“内容已应用，需核对删除结果”，避免界面引导再次恢复。删除回执需核对实际移除对象。

### 原生验收

- build-for-testing 只表示编译通过。smoke 必须实际 total=1 / passed=1 / failed=0 / skipped=0，并保留源码回执、xcresult、日志和环境记录。
- 候选 PR 原生诊断由可信 main 的脚本选择不可变 SHA，仅允许 smoke + 明确列出的单用例；新诊断入口需正常经过 PR 集成，不能在本机执行 XCTest 或绕过可信脚本。
- M0 托管 run 39385290549 是 48 总数、45 通过、3 失败、0 跳过。由 #41 跟踪；旧版本成功不关闭这三个失败。
- M0 侧栏失败截图中圆形材质边缘存在。旧像素断言只采样半径 14 pt 的透明内部；实测半径 17–18 pt 有可见差异。修复断言后仍需托管重验。
- Changes 分组含独立复选框与折叠 Button。测试不应点击不可命中的整条 OutlineRow；需定位实际折叠按钮并保留文件选择/草稿断言。
- 工具栏 AX 容器和实际按钮可能有不同尺寸。52 vs 36 pt 的失败仍需活动/截图与控件诊断确认，不能直接放宽尺寸断言。

### 工具与托管队列

- `npx skills add` 直连 GitHub 也可能长时间停在克隆阶段。本次安装通过当前子进程的 `HTTPS_PROXY` / `HTTP_PROXY` 使用 `scutil --proxy` 已确认的系统代理后成功；不要因此修改全局配置。
- Git CLI 直连 GitHub 可能超时，而系统已配置 HTTPS 代理。只为当前子进程读取并使用 `scutil --proxy` 的代理，不改全局 Git 配置或系统网络设置。可复用本轮 `.build/with-system-proxy.py`。
- GitHub concurrency 即使 `cancel-in-progress: false` 也只保留一个 pending。连续 dispatch 多个原生诊断会取消较早的 pending，不能当成多个测试已排队成功。等当前运行和 pending 都结束后逐个 dispatch；取消的 run 保留原结论，重新调度尚未执行的范围。当前 `.build/queue-native-diagnostics.py` 串行处理恢复、分组与侧栏诊断。
- Remote 配置按最后一个点分隔 Git subsection/变量。`origin.child` 必须独立于 `origin`，不能用字符串前缀归组；新回归最初失败，修复后通过。
- 配置写入使用私有候选文件、`config.lock` 和锚定 Git 目录描述符的 `renameat`。失败不能留下半次 URL 修改；继承、include 来源、多地址与凭据地址不交给简单编辑器覆盖。

- 托管环境的 Touch Bar 也会暴露“取消”按钮。`app.buttons["取消"]` 会命中多个元素；取消 sheet/alert 时应限定到 `app.windows["main"].sheets.firstMatch`。Stash 恢复专项的第一次失败即由此引起，未证明产品恢复失败。

### Tag

- XCTest 的字符串下标查询限制 128 个字符；托管 sandbox 内的完整临时路径常超过此限。Tag 推送 39871570623 已到达端点确认，失败是把长地址当查询 identifier。数据文本用明确属性的 NSPredicate 查询，控制组件仍用短稳定 ID。

- 远端冲突夹具先把另一个附注对象传入 Bare 仓库，再修改引用。首次托管核心运行 200 项中 199 通过，失败在测试夹具试图将远端引用写到其尚未拥有的对象；这不是产品推送失败，需保留失败记录并修正夹具后重跑。

- Git 的默认标签附注清理会删除 `#` 开头的正文；创建附注需显式 `--cleanup=verbatim`，保留最初失败与修复后的检查。
- 推送必须比较原始标签对象，不能只比较剥离后的提交：同一提交的不同附注仍是不同已发布标签。显式单对象 refspec，并关闭 followTags/mirror，避免附带其他标签。
- SwiftUI 相邻 Text 可能合并为一个 AX 元素；目标 SHA 需在明确的语义容器上标识，避免假设每个 Text 都是独立 StaticText。
- 本机 GPG 脚本编译通过，但缺少要求的 Homebrew 工具，行为检查以 78 退出；不回退、不安装。真实附注签名由托管 CI 的私有临时密钥检查。

### 文件历史

- 新核心用例首次托管运行 204 项中 203 通过，失败在夹具重复暂存已由 `git mv` 暂存的重命名。`Fixture.commit()` 会先暂存所有状态路径；已暂存的 mv/rm 夹具应直接调用 service.commit，不能再次对已不存在的旧路径 git add。修正只涉及夹具，原跟随/分页/消息断言保留。

- 目录只有一个发生变化的子文件时，Git 仍可能返回单条记录。不能仅凭记录数量判断输入是单文件；路径链第一条必须与输入的旧/新文件路径精确对应。新增目录夹具验证这一保护。

- `git log --follow --skip=N` 会在跳过重命名输出后丢失更早的文件名；消息过滤排除重命名提交也会丢历史。最初夹具明确漏掉根提交。先获取有界的完整路径元数据，再对精确 OID 使用 `--no-walk` 筛选，按快照分页读取提交对象。不要把普通历史的 skip 分页直接复制过来。
- 文件名可含换行、中文和 pathspec 字符；按 NUL 和状态记录解析，不能 trim 或按行切路径。Merge 记录及 Diff 固定相对真实第一父提交，保留分支内的修改；根提交用空树，重命名比较传入旧/新两个字面路径。
- 性能必须覆盖首次路径链建立；5000 条夹具对首次文件查询与现有历史入口各采样 30 次，不能只测已缓存后的页读取。元数据限制 8 MiB/100000 条，单页最多 200 个对象，过大明确报错。

## 当前入口

- 进一步原始回执纠正前述换行猜测：39871992940 的截图/Git 配置是获取 B、推送 A，但 `remote-fetch-value.value` 确实仍为 A。独立 `Tools/SelectableTextControl` 复现普通可选择 Text 的 AX 缓存旧值；`.id(value)` 与显式 `.accessibilityValue(value)` 均随渲染更新到 B。Remote 采用显式当前值以保留原生文本身份/选择；原用例恢复逐字核对整个地址，等待托管重验。

- Remote 39869429918 的 Git 双地址编辑断言通过，失败录像清楚显示获取地址为 `ui-remote-b.git`、推送为 `ui-remote-a.git`；原生可选择文本会按行显示长地址。地址核对限定当前 Sheet 的第一个精确 ID，并保留 value/title/label 原文与截图；只对不含换行的已知夹具去除展示换行，仍逐字比较整个地址，不仅比较末尾文件名。

- 可选择的 macOS StaticText 通过 `value` 暴露内容，不能统一读取 `label`。Remote 39868575930 已完成新增/取消/双地址编辑，Git 配置断言通过；随后 UI 地址断言因读取空 label 失败，AX 树明确有 `remote-fetch-value` 的内容。下一轮改为等待 value 与目标 URL 一致，仍保留实际 UI 与配置双重核对。

- macOS 原生 MenuItem 的可见文字在 XCTest `title`，`label` 可以为空。39867675289 的完整 AX 树显示 `title: 拉取 3 / 推送 2`，不能用空 label 推断数量丢失；改为核对实际 title。Remote 39866914102 的 `toolbar-more` 是 MenuButton，查询需按稳定 ID 取对应元素，不能限定 Button 类型。
- Stash 恢复专项 39867246375 在候选 `f422aa6` 实际 1/1 通过、0 失败/跳过，包含取消、成功 Pop、冲突保留与外部删除刷新；完整最终源码回归仍单独执行。

- 原生专项 39817031571 的 Stash 取消已命中主窗口 Sheet，之后再次点击的确认框未出现；保留录像/AX 树，下一轮先等待 Sheet 实际消失，不能仅凭取消点击返回判定动画结束。工具栏 39817654141 的表面尺寸断言全部通过，失败位于紧凑同步菜单标签；新增菜单截图和 AX 内容诊断，原数量断言保留。

- 总计划：`docs/V1_1_PLAN.md`；总任务 #35。
- Stash：#36 / PR #42；验收快照 `docs/acceptance/2026-10-22/stash-management/`，更新结果看 PR 与 Actions。
- Remote #37，Tag #38，文件历史 #39，M0 回归 #41。
- 原始 CI 和本机中间产物在 `.build/`，不整体提交；仅保存必要、脱敏、可复核的结构化证据。

## 2026-10-23 托管 UI 定位补充

- run 39810342148 的分组专项通过，run 39810816133 的侧栏专项通过；各自先执行并通过 smoke。待最终源码完整回归。
- run 39808983520 确认 `toolbar-repository` 的实际 AX Button 仍报告 44×52 pt。原始视频实测各表面高度为 34–36 pt，AX 容器高度不能当作可见材质尺寸。新断言用截图的可见边缘比较高度，并保留点击与垂直对齐检查。
- 像素采样须排除 window 外部。否则标题栏上方的黑色桌面会被误判为控件边缘。保留原图、诊断失败和采样结果，不通过放宽 AX 高度容差接受 52 pt。
- run 39809921471 的 Stash 恢复专项首先失败在“取消”按钮匹配：Touch Bar 和 alert 各有一个。将点击限定到 main window 的 sheet；该失败未证明产品 Pop/冲突失败，后续恢复步骤尚需执行。
