# v1.2 · 固定提交逐行归属

需求 [#65](https://github.com/WeOpen/WeGit/issues/65)，实现于 `codex/v1.2-blame`。这里只记录本批证据，完整 v1.2 回归、Release 性能与发布验收继续独立跟进。

## 实现边界

- 从更改文件、提交详情或文件历史进入，固定完整提交 OID 和当时的字面路径。删除记录读取所比较的父提交，暂存重命名读取 HEAD 中的旧路径；新增/未跟踪内容不冒充已提交行。
- 先读取并限制固定 blob，再运行原生 `blame --line-porcelain --root --no-textconv`，核对每条目标行与原始 UTF-8 字节。保留 CRLF、无末尾换行、特殊路径和原始提交作者；不受当前 mailmap、忽略提交列表或替换对象影响。Git 默认重命名检测、未启用复制搜索及 Merge 归属边界由标题帮助说明。
- 文件最多 8 MiB、100,000 行、单行 8,192 字节，每页 200 行；元数据最多 16 MiB，Blame 查询最多 60 秒。二进制、无效 UTF-8、符号链接、缺失对象与超限内容有明确限制，不自动获取对象或启动 textconv。
- 后台任务可取消、重试；固定会话身份与请求代次，关闭或切仓库后旧结果不能覆盖新上下文。页面复用原生代码选择，跨行复制保留原始换行，翻页重置选择与滚动；来源 SHA 与历史图标分别打开对应提交和原路径的固定历史。
- 所有读取不写 HEAD、索引或工作文件，没有新增轮询、监视器或网络请求。

## 本机结果

| 范围 | 实际结果 |
| --- | --- |
| 独立真实 Git 行为 | [29 项通过](independent-checks.json)，包含多作者、根提交、重命名、删除后历史、CRLF/EOF、特殊路径、空/二进制/无效文本、文件/行上限、取消和 partial clone 缺失对象不获取 |
| 首次查询与分页 | 5,000 行夹具，各 30 次：重新读取 blob + 首屏 p95 **58.23 ms**；下一页 p95 **26.27 ms**；2,000 ms 后台预算通过；原始样本保留在同一 JSON |
| 取消 | 受控延迟查询取消约 **0.16 ms**，不返回迟到页；这不是实际大历史最坏取消时延 |
| 编译 | `swift build --build-tests` 与 `xcodebuild ... build-for-testing` 通过；核心 6 个新测试声明与 1 个固定原生用例仅编译，本机未执行 XCTest |
| 工具 | 本次 Swift 格式与本地化检查通过：1,205 字符串 / 8 复数；Python 与策略结果另按最终执行记录更新 |
| 原生 CUA | 中文浅色、英文深色；作者/SHA、提交详情、重命名前历史、跨行选择高亮、首末页及 Escape 返回与草稿保留均实际检查 |

该性能是本机 Debug 后台 5,000 行/少量提交夹具，既不是复杂历史压力测试，也不代表 Release UI、内存、滚动或完整应用性能通过。取消的真实进程/压力上限继续保留最终验收。

## 可复核证据

- [中文跨行选择](screenshots/selection-zh-light.png)、[英文深色](screenshots/blame-en-dark.png)、[原始路径历史](screenshots/original-path-history.png)。CUA 只核对选择高亮；原始跨行剪贴板字节核对在新增托管用例中执行，不将截图当作复制正确性证据。
- [Git 与清理回执](ui-receipt.json)确认读取前后 HEAD、原始 index、未提交字节相同；专用预览退出、私有夹具删除，专用 UITests 偏好逐值还原。
- [预览构建来源](preview-build-source.json)在预览建立时与 165 项输入完全一致。之后 XcodeGen 只增加 `BlameWorkflowTests.swift` 的工程登记；应用源文件没有变化，工程文件哈希的差异不伪装成完整清单一致。
- 新原生诊断入口由 [PR #68](https://github.com/WeOpen/WeGit/pull/68) 单独注册到可信 main。只有 smoke 实际 1/1 通过后才能运行固定的 `BlameWorkflowTests/testCommittedAttributionPagingAndHistoricalNavigation`，实际用例与产品代码留在功能分支。

## 待验与已修正细节

- [首次托管原生 40518140084](https://github.com/WeOpen/WeGit/actions/runs/40518140084) 使用候选 `59dd9f0`；[smoke 1/1 通过](native-first-smoke.json)，[Blame 专项 0/1、1 失败、0 跳过](native-first-failure.json)。测试在首个代码值断言处停止，后续导航和剪贴板步骤没有执行。AX 的展示文本把 CR 显示为空格，测试误把展示值当原始字节；现改成核对准确展示值，跨行剪贴板仍逐字节要求 `first\r\nchanged\r`。原始日志与 xcresult 由该运行的 artifact 保留。其 165 项应用输入与 `bb50bbd` 逐一匹配。
- [托管 CI 40479885155](https://github.com/WeOpen/WeGit/actions/runs/40479885155) 对候选 `71b1b29` 的 Apple、最低 Git 2.46 与 Homebrew 三套核心各执行 **224 项 / 40 suites 全部通过**。该结果是更新 main 前的源码；当前源码的必需检查仍需重新完成。
- 托管核心执行、smoke 和 Blame 专项在固定功能 PR SHA 上运行，保留实际计数、源码清单、日志与 xcresult；当前不以本机构建替代。
- 初始逐行原生文本没有连接共享选择，无法跨行；接入现有 `DiffTextSelection`，每页以原始行与换行建立选择源。原生文本自带右键菜单会接管代码区，文件历史另提供可键盘访问的图标入口，不依赖父行菜单。
- 翻页后旧滚动位置不应让新页从中段开始；以首行重新建立滚动容器。一次 CUA 读取遇到切页瞬间 AXError，随后真实末页 201–206/206 与禁用的下一页均已核对，没有把点击返回本身当作通过。
