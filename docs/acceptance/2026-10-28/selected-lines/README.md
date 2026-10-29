# 选中行暂存/取消暂存开发证据

需求 #70；功能分支 codex/v1.2-selected-lines。固定原始差异、HEAD/分支、索引与目标工作文件，私有对象目录和临时索引生成候选；执行持有 index.lock、重验并原子安装，回执不确定时不自动重写。

- 独立检查重新执行 99 项：72 个逐字节选择组合（零/三行上下文、CRLF、无末尾换行、Unicode、多块）、13 个预演/陈旧快照/索引锁/并发写入、14 个新增删除/未诞生分支/转换守卫。
- 原生 CUA 确认预览和 Escape 取消保持原索引字节；Unified 单选 B 仅使 index 为 a/B/b/c/d；修复分组身份后，Split 只取消 B，index 回到 a/b/c/d。工作文件 a/B/C/d 和 HEAD 保持原样。专用预览空闲 CPU 0%，RSS 106128 KiB 的单次诊断；不是 Release 完整性能验收。
- DiffTextSelection 的弱引用登记不参与 Observation，保留首次 100% CPU 失败采样。适用差异的动作区固定高度，避免跨行拖选途中代码纵向位移。
- swift build --build-tests 与 xcodebuild build-for-testing 已成功；本机未执行 XCTest。新增核心/原生用例仍需托管实际执行。
- 可信 main 的 selected-lines 白名单通过独立 PR #72 集成，只允许一个固定方法，必须先实际 smoke 通过。

本批不包含选中行丢弃、工作文件编辑或跨文件批量写入。二进制、符号链接、gitlink、mode/rename、split index、clean filter 或无法逐字节重现的转换保留文件级入口。完整最终回归、Release 开销和发布门禁继续跟进，不能把开发构建或本机 CUA 当作托管验收。


- 首轮托管 run 40806321814：smoke 实际 1/1、0 失败/跳过；selected-lines 专项实际 1 项、0 通过/1 失败/0 跳过，在部分暂存后的 checkbox.value 字符串强转断言失败，后续步骤未执行。已有原生用例与控件使用数值 1/0，现保持相同状态断言并改为 Int；不删检查或放宽结果。
- 必需 CI 40806104965 在 OnlyOneTrailingClosureArgument 格式检查处失败，后续核心/构建步骤未执行。该规则不会由自动格式化全部修复；显式 operation 参数后重新执行严格 lint。旧运行和原始 xcresult 保留，修复后的托管验收仍待真实结果。


- 第二轮原生 40810107371：smoke 1/1，专项 0/1、1 失败、0 跳过；已越过 checkbox 1/0 与单行暂存检查，失败是查询不存在的 SegmentedControl 容器。现沿用既有原生用例的 RadioButton「统一/分栏/Unified」切换，不改产品布局或删掉后续范围、重开及陈旧确认断言。
- 固定 82b56dc 的 Swift package Release CLI 30 个有效样本全部逐字节核对：5000 行、三处替换，只选择一处，其他已暂存内容、工作文件和 HEAD 不变。prepare/execute p95 93.140583/121.103875 ms，预先沿用后台入口 2000 ms 预算。该结果仅为后台 CLI 诊断，不能代表原生界面或完整 Release 性能通过；初次临时测量表达式触发 Swift 类型检查超时，拆分为显式循环后编译和运行完成。
- #75 的移除预研确认 Git 2.54 默认 worktree remove 会以成功状态删除 ignored 内容，不能凭普通 status 干净直接删除。私有同卷目录先经 Git move 更新登记，再保留文件、移除私有空路径登记，九项保护断言通过，原路径后来出现的外来目录与晚到 ignored 文件均保留；单次 22.55 ms 只作预研。首个夹具路径断言受 /var 与 /private/var 别名影响，改用规范路径后 NUL/中文/换行检查通过，不改产品或放宽身份保护。


- 第三轮 40813349194 的 smoke 1/1，selected-lines 0/1、1失败、0跳过。外部编辑后 Core 拒绝陈旧快照，但局部确认 sheet 随差异刷新销毁，第90行的 Close 等待失败；最后的字节/草稿断言尚未执行。原报告和 xcresult 保留。
- 确认请求已迁到稳定 AppState/WorkspaceView，绑定原仓库会话与 UUID。失败反馈留在原确认窗口，成功按 UUID 关闭，切仓库清理旧请求。本机 Debug build-for-testing、严格格式/策略与4项 Git helper 通过，171项源码输入匹配，详情 stable-sheet-build.json；实际托管重验仍待运行。


- 修复候选3f94994的托管40820141087已下载：smoke与selected-lines各1/1、0失败/跳过，171项输入逐项匹配。全部原断言执行至最后，陈旧索引/外部字节/无lock/草稿/HEAD检查通过；三张原生截图已检查，英文深色失败时确认窗口、错误和Close均保留。hosted-40820141087.json与screenshots/保存实际证据。当前完整必需CI 40820061103仍在进行，最终回归/Release验收继续。

- 3f94994的必需CI 40820061103已全部成功；Apple、最低Git2.46、Homebrew各226项/41 suites通过。新的收尾提交只加入实际验收/截图和执行状态，应用、Core、UI/核心测试输入均与该候选相同；收尾HEAD的必需检查仍要实际通过后集成，不沿用旧检查状态。
