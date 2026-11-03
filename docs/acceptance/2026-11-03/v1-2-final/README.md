# WeGit v1.2 固定源码取证

V12-01～V12-09 的实现已进入 main。PR #102 按三项必需检查正常合入 `126ca20c908b58a80a00b5eb9ce081e388cd01e4`，该固定主线的原生 smoke 为 1/1/0/0，完整 functional 为 **69 总 / 69 通过 / 0 失败 / 0 跳过**；主线 CI 的三套 Git 各 266 项 / 47 组及 450 个有效原始性能样本通过。正式发布验收沿用[维护者确认的延期条件](../../2026-11-01/v1-2-closeout/README.md)。

该主线整个 Git tree 与已验证候选 `fa60ffd6fa9d7aa47b76e7a100ee25f645e0ba24` 一致，[源码等价回执](integrated-source-equivalence.json)保留实际来源。本目录是开发验证记录，保留旧失败、当前警告和正式验收边界。

## 已验证候选的五个原生专项

每项实际执行 smoke 和唯一白名单方法，均为 1 总 / 1 通过 / 0 失败 / 0 跳过。194 个应用/Core/资源输入与 33 个测试及辅助输入分别核验；完整 ZIP 大小、SHA256、CRC、直接 xcresult、运行方法、原限时和显示恢复均记录在对应回执。

