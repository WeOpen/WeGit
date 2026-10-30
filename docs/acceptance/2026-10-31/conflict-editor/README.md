# V12-05 内置三方冲突编辑器 · Issue81

## 当前实现

独立分支 `codex/v1.2-conflict-editor` 基于 Rebase 候选 `8474d620c7607678921fcfb91d13dae68572b26c`。Changes 冲突文件现在提供“编辑冲突…”入口；编辑器读取并显示 BASE、OURS、THEIRS 和可编辑 RESULT，支持块导航、接受 BASE/OURS/THEIRS/两侧、保存结果和标记已解决分离。保存只原子替换工作文件并保留 index；标记解决重新核对同一快照后只安装目标路径的 stage-0 条目。

来源解析按活动 Merge、Rebase、Cherry-pick、Revert 元数据和真实对象父链进行。Rebase/Cherry-pick 的 BASE 是被重放提交的唯一父提交；不能验证来源、共同起点、UTF-8、regular-file mode、attributes 或索引格式时拒绝内置写入并保留外部工具路径。所有保存和解决动作重验仓库 persistence identity、HEAD、sequencer/operation markers、完整 index、目标 stage entries、attributes、工作文件 inode/bytes/mode 和父目录身份。

## 独立验证

| 验证 | 结果 |
| --- | --- |
| 真实 Git checker | `27/27` 通过：parser CRLF/no-final-newline/malformed、Merge/Cherry-pick/Revert/Rebase 来源、保存与 index 分离、标记解决、外部工作文件/index/HEAD/operation/mode/父目录变化拒绝、merge driver/filter/无效 UTF-8/符号链接/外部 index.lock 拒绝 |
| Core tests | `swift build --build-tests` 通过；新增 `ConflictEditorTests` 覆盖 parser、Merge 保存/index 保持、标记解决和外部工作文件变化拒绝；本机未执行 XCTest |
| 原生 UI 编译 | `xcodebuild ... build-for-testing` 通过；新增的固定 `WorkflowRecoveryTests/testConflictEditorPreservesIndexUntilResolveAndGuardsUnsavedClose` 编译进入现有 UI test target；本机未运行 XCTest |
| 可信入口 | 独立 Issue83 注册固定 focus `conflict-editor`，指向上述方法；`scripts/ci/tests/test_ui_probe.py` 17/17 通过。Issue83 必须先正常进入 trusted main，Issue81 才能使用该入口 |
| Release checker | Release WeGitCore + 私有 disposable Git fixtures：27/27 通过，wall `6.82 s`，峰值 RSS `14,417,920` bytes；资源 bundle 在隔离运行目录内。该检查器是 Core 行为/开销证据，不是托管 XCTest 或版本性能验收 |

## 未完成门禁

Issue81 尚未提交、push 或创建功能 PR；Issue83 的可信入口 PR #84 已创建，仍需正常 CI/review/集成。需要补托管 Core/Native required 计数、完整 artifact/xcresult、截图/AX、Release 冲突编辑器性能、取消/保存失败/取消重开草稿和更广复杂边界后，才能将 Issue81 标为完成。V12-07、V12-08、V12-09、最终固定源码回归及 M5 仍开放。
