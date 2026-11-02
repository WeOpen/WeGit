# PR #87 最终实现的 CI 与原始性能证据

[PR #87](https://github.com/WeOpen/WeGit/pull/87) 候选 `0c176e2c73477bd20a615fb381d91ef147f9fff5` 正常合入 main `9ee1ab243ed7d886de78cde91882121fd5fb1e2f`，两者最终树一致。其 [必需 CI 41363741213](https://github.com/WeOpen/WeGit/actions/runs/41363741213) 实际通过；三套 Git 各266项 Core测试、47组，普通 Release 的194个输入与候选一致，开发包摘要核验通过。详细 [回执](ci-41363741213-verified.json) 保留实际版本/包来源。

五份托管报告各包含普通、5000文件松散对象、5000文件打包对象三类负载，每类30个有效原始样本，共450个。数组、源码和原预算在各文件内：

- [Interactive Rebase](interactive-ci-performance.json)
- [LFS 读取/固定缓存获取](lfs-ci-performance.json)
- [独立 Rebase](rebase-ci-performance.json)
- [冲突编辑器](conflict-editor-ci-performance.json)
- [Worktree 读取](worktree-ci-performance.json)

本次收口的测试驱动/截图修改没有改变这些测量的 Core 输入。以上专项预算不等于整版 UI 性能验收；Core resident 不包含子Git。完整主线原生回归在 [失败与恢复记录](../native-functional-recovery/README.md) 单独跟踪，维护者明确延期的最终Release性能、VoiceOver、真实兼容组合、安装/迁移/回退与Beta反馈仍保留未验状态。
