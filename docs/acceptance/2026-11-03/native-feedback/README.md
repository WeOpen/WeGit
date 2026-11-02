# 原生反馈夹具的真实 Git 失败与恢复

PR #101 正常进入 main `297f15c` 后，[提交反馈专项 41540708075](https://github.com/WeOpen/WeGit/actions/runs/41540708075) 实际 smoke 1/1/0/0、专项 1/0/1/0。旧状态谓词与详情定位已通过，新的失败在私有 `pre-commit` shell hook 被托管应用沙盒拒绝执行，Git 返回 `Operation not permitted`；原断言期望 hook 自己输出的拒绝文案。

改用暂存完成后建立的私有 `index.lock` 触发真实 commit 失败。详情必须包含自己的完整锁路径，锁和完整 index/工作文件字节必须保留；移除锁后继续原有取消、草稿、明暗主题及最终唯一新提交的断言。应用/Core、测试超时、沙盒权限与全局 Git 配置均未改变。

独立真实 Git [检查回执](private-index-lock-check.json)确认失败退出128、自己的锁路径、HEAD/index/工作文件和锁字节保持，移除锁后只新增一个成功提交。原生目标只在本机编译；托管专项和最终69方法回归仍需实际执行。

失败的完整 ZIP 为113,738,086bytes、2137项CRC，SHA256 `e1b452c5560a99db7720ebaa073b74ced2df4c40dbd975049135338ff2711149`；194应用和33测试输入逐项核对，显示已恢复，系统权限未改。[失败回执](feedback-commit-41540708075-failed.json)和[实际23.723333秒画面](feedback-commit-41540708075-visible.png)保留。反馈详情可伸出父窗口，后续成功证据使用完整屏幕截图并保留AX内容。

本轮仍通过 #98 收口：五个固定入口各须 smoke 及唯一专项实际1/1/0/0，再正常合入并完成同源码69/69/0/0的完整functional。剩余Issue、冗余PR和已归档分支只在该门禁通过后清理。正式验收沿用[维护者确认的延期条件](../../2026-11-01/v1-2-closeout/README.md)。
