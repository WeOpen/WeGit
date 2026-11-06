# v2.0 实施与验收进度

范围唯一入口为 [V2_0_PLAN.md](V2_0_PLAN.md)，[M0 契约/预算](V2_0_CONTRACTS.md)为实施输入。表中“实现完成”不表示实际验收或版本发布。

## 当前批次

M1 固定bcf8666的最新实际[CI42043325839](https://github.com/WeOpen/WeGit/actions/runs/42043325839)仍失败：三套Git各294/48、签名及功能通过，大型Reset2385.34ms、恢复预览2130.95ms、恢复2104.56ms超过原2000ms，应用/UI编译及包未执行。新的稳定修补保留两组有界Git工作文件核对、独立普通叶子的四批安装，以及恢复预览独立读取重叠和末尾统一身份/原索引/文件/Git状态核对。SHA和每批分目录实验没有稳定端到端提升，已撤回，原失败与原预算均保留。

Release模块、五项新增Core测试源及严格格式通过，本机未执行XCTest。12条私有非XCTest控制通过，包含SHA-1/SHA-256×完整/拆分索引GC后恢复、分组后编辑拒绝、预览期间并发暂存拒绝、字节/权限/原索引、新父目录及替换临时存储保护。普通/大型各2个串行开发样本满足原门槛，大型最大预览507.82ms、Reset959.95ms、恢复预览463.73ms、恢复712.93ms，取消0.75ms、RSS26,574,848bytes；缓存未控制，不替代托管30样本、UI或版本验收。原始记录与96项模块/资源输入及测试/静态链接对象SHA在.build/v2-m1/final-profile，候选统一送验后保持稳定并继续M4/M5。

后续仓库工具已固定6096236/[草稿PR134](https://github.com/WeOpen/WeGit/pull/134)，提交/任务已固定cee02a4/[草稿PR135](https://github.com/WeOpen/WeGit/pull/135)，分别以M1/M2为父批次；M3邮件补丁的私有原生开发复验已完成，完整托管及版本结果仍待。主题/网站[PR133](https://github.com/WeOpen/WeGit/pull/133)及主检出用户PBX差异继续独立保留。

M1 最新实际 [CI 41909998480](https://github.com/WeOpen/WeGit/actions/runs/41909998480) 固定0915404：三套Git各292/48、签名与功能通过；大型预览、Reset及恢复预览超过原2000ms，应用/UI编译及包未执行。新的阶段并发修补已经完成：已知目标文件与status重叠捕获，额外路径共用剩余预算且名称独立；索引树验证与备份读取重叠，末尾Git比较绑定原始索引版本。两项独立控制实际通过，新增2项Core测试源只编译；普通/大型各2样本开发诊断符合原门槛，大型最大恢复预览1450.98ms。本机未执行XCTest，完整托管批次仍待验，历史失败保留。
M3 在 `codex/v2-m3-commit-and-task` 开发：有序多提交队列/主线父提交、保存任务切换/Stash分支、8个固定配置键/工作区覆盖、提交/Tag签名查询、消息历史/模板和邮件补丁导入/导出均已接入。Core与原生/UI测试源已编译，本机未执行XCTest；`commit-tasks`已统一注册6项托管原生流程方法，60项相关工具检查、56个Swift源严格格式及1745字符串/8复数检查通过。邮件新增11项Core测试源只编译；实际私有控制和原生恢复记录见下文。M3开发批次准备固定提交；英文深色邮件预览的图标、正文左对齐、进度AX、中止/未执行状态及原生File菜单入口已实际复验，完整托管验收依M1前置统一安排；M4～M5仍需继续。

私有原生邮件开发验证已经核对：预览取消不写、顺序调整/恢复、正文展开、三方冲突编辑保存不改索引/HEAD、明确标记解决后继续、作者/日期/完整消息/文件字节一致；选定两项导出2549bytes逐字节等于Git原始输出。中止确认取消保持全部原状态，确认后回原起点且工作树干净，操作前阶段索引及冲突工作字节备份准确。非XCTest邮件控制还覆盖来源提交对象缺失、丢失回执后跳过、GC后恢复三阶段索引、替换邮件拒绝、根提交到Unborn及关闭时清理已核对原始缓存/保留变化后输入；原JSON与失败在`.build/v2-m3`保留，不冒充托管或版本通过。

M1 [CI42043325839](https://github.com/WeOpen/WeGit/actions/runs/42043325839) 固定bcf8666：三套Git各294/48、签名和功能通过；普通/大型各30原数组独立重算，大型预览1606.41ms符合预算，Reset2385.34ms、恢复预览2130.95ms、恢复2104.56ms仍超原2000ms。应用/UI编译及包未执行，失败保持开放；原ZIP、CRC、SHA和重算报告保留于主检出.build/v2-m1/failed-native-8。

M2 仓库工具在 `codex/v2-m2-repository-tools` 形成开发批次：新建/高级克隆/补深、两点/共同祖先比较、行级丢弃/历史恢复、两个作用域的忽略规则、图片/编码阅读与普通补丁已经接入原生入口。Core、测试源与应用/UI测试源已编译；本机未执行 XCTest，已形成草稿 PR134，完整托管验收等待 M1 前置。主题/网站草稿 [PR #133](https://github.com/WeOpen/WeGit/pull/133) 在主检出独立保留，M3～M5 仍需继续。

私有原生开发预览已逐字节核对：取消不写；选中行丢弃保留未选行和原索引，备份恢复 CRLF/无末尾换行；历史工作文件恢复；已有文件新建、指定分支/深度1克隆、显式补深/完整历史；分叉两点与共同祖先比较；本地 exclude 与仓库 gitignore 保存/准确撤销、无遗留 lock；PNG/JPEG/WebP/缺侧/LFS指针、Shift-JIS原始导出；图片滑杆/缩放/越界平移裁切；234字节原始补丁导出、取消、工作文件应用和备份恢复。原 JSON 保留于 `.build/v2-m2`，这些不是托管批次或版本验收。`repository-tools` 已统一注册6项原生流程方法（新建/浅历史、分叉比较、文件处理/忽略、普通补丁与两项特殊内容），b812293 阶段的应用及测试源已集中编译，215 项应用输入与当时实际编译回执一致；35 项 UI 测试输入另存摘要。M1 前置修补后的共享源码继续按批次核对编译。54 个变更 Swift 文件严格格式、1610 字符串/8复数和14项证据工具检查通过，实际执行仍依托可信main托管批次。

M1 候选固定 `bcf8666939e4d337629bb90be5e869021494bb0b`，已对 PR132 请求一次统一托管批次；M2 在此源码前置上继续。M1 最新实际 [CI 41909998480](https://github.com/WeOpen/WeGit/actions/runs/41909998480) 固定0915404：三套Git各292/48、签名与功能通过；大型预览、Reset及恢复预览超过原2000ms，应用/UI编译及包未执行。新的阶段并发修补已经完成：已知目标文件与status重叠捕获，额外路径共用剩余预算且名称独立；索引树验证与备份读取重叠，末尾Git比较绑定原始索引版本。两项独立控制实际通过，新增2项Core测试源只编译；普通/大型各2样本开发诊断符合原门槛，大型最大恢复预览1450.98ms。本机未执行XCTest，完整托管批次仍待验，历史失败保留。

M0 已经由 [PR #131](https://github.com/WeOpen/WeGit/pull/131) 正常合入 main `fc9afa7`；[CI 41797958554](https://github.com/WeOpen/WeGit/actions/runs/41797958554) 的策略/工具实际通过，Native/前端/Core编译/site为skipped、0步骤、无runner。112项本机工具检查、固定actionlint与18份文档/304本地链接通过。草稿/中间head频率与真实复用继续由业务批次核对。历史 M1 失败、runner取消和修补详情保留在 [HANDOFF.MD](../HANDOFF.MD)，实际通过、失败和未执行分别记录。

## 全部62子任务

M1 固定229facf的[CI41829276861](https://github.com/WeOpen/WeGit/actions/runs/41829276861)三套Git各282/48、签名/功能通过，大型恢复30样本超预算，应用/UI编译和包未执行。后续修补用全索引文件版本检查、有限并行快照和原索引对象/拆分依赖保护；四种哈希/索引私有诊断通过，新增测试源只编译，开发2样本不代替托管30样本验收。


| 子任务 | 模块/Issue | 实施内容 | 实现状态 | 批次证据 |
| --- | --- | --- | --- | --- |
| 01a | [V20-01](https://github.com/WeOpen/WeGit/issues/116) | 建立按用途选择的控件规范 | 实现完成/待批次验收 | — |
| 01b | [V20-01](https://github.com/WeOpen/WeGit/issues/116) | 收敛 `workbenchControlFamily`、主要操作、图标、菜单和 Tabs；移除内容层的全局玻璃继承及内容面板的重复玻璃 | 实现完成/待批次验收 | — |
| 01c | [V20-01](https://github.com/WeOpen/WeGit/issues/116) | 检查系统工具栏与自定义表面，避免玻璃叠玻璃；浮动控制条按真实层级判断，不按顶部/底部位置一刀切 | 实现完成/待批次验收 | — |
| 01d | [V20-01](https://github.com/WeOpen/WeGit/issues/116) | 逐页替换和渲染检查 | 实施中/待批次验收 | — |
| 01e | [V20-01](https://github.com/WeOpen/WeGit/issues/116) | 滑块、开关等瞬时交互效果遵循系统行为；减少透明度/动态效果、增强对比度和自定义主题的退化路径保持明确 | 实现完成/待批次验收 | — |
| 02a | [V20-02](https://github.com/WeOpen/WeGit/issues/117) | 从 Welcome/仓库菜单建立普通仓库，选择目录与初始分支；已有普通文件可保留并作为未跟踪内容显示，拒绝覆写已有仓库或隐式建立嵌套仓库 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 02b | [V20-02](https://github.com/WeOpen/WeGit/issues/117) | 克隆支持明确选择分支、仅指定分支、深度与递归 Submodule；默认行为保留现有完整克隆，浅仓库支持显式补深/获取完整历史 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 02c | [V20-02](https://github.com/WeOpen/WeGit/issues/117) | 目录移动、权限/书签失效、Unborn/Detached HEAD、clone 部分完成、网络取消与磁盘不足均可核对 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 03a | [V20-03](https://github.com/WeOpen/WeGit/issues/118) | 从历史/分支进入 Soft/Mixed/Hard Reset，预览当前分支、固定目标、索引/文件影响和发布历史状态 | 实现完成/待批次验收 | — |
| 03b | [V20-03](https://github.com/WeOpen/WeGit/issues/118) | 浏览有界的 HEAD/分支 Reflog，识别条目时间、动作及对象是否仍存在；支持从旧提交创建恢复分支、找回误删分支和撤回最近本地提交 | 实现完成/待批次验收 | — |
| 03c | [V20-03](https://github.com/WeOpen/WeGit/issues/118) | 定义工作文件备份、恢复定位记录与保留/清理规则 | 实现完成/待批次验收 | — |
| 03d | [V20-03](https://github.com/WeOpen/WeGit/issues/118) | 覆盖外部引用移动、特殊索引标记、Unborn/Detached、多 Worktree 占用、取消及未知回执；不把共享分支 Reset 写到错误工作区 | 实现完成/待批次验收 | — |
| 04a | [V20-04](https://github.com/WeOpen/WeGit/issues/119) | 选择两个提交/本地分支/远端跟踪分支/Tag 进行两点比较，先解析并固定实际对象；保留现有父提交比较作为默认快捷入口 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 04b | [V20-04](https://github.com/WeOpen/WeGit/issues/119) | 提供“共同祖先到目标分支”的范围比较，显示方向、共同祖先、待合入提交和文件；明确两点与共同祖先比较的不同语义 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 04c | [V20-04](https://github.com/WeOpen/WeGit/issues/119) | 支持文件筛选、重命名、根提交、Merge 多父和有界分页，复用 Unified/Split、磁盘差异与原文复制；缺对象/浅历史边界提示显式获取，不自动下载 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 05a | [V20-05](https://github.com/WeOpen/WeGit/issues/120) | 按原始差异选择行丢弃，支持预览、取消和备份恢复；默认仅修改工作文件，保留未选变化及索引 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 05b | [V20-05](https://github.com/WeOpen/WeGit/issues/120) | 从历史/比较恢复明确时点的单文件，区分恢复到工作文件、恢复到索引及两者；默认仅恢复工作文件 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 05c | [V20-05](https://github.com/WeOpen/WeGit/issues/120) | 未跟踪文件可添加精确文件/目录/扩展名忽略规则，选择仓库 `.gitignore` 或本地 `.git/info/exclude`；预览匹配范围、转义和规则位置，保留注释/行尾/原有规则 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 06a | [V20-06](https://github.com/WeOpen/WeGit/issues/121) | 历史中选择有序的多个提交，预演 Cherry-pick/Revert 队列的顺序、当前分支及实际文件落点；执行前固定全部提交和起点，不默认自动 Stash | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 06b | [V20-06](https://github.com/WeOpen/WeGit/issues/121) | Merge 提交提供可理解的 mainline 父提交选择与对应差异；不把用户分支恒定解释为 OURS，也不根据显示顺序猜父提交 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 06c | [V20-06](https://github.com/WeOpen/WeGit/issues/121) | 记录已完成、当前与剩余提交；重复冲突、空变更、edit/消息停点、Hooks/签名失败和重开形成继续/跳过/中止闭环 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 07a | [V20-07](https://github.com/WeOpen/WeGit/issues/122) | 导出任意比较、选定文件及已暂存/未暂存的原始补丁；支持 Git 文本/二进制补丁，二进制仅文件级 | 实现完成/待批次验收 | M2文件补丁/M3邮件开发证据；托管待验 |
| 07b | [V20-07](https://github.com/WeOpen/WeGit/issues/122) | 导入标准补丁，显示路径、状态、目标层与预检查结果；默认应用到工作文件，应用到索引为明确独立选择 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 07c | [V20-07](https://github.com/WeOpen/WeGit/issues/122) | 导入单个/有序邮件提交补丁，使用受控 Git am 序列，预览作者/提交信息及文件；提供冲突继续/跳过/中止和重开识别，区分 Git am 与其他 rebase-apply 状态 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 08a | [V20-08](https://github.com/WeOpen/WeGit/issues/123) | 从选定 Stash 创建分支，固定对象/起点/分支名；Apply 成功后才按明确选择删除记录，冲突及删除回执不确定时保留可核对状态 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 08b | [V20-08](https://github.com/WeOpen/WeGit/issues/123) | 显式“保存当前任务并切换”，预览跟踪/未跟踪范围与目标，保留索引状态和草稿；保存成功、切换失败分别报告，不自动重复保存或丢弃 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 08c | [V20-08](https://github.com/WeOpen/WeGit/issues/123) | 按仓库保存可清空的提交消息历史，去重并保护当前草稿；支持消息模板，读取配置来源和有界原文 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 09a | [V20-09](https://github.com/WeOpen/WeGit/issues/124) | PNG/JPEG/WebP 两侧图片对照、尺寸/大小、缩放/平移及滑杆比较；透明图片有可读的背景，内容图像和颜色保持原样 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 09b | [V20-09](https://github.com/WeOpen/WeGit/issues/124) | 普通图片、二进制、大文件和 LFS 指针分别展示；固定两侧对象，先检查压缩字节和解码像素预算，大图先缩略预览，原尺寸明确加载且可取消 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 09c | [V20-09](https://github.com/WeOpen/WeGit/issues/124) | 特殊编码文本可明确选择阅读编码，解码失败/截断/无法可靠构造部分补丁时保留原始导出及文件级操作；不把替换字符后的显示文本写回仓库 | 实现完成/待批次验收 | M2私有开发验证；托管待验 |
| 10a | [V20-10](https://github.com/WeOpen/WeGit/issues/125) | 扩展仓库级 GPG/SSH 签名设置、现有密钥标识与工具检测，显示有效值/来源/继承/工作区覆盖；不存储或生成用户私钥 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 10b | [V20-10](https://github.com/WeOpen/WeGit/issues/125) | 提交和 Tag 签名结果可查，区分验证通过、无签名、无公钥/无法验证、无效与信任不足；不把密码学有效等同于已信任身份，不自动联网获取密钥 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 10c | [V20-10](https://github.com/WeOpen/WeGit/issues/125) | 保留现有身份/整合策略设置；新增编辑键限定为 `commit.gpgsign`、`tag.gpgsign`、`gpg.format`、`user.signingkey`、`gpg.program`、`gpg.ssh.allowedSignersFile`、`commit.template` 和 `core.excludesfile`，工具/文件路径按实际能力校验 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 10d | [V20-10](https://github.com/WeOpen/WeGit/issues/125) | 签名/Helper/Pinentry/Hooks 的失败、取消和缺工具保留草稿与恢复入口；不静默降级、跳过 Hooks 或清理系统密钥服务 | 实现完成/待批次验收 | M3开发编译/控制；托管待验 |
| 11a | [V20-11](https://github.com/WeOpen/WeGit/issues/126) | 支持新建主窗口及将仓库/Worktree 在窗口中打开，持久化每窗口路由、选中对象和阅读状态；同一工作区草稿共享且有编辑归属，避免后打开窗口覆盖已有输入 | 待实施 | — |
| 11b | [V20-11](https://github.com/WeOpen/WeGit/issues/126) | 相同工作区复用会话/写许可，common directory 共享操作继续协调；聚合订阅，关闭一个窗口不取消另一个窗口仍需使用的写入或监视 | 待实施 | — |
| 11c | [V20-11](https://github.com/WeOpen/WeGit/issues/126) | 快捷键可修改/恢复，检测冲突并同步菜单显示；保留系统编辑快捷键、输入焦点、responder 验证、禁用原因及菜单栏快捷面板行为 | 待实施 | — |
| 11d | [V20-11](https://github.com/WeOpen/WeGit/issues/126) | 统一查询入口覆盖提交、已跟踪路径、分支、Tag、Stash、Worktree 和命令，按作用域导航到现有对象页面；有界分页/取消，默认不全文扫描全部仓库 | 待实施 | — |
| 12a | [V20-12](https://github.com/WeOpen/WeGit/issues/127) | Submodule 添加、移除与来源变更，预览父仓库 gitlink/配置、子仓库路径/对象及需下载内容；保留已配置模块的打开/初始化/更新能力 | 待实施 | — |
| 12b | [V20-12](https://github.com/WeOpen/WeGit/issues/127) | 移除前检查脏内容、ignored 文件、子仓库独立提交、锁定/嵌套状态并提供保留方案；不默认递归覆盖或清理子仓库 | 待实施 | — |
| 12c | [V20-12](https://github.com/WeOpen/WeGit/issues/127) | LFS track/untrack 规则编辑，预览 `.gitattributes` 的匹配路径、顺序和有效来源，保留其他属性/注释/行尾；固定对象获取复用 v1.2，不因打开 Diff 自动下载 | 待实施 | — |
| 13a | [V20-13](https://github.com/WeOpen/WeGit/issues/128) | 在 M0 固定发布源、独立签名/内置验证公钥、版本通道、密钥轮换和安装者协议；SHA-256 核对字节，独立签名验证来源 | 待实施 | — |
| 13b | [V20-13](https://github.com/WeOpen/WeGit/issues/128) | 检查更新、展示版本说明、下载/进度/取消、同版本防重复、完整校验后退出安装；稳定通道排除 draft/RC，候选通道需明确选择 | 待实施 | — |
| 13c | [V20-13](https://github.com/WeOpen/WeGit/issues/128) | 安装前核对现有包、目标目录、运行窗口/任务及持久化状态，准备旧包与数据备份；失败/中断/磁盘不足时能恢复旧包，并核对重开后的真实版本 | 待实施 | — |
| 13d | [V20-13](https://github.com/WeOpen/WeGit/issues/128) | 测试 v1.2→v2.0 的设置、最近/收藏、主题、各 Worktree 草稿与页面迁移；v2.0→旧版回退通过明确备份恢复，不让旧版直接读取不兼容的新格式 | 待实施 | — |
| 13e | [V20-13](https://github.com/WeOpen/WeGit/issues/128) | v1.2 没有本版更新器，首次 v2.0 安装使用官网下载/DMG路径；应用内升级从 v2.0 开始提供 | 待实施 | — |
| 13f | [V20-13](https://github.com/WeOpen/WeGit/issues/128) | 同版本/源码/build 提供 Universal、Apple Silicon 与 Intel 三种 DMG；所有内嵌 Mach-O 的架构与 minos 按对应包核对，分别输出摘要、来源与安装大小 | 待实施 | — |
| 14a | [V20-14](https://github.com/WeOpen/WeGit/issues/129) | 客户端保存多个自定义主题，支持新增、复制、重命名、编辑、删除、导入/导出和切换 | 待实施 | — |
| 14b | [V20-14](https://github.com/WeOpen/WeGit/issues/129) | 旧 `customTheme` 迁移为主题库的一项，保留原17角色颜色、控件外观与当前选择 | 待实施 | — |
| 14c | [V20-14](https://github.com/WeOpen/WeGit/issues/129) | 注册受控 `wegit://theme/import` 入口，从用户点击网页动作直接唤起客户端 | 待实施 | — |
| 14d | [V20-14](https://github.com/WeOpen/WeGit/issues/129) | 网页预览、下载JSON和发送客户端使用同一份当前编辑后的配色快照，包括强调色/对比度，不能只传目录ID再读取原配色 | 待实施 | — |
| 14e | [V20-14](https://github.com/WeOpen/WeGit/issues/129) | 网页常规主题直接导入；未安装、旧版不支持协议或浏览器阻止唤起时提供下载客户端/JSON的可用退路，不虚报“导入成功” | 待实施 | — |
| 15a | [V20-15](https://github.com/WeOpen/WeGit/issues/130) | 扩展现有 Release 读取/选择逻辑，使用结构化的版本/通道/minimumOS/架构/URL/摘要/大小/manifest 数据 | 待实施 | — |
| 15b | [V20-15](https://github.com/WeOpen/WeGit/issues/130) | Release 发布/编辑/撤销触发有界的轻量清单更新；即使没有 site 提交，官网也能取得新版本 | 待实施 | — |
| 15c | [V20-15](https://github.com/WeOpen/WeGit/issues/130) | 网页自动推荐对应包，优先使用可获得且可信的架构/位数信息：Client Hints 的 arm+64归一为arm64，x86+64归一为x86_64，再选择Apple Silicon/Intel | 待实施 | — |
| 15d | [V20-15](https://github.com/WeOpen/WeGit/issues/130) | 三种包始终可手动选择；用户选择优先于后到的自动识别 | 待实施 | — |
| 15e | [V20-15](https://github.com/WeOpen/WeGit/issues/130) | 覆盖新Release但无site提交、旧稳定仅ARM/ZIP、公开Universal候选、三包齐全稳定版、部分资产上传/撤销、缓存陈旧、失败兜底及手动覆盖；不将不适用架构或候选误标成稳定 | 待实施 | — |
| 16a | [V20-16](https://github.com/WeOpen/WeGit/issues/115) | 按完整用户流程/功能批次组织分支和PR，一个PR可关联多个子任务/Issue | 实现完成/待批次验收 | — |
| 16b | [V20-16](https://github.com/WeOpen/WeGit/issues/115) | M0先调整工作流触发/排队规则：草稿及开发中间提交不自动启动后端重流程，批次稳定后进入待审状态或发出明确验收请求 | 实现完成/待批次验收 | — |
| 16c | [V20-16](https://github.com/WeOpen/WeGit/issues/115) | 开发遇到错误时按需做局部定位；视图/网站/工具及Core测试编译按批次实际范围集中执行 | 实现完成/待批次验收 | — |
| 16d | [V20-16](https://github.com/WeOpen/WeGit/issues/115) | 缓存构建与依赖；按应用/后端/测试/夹具/验证入口的不可变输入复用已通过回执，前端/文档不重复Core/GPG/后端性能 | 实现完成/待批次验收 | — |
| 16e | [V20-16](https://github.com/WeOpen/WeGit/issues/115) | 批次送验后保持候选head稳定，在独立后续批次继续无依赖开发；取消失效重复队列，避免等待每个子任务 | 实现完成/待批次验收 | — |

M1 第二轮 CI41814318775：三套 Git 各277/48、OpenPGP各9实际通过；功能前置Debug对象缺失导致失败，后续尚未执行。behavior补回同源Debug构建并增加调度测试，共享入口变化扩大对应回归。