| 专项 | 运行 | 方法秒数 | 原始取证回执 |
| --- | --- | --- | --- |
| feedback-commit | [41565334788](https://github.com/WeOpen/WeGit/actions/runs/41565334788) | 94.499 | [verified](feedback-commit-verified.json) |
| feedback-push | [41574062149](https://github.com/WeOpen/WeGit/actions/runs/41574062149) | 71.113 | [verified](feedback-push-verified.json) |
| feedback-tag | [41574717412](https://github.com/WeOpen/WeGit/actions/runs/41574717412) | 83.786 | [verified](feedback-tag-verified.json) |
| feedback-stash | [41575377571](https://github.com/WeOpen/WeGit/actions/runs/41575377571) | 117.578 | [verified](feedback-stash-verified.json) |
| settings-lifecycle | [41564070167](https://github.com/WeOpen/WeGit/actions/runs/41564070167) | 31.030 | [verified](settings-lifecycle-verified.json) |

32 张截图与 31 份文本附件已审阅。窗口请求 980 时首次实际宽度为 1191，后续实际 980 与 1360 帧及侧栏显示/隐藏/恢复均已核对；文件名不代替真实 frame。Stash 保留应用后的工作文件和索引字节、删除前后的真实列表及“请勿重复恢复”；Tag 使用附注标签对象核对，Push 只在目标匹配后解除待核对状态，二者保持一次应用推送；Commit 保留草稿与一次恢复后的提交。120 秒方法 / 180 秒 summary 的专项边界保持。

Git 帮助取证保留原始 HelpTag 图像，独立工具从实际像素核对 Git 2.46+。沙盒 runner 内的 Vision 模型加载失败保留原失败；配置写入、退出阻止、取消恢复和原配置值均在真实 XCTest 中完成。本机没有运行 XCTest，也没有修改系统权限。Settings 的 QoS 运行时警告保持在原回执。

## 当前候选 CI 与原始性能数组

[CI 41563843830](https://github.com/WeOpen/WeGit/actions/runs/41563843830)的完整 13,401,212 bytes / SHA256 `cb44fc22989c587483e239166f30bdfdeff95e579c5f346c845fc0e880fc3647` / 39 CRC 项已核验。三套 Git 各 266 项测试 / 47 组通过；隔离签名 9+9、取消读取模型 64 项通过。359 个包来源与 194 个普通 Release 应用输入、包内外构建回执和开发包摘要均匹配。[完整重算回执](candidate-ci-verified.json)与[下载校验](candidate-ci-download.json)保留各自来源。

五份报告各保留 ordinary / large-loose / large-packed 或已定义 Worktree 负载各 30 个有效样本，共 450 个；全部 P95 从原始数组重算并通过原预算。

| 原始报告 | 样本 |
| --- | --- |
| [conflict-editor-performance](conflict-editor-performance.json) | 90 |
| [interactive-rebase-performance](interactive-rebase-performance.json) | 90 |
| [rebase-performance](rebase-performance.json) | 90 |
| [submodule-lfs-performance](submodule-lfs-performance.json) | 90 |
| [worktree-read-performance](worktree-read-performance.json) | 90 |

Core 的 RSS 范围按原报告定义，不包含子 Git；这些专项数据保留各自原预算和编译模式。最终整版普通 Release UI/Instruments、完整 VoiceOver、真实硬件/账号/LFS 服务、专用验收机、受保护 Mac 安装/迁移/回退及外部 Beta 的未验条件继续归入 #3/#4/#5/#6/#7/#9 的明确延期。

## 固定 main 的 CI

[主线 CI 41576890379](https://github.com/WeOpen/WeGit/actions/runs/41576890379)已成功，其 13,400,771 bytes / SHA256 `bba6e75eb90eecc7af4d79c8490e24c11be90b1e37adbcab07966fb0cf040e40` / 39 CRC 项原始 ZIP 完整核验。三套 Git 各 266/47，9+9 隔离签名和 64 模型检查通过；五份共 450 个有效原始样本按原预算独立重算通过。所有包来源和 Release 回执匹配实际 main `126ca20`，不是合成 PR 源。开发包 SHA256 为 `b2c85a413b5004901caed78583d5cd6e98996a2eb4506f6cdeeaf88fe5df556c`，见[主线完整回执](main-ci-verified.json)及[下载校验](main-ci-download.json)。

主线五份原始数组以 `main-` 前缀保存，前一候选数组保留原来源；各自的输入摘要与预算独立核对。

| 主线原始报告 | 有效样本 |
| --- | --- |
| [conflict-editor](main-conflict-editor-performance.json) | 90 |
| [interactive-rebase](main-interactive-rebase-performance.json) | 90 |
| [rebase](main-rebase-performance.json) | 90 |
| [submodule-lfs](main-submodule-lfs-performance.json) | 90 |
| [worktree-read](main-worktree-read-performance.json) | 90 |

## 完整主线回归与收尾

固定 main 的[完整 functional 41577046313](https://github.com/WeOpen/WeGit/actions/runs/41577046313)实际通过。完整制品 `13207258080` 为 296,521,012 bytes，SHA256 `8d2f90cc961917fae6d140f02938a2c7f9cdea46288392c6ca18f06846785887`，2,953 个 CRC 项均通过，见[完整核验](main-functional-verified.json)及[下载校验](main-functional-download.json)。

直接读取 xcresult 得到 [smoke 1/1/0/0](main-smoke-summary.json) 和 [functional 69/69/0/0](main-functional-summary.json)。69 个唯一实际方法与[精确方法清单](functional-inventory.json)完全匹配，194 个应用/Core/资源输入、33 个测试及辅助输入与可信入口文件均匹配固定 main，见[构建来源](main-functional-build-source.json)。源码共 71 个方法，既有单独登记的手工/audit 两项保持分开。原限时、4 个实际 Git wrapper 检查和显示恢复均核验；未修改系统权限，未执行本机 XCTest。

原生结果保留 330 份附件，阅读矩阵 144 个预期标签逐一匹配。实际查看 **45 张原图，其中阅读矩阵 16 张**；抽查覆盖 11/24 pt、980/1460 实际窗口、内存/磁盘路径、Unified/Split、浅/深色及两种密度，同时核对 Blame、Stash、Tag、Submodule/LFS、Interactive Rebase 和 Settings。全部抽查原图按字节复制，原始附件名、PNG 尺寸、SHA256、范围和逐组观察保存在[截图审阅回执](main-functional-visual-review.json)。这不等于逐张目视审阅全部 144 张。

| 原图样例 | 核对内容 |
| --- | --- |
| [Blame](main-native-images/BlameWorkflowTests-003.png) | 原提交字节、作者、跨行选择与分页 |
| [Submodule/LFS](main-native-images/InspectorRestorationTests-004.png) | 模块状态、指针对象和获取入口 |
| [Stash](main-native-images/OperationFeedbackTests-020.png) | 980 窗口恢复侧栏后的列表、内容和完整反馈栏 |
| [Tag](main-native-images/OperationFeedbackTests-028.png) | 980 窗口恢复侧栏后的待核对对象及核对/关闭入口 |
| [磁盘 24 pt / 980 / Split](main-native-images/ReadingMatrixTests-043.png) | 大型差异的滚动视口、上下文和分页 |
| [内存 11 pt / 1460 / Unified](main-native-images/ReadingMatrixTests-078.png) | 变化行、原生差异块与滚动 |
| [交互式变基](main-native-images/RebaseWorkflowTests-097.png) | 固定范围、排序、动作和组合消息编辑 |
| [Settings 原生 HelpTag](main-native-images/SettingsLifecycleTests-100.png) | 实际像素中的 Git 2.46+，另有[独立核验](main-native-help-verified.json) |

functional 的 17 条运行时 warning、smoke 的 0 条 warning 保持原结果。980 pt 的大型差异页中，`+19,996` / `−19,996` 的头部统计会换行；操作控件与明确的滚动/分页仍可用，该视觉限制保留在回执中，不据功能计数签核正式视觉验收。旧 Vision 沙盒失败、旧 69/64/5/0 回归和此前超时继续保留各自记录。

#59/#70/#96/#98 已满足本轮开发与固定主线回归条件，按维护者授权以 completed 收口。#35/#57 的已集成开发成果保留，正式 M5 条件按 #3/#4/#5/#6/#7/#9 的既有延期以 not_planned 归档，原未通过条件继续保留。[PR #97 源码依据](superseded-lfs-source.json)证明其 head 是已合入 #87 原始 head 的祖先，七个 LFS 实现/检查文件与当前逐字节相同；冗余 PR 按已被取代关闭，不再次合并。

已完成分支在最终文档 PR 的三项必需检查与正常合并后，先生成包含最终文档 tip 的 Git bundle，在空镜像恢复并核验全部分支，再以原 SHA 建立 archive refs 并清理。承载用户改动的 `codex/v1.2-blame` / `codex/v1.2-rebase` 和实际检出保留；[保护状态](protected-state.json)核对其 HEAD、索引和 89/5 个文件摘要。实际关闭、归档及清理计数保存在本机 `.build/v1-2-closeout-2026-11-03/current-state.json` 与对应操作回执。

文档 head 仍需 PR policy、Repository policy、Native macOS；集成后核对应用、测试和可信入口的逐 SHA 等价，完整原生来源保持上述实际 main。可选 Workers Builds 的失败单独记录，未人工部署或发布正式 Release。
