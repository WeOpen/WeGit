# Git 兼容性与测试隔离

> 验证日期：2026-10-11。运行环境：macOS 27.0.1（26A434）、Xcode 27、Swift 6.4、Apple Silicon Mac16,8。

## 1. 最低能力要求

WeGit 要求 **Git 2.46 或更新版本**。启动时除版本号外，还实际检查以下能力：

- `GIT_CONFIG_SYSTEM`、`GIT_CONFIG_GLOBAL` 和 `GIT_CONFIG_COUNT` 的读取与覆盖顺序。
- 空 `remote.<name>.url` / `pushurl` 值能清除继承的地址列表，使一次推送只使用选定目标。

探针仅在私有临时目录中创建配置，通过 `config --get-all` 和 `remote get-url` 读取；不连接远端，不改写用户配置。版本号符合但能力不符的可执行文件同样被拒绝。

此前的 Git 2.31 声明不准确，现已撤回。2.31.8 实测忽略全局/系统配置隔离变量，不支持 SSH 签名，也不具备当前远端实现所需的 URL 列表重置行为。Git 官方 v2.45.0 与 v2.46.0 的 `remote.c` 对比显示，该重置行为从 2.46 起具备；最低版本以完整实际回归补充验证。

## 2. 已执行矩阵

| 可执行文件来源 | 版本 | 范围与结果 |
| --- | --- | --- |
| 系统 `/usr/bin/git` | Apple Git 2.54.0 | 175 项核心测试、31 个套件全部通过，包含新增推送未知结果与恢复 |
| Git 官方源码，项目目录内独立编译 | 2.46.0 | 同一套 175 项核心测试、31 个套件全部通过 |
| Git 官方源码，项目目录内独立编译 | 2.31.8 | 不受支持；隔离修复后在任何仓库命令前拒绝，配置文件校验值保持一致 |
| Xcode 内 Git | 与当前 Xcode 配套 | 用于原生 UI 夹具，独立执行配置隔离探针；UI 结果见开发记录 |
| Homebrew Git / GPG | 当前未找到 | 尚未验证，不能用其他来源的结果代替 |

核心矩阵覆盖真实临时仓库、SSH 临时密钥签名、Hooks、配置编辑、差异写入、历史与分支、多个本地 Bare Remote、Lease、Pull/Rebase 冲突与取消。真实 GitHub/GitLab 的 HTTPS/SSH 写入和交互认证、GPG、干净机器与正式公证包仍需补齐。

最新系统 Git 日志：`/tmp/wegit-v1-line-ending-core-complete.log`；2.46 日志：`/tmp/wegit-v1-line-ending-core-git246.log`。此前 156 项的地址固定回归记录分别为 `/tmp/wegit-system-git-pinning-full.log`、`/tmp/wegit-git246-full.log`；不受支持版本的拒绝记录为 `/tmp/wegit-git231-isolation-rejection.log`。日志路径为本机验证产物，并非随仓库分发的测试数据。

## 3. 复现与隔离约束

```bash
# 默认使用系统 Git
swift test

# 仅测试进程使用指定的独立 Git；不修改 PATH 或用户配置
WEGIT_TEST_GIT="$PWD/.build/toolchains/git-2.46.0/install/bin/git" swift test
```

`WEGIT_TEST_GIT` 仅由测试辅助代码读取，生产应用不读取此变量。独立工具链放在被忽略的 `.build/toolchains/` 下；不替换系统 Git、不全局安装，也不改写 `HOME`。

核心测试的每个 Git 引擎默认使用 `/dev/null` 隔离全局和系统配置。所有夹具命令在首次执行前共享一个只读能力探针，失败结果也会缓存，避免并发测试绕过检查。全局配置编辑测试必须显式提供刚创建的私有文件；测试执行器将 `--global` 转成 `--file <私有文件>`，并检查目录身份及文件类型。缺少文件、文件被换成符号链接或请求系统配置时，直接拒绝执行。原生 UI 夹具使用统一执行器，同样先验证隔离，并禁止全局/系统作用域写入。

