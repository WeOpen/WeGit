# Homebrew Git 与隔离 OpenPGP

[CI 38994191287](https://github.com/WeOpen/WeGit/actions/runs/38994191287) 在 PR #20 head `a4ab7a95e1c333fb7b6eb6a25f2a37efaf6dbc9b` 的合并快照 `18083727c24e525157e749137d2fce5692bbbffa` 上实际通过。macOS 27.0.1 / Xcode 27 的独立 arm64 VM，无真实用户账号或远端传输。

| 环境 | 实际结果 |
| --- | --- |
| Xcode Apple Git 2.54.0（Apple Git-157）＋GnuPG 2.5.24 | 7 项签名行为通过；私有服务停止、夹具删除通过 |
| Homebrew Git 2.56.0（formula 2.56.0_1）＋GnuPG 2.5.24 | 同一 7 项签名行为通过；私有服务停止、夹具删除通过 |
| Homebrew Git 完整核心回归 | 实际 183 项 / 32 套件通过，58.488 秒 |
| 其余受保护 CI 步骤 | 原两套 Git、原生专项、UI 编译、Debug/普通 Release 与预览包通过；完整 UI 没有执行 |

七项行为是工具能力检测、私有全局配置继承、通过 RepositoryService 生成指定密钥的有效签名、无效密钥拒绝并保留 HEAD/暂存内容、仓库级禁用签名、移除仓库值恢复全局签名，以及私有全局配置字节保持不变。没有只检查命令退出码就宣称签名有效；`verify-commit --raw` 的 VALIDSIG 必须匹配本次生成的密钥。

每次运行使用原子创建的 `/tmp/WeGitGPG-*` 私有目录、独立 Git 全局文件与 GNUPGHOME，结束只停止该 home 的 GnuPG 服务并删除本次夹具。未改 HOME、用户配置或用户密钥，没有安装工具、连接服务或分发 GnuPG；密钥文件不在上传范围。清理失败会使检查失败。完整 JSON 见 apple/homebrew/source，实际 formula 见 homebrew-versions.txt，核心末行见 homebrew-core-excerpt.txt。

53 个核心输入的聚合 SHA-256 为 `421fc53e24a43ab5f05e38634ecce86114b7a477822694d24d2e5aaccb2500b9`，方法由 source.json 记录；后续文档回执加入时核对核心与检查器均未变化，见 source-equivalence.json。应用、领域服务和公开接口没有改动。

本轮只覆盖无口令临时密钥的非交互 OpenPGP，不覆盖真实 Pinentry、硬件密钥、GitLab/其他账号、原生界面、受保护目标机器安装或完整发布。此前本机 Homebrew 5.1.6 不支持 macOS 27 的失败记录保留，不能以托管环境的成功替换其条件。

最终提交 `f0164bbd8e25ca7696f4b446590fb9a541c9e5dc` 的 [CI 38995575313](https://github.com/WeOpen/WeGit/actions/runs/38995575313) 再次全绿，合并快照 `61d02d7db5760bec68620438d086fcd9757af618`；两份签名报告各 7 项与清理全部通过，核心输入和检查器摘要相同。实际产物已下载核对，见 final-*。PR #20 已按受保护流程 Squash 合入 main `caca33279f1aa7be5a6e3760bc51b6c55d4c5304`；完整兼容性 Issue #5 仍开放。

最终 PR head `f0164bbd8e25ca7696f4b446590fb9a541c9e5dc` 的 [CI 38995575313](https://github.com/WeOpen/WeGit/actions/runs/38995575313) 也已全部通过，实际合并快照为 `61d02d7db5760bec68620438d086fcd9757af618`。两组各 7 项签名及清理已从最终 artifact 核对，核心摘要不变，见 final-*。PR #20 已按分支保护 Squash 合入 main `caca33279f1aa7be5a6e3760bc51b6c55d4c5304`，见 merge.json；完整兼容性 Issue #5 保持开启。
