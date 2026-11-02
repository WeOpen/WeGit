# 原生反馈布局与真实 Git 失败夹具

[Stash专项41543656156](https://github.com/WeOpen/WeGit/actions/runs/41543656156)在7787f9b实际smoke1/1/0/0、专项1/0/1/0。恢复字节和删除前列表已核对，失败在详情打开；[实际画面](feedback-stash-41543656156-visible.png)显示反馈被侧栏遮住，只露出消息尾部。AX按钮从x312开始，实际Stash列从x490开始。这是可见布局缺陷，不能只换点击方式。[完整失败回执](feedback-stash-41543656156-failed.json)保留114,854,087bytes ZIP、SHA256 `3ac01c60f87f1e8d10a755c7bada0a9e99baeac455890d5b743f518bc4c06b02`、2055CRC、23.072秒及源/显示核验。

主视图为原生分栏忽略横向安全区，同时已经为纯SwiftUI状态Banner和Changes提交区计算leadingInset。将同一个inset补给Stash反馈栏及Tag待核对/反馈栏，控件留在工作区内，原生分栏继续使用已有边界。布局复用已有几何计算；原业务读取、写入和反馈结果保持。

两个原生用例增加980/1360窗口、侧栏开关的bounds、可点击和截图检查，再确认实际详情及原业务结果。当前视图变更仍须新的固定候选CI、五项可信原生和同源码完整69方法结果；未执行项保留待验状态。

PR #101 正常进入 main `297f15c` 后，[提交反馈专项 41540708075](https://github.com/WeOpen/WeGit/actions/runs/41540708075) 实际 smoke 1/1/0/0、专项 1/0/1/0。旧状态谓词与详情定位已通过，新的失败在私有 `pre-commit` shell hook 被托管应用沙盒拒绝执行，Git 返回 `Operation not permitted`；原断言期望 hook 自己输出的拒绝文案。

提交失败夹具改用暂存完成后建立的私有 `index.lock` 触发真实 commit 失败。详情必须包含自己的完整锁路径，锁和完整 index/工作文件字节必须保留；移除锁后继续原有取消、草稿、明暗主题及最终唯一新提交的断言。原测试超时、沙盒权限与全局 Git 配置保持。

独立真实 Git [检查回执](private-index-lock-check.json)确认失败退出128、自己的锁路径、HEAD/index/工作文件和锁字节保持，移除锁后只新增一个成功提交。7787f9b的[提交反馈41542561321](https://github.com/WeOpen/WeGit/actions/runs/41542561321)实际smoke/专项各1/1/0/0，77.527秒、194应用/33测试输入和四图四AX核验；该通过只属于该源码。视图修正后的托管专项和最终69方法仍待执行，本机不运行XCTest。

失败的完整 ZIP 为113,738,086bytes、2137项CRC，SHA256 `e1b452c5560a99db7720ebaa073b74ced2df4c40dbd975049135338ff2711149`；194应用和33测试输入逐项核对，显示已恢复，系统权限未改。[失败回执](feedback-commit-41540708075-failed.json)和[实际23.723333秒画面](feedback-commit-41540708075-visible.png)保留。反馈详情可伸出父窗口，后续成功证据使用完整屏幕截图并保留AX内容。

本轮仍通过 #98 收口：五个固定入口各须 smoke 及唯一专项实际1/1/0/0，再正常合入并完成同源码69/69/0/0的完整functional。剩余Issue、冗余PR和已归档分支只在该门禁通过后清理。正式验收沿用[维护者确认的延期条件](../../2026-11-01/v1-2-closeout/README.md)。