切换 Git 版本时，验证前后比较实际全局配置文件的校验值和相关键值；不要在隔离不确定的情况下继续整套测试。

2.46.0 工具链来源记录：

| 项目 | 值 |
| --- | --- |
| 官方仓库 | `https://github.com/git/git` |
| Tag 对象 | `75a062f03c1c151fb46427b44cc0c7d89a5fc73d` |
| 提交 | `39bf06adf96da25b87c9aa7d35a32ef3683eb4a4` |
| 源码压缩包 SHA-256 | `7cb9a19f08b44935fc0b6afc6fef1ae172a2e6113d704d5e867a2e095c122386` |
| 本地记录 | `.build/toolchains/git-2.46.0/source-provenance.json` |

该工具链用于最低版本的本地回归，未作为应用依赖或分发内容。用户应优先使用其安装渠道维护的更新版本。

## 4. 已确认缺陷与修复

| 问题 | 影响与修复 | 验证 |
| --- | --- | --- |
| 旧 Git 忽略配置隔离 | 旧测试误改全局提交者姓名和默认分支；已恢复既有姓名及用户确认的 `main`。增加只读探针、私有文件写入与路径检查 | 隔离回归通过；2.31.8 在夹具命令前拒绝；后续两个受支持版本完整测试前后全局配置一致 |
| 确认后 URL 重写变化 | 临时仓库测试复现 Push/Pull 可被重定向；执行时使用每次命令独立的别名，单次解析到确认时的有效地址 | 在实际 Push/Fetch 前注入重写配置，操作仍只使用确认的仓库 |
| 有效地址被二次重写 | Lease 查询拒绝原本合法的单次重写配置 | Lease 查询与写入使用相同的固定方式，双重匹配规则回归通过 |
| 地址列表清空与特殊路径 | 正确处理已有配置的空值重置；本地地址含换行时转为编码后的 `file://` 地址 | 多地址、清空后回退、绝对/相对换行路径回归通过 |
| 推送回执不完整 | 远端已更新后仍可能超时、取消或报告 remote failure。保留原计划并提供只读核对；重启后校验仓库实体与地址指纹，凭据/查询参数不进入保存记录 | 两套 Git 下实际更新后模拟丢失回执、目标变化及相对路径移动；核对不增加 Push 或 Commit 次数 |

以上错误目标测试只操作本次创建的临时仓库，没有向项目远端写入。它们是发布前必须通过的回归条件，不能通过跳过旧版本测试或放宽断言来标记完成。


2026-10-11 的完整回归日志为 `/tmp/wegit-v1-line-ending-core-complete.log` 和 `/tmp/wegit-v1-line-ending-core-git246.log`。新增原文选区、磁盘块跳转与复制、UTF-8 截断及首批语言高亮覆盖通过。Homebrew 5.1.6 更新后仍无法为本机 macOS 27 安装 Git/GPG，实际错误是 `unknown or unsupported macOS version: :dunno`；不修改系统版本来制造渠道兼容结果。

## 5. 获准 GitHub 仓库的只读传输（2026-10-11）

仓库 `WeOpen/WeGit` 的 HTTPS 和 SSH 只读引用查询均成功。使用实际编译的 `GitEngine` 再次验证两个协议；`CloneCoordinator` 完成 HTTPS 克隆，`RepositoryService.status()` 核对空工作区且 HEAD 尚不存在。测试当时远端没有提交，因此这不替代有提交后的 Fetch/Push、Lease、分支写入、SSH Clone 或交互认证验收。

HTTPS 使用私有 0600 配置文件复用已有 gh 凭据辅助；SSH 使用已有身份和 `StrictHostKeyChecking=yes`，没有新增主机信任或密钥。测试目录在完成后清理，用户 Git 配置校验值保持原基线。临时验收源码与结果为 `/tmp/wegit-github-read-acceptance.swift`、`/tmp/wegit-github-read-acceptance.log`，调用现有领域服务，不增加生产接口。
