# 原生反馈布局与真实 Git 失败夹具

[Stash专项41543656156](https://github.com/WeOpen/WeGit/actions/runs/41543656156)在7787f9b实际smoke1/1/0/0、专项1/0/1/0。恢复字节和删除前列表已核对，失败在详情打开；[实际画面](feedback-stash-41543656156-visible.png)显示反馈被侧栏遮住，只露出消息尾部。AX按钮从x312开始，实际Stash列从x490开始。这是可见布局缺陷，不能只换点击方式。[完整失败回执](feedback-stash-41543656156-failed.json)保留114,854,087bytes ZIP、SHA256 `3ac01c60f87f1e8d10a755c7bada0a9e99baeac455890d5b743f518bc4c06b02`、2055CRC、23.072秒及源/显示核验。

主视图为原生分栏忽略横向安全区，同时已经为纯SwiftUI状态Banner和Changes提交区计算leadingInset。将同一个inset补给Stash反馈栏及Tag待核对/反馈栏，控件留在工作区内，原生分栏继续使用已有边界。布局复用已有几何计算；原业务读取、写入和反馈结果保持。

两个原生用例增加980/1360窗口、侧栏开关的bounds、可点击和截图检查，再确认实际详情及原业务结果。当前视图变更仍须新的固定候选CI、五项可信原生和同源码完整69方法结果；未执行项保留待验状态。

e0c0aca的[Stash41549084277](https://github.com/WeOpen/WeGit/actions/runs/41549084277)实际smoke/专项各1/1/0/0，119.391秒；16张图及16份AX核对了恢复字节、删除前后列表、侧栏和可见详情。请求980的第一张图实际1191，随后恢复为980；按真实frame统计范围，原始记录保留，文件名不充当尺寸证据。

同源[Tag41550804654](https://github.com/WeOpen/WeGit/actions/runs/41550804654)实际smoke1/1/0/0、专项1/0/1/0。按钮在[画面](feedback-tag-41550804654-visible.png)中存在，待核对状态也保留；失败在未分组HStack传播父标识、覆盖子按钮与目标的标识。[失败回执](feedback-tag-41550804654-failed.json)保留107,338,985bytes、SHA256 `915816d4a198531b8cb16f62e85a2699a5461af7e1d2ad4340c1e82931842b59`、1985CRC、36.753秒和源/显示核验。父栏明确contain分组，子控件继续保留自己的标识、原生名称和动作。新源码仍待相应实际验证。

5fbc888的[Tag41552816832](https://github.com/WeOpen/WeGit/actions/runs/41552816832)与[Stash41553952708](https://github.com/WeOpen/WeGit/actions/runs/41553952708)已实际smoke/focus各1/1/0/0；72.760/92.982秒，源、ZIP与显示核验，Tag8图8AX和Stash16图16AX实查。对应[CI41552703196](https://github.com/WeOpen/WeGit/actions/runs/41552703196)完整制品也已核验三套Git266/47、450原始性能样本、9+9签名、64模型和普通Release包。上述通过仍只属于5fbc888。

设置[41558675691](https://github.com/WeOpen/WeGit/actions/runs/41558675691)在[可见HelpTag](settings-lifecycle-41558675691-visible.png)已显示Git2.46+时失败；原生HelpTag没有AX label/value，旧文字查询无法匹配。[失败回执](settings-lifecycle-41558675691-failed.json)保留60,359,725bytes/SHA `a0dd70f3e66e50884e341720fe69464b8f166d7020d9392092f526b5713ad64e`、2047CRC及19.364秒。使用公开helpTags与原始截图，并以本机Vision从实际提示像素读取Git2.46+；[独立图像文字回执](native-help-ocr-verification.json)已通过。图像只在内存采样，未注入期待词汇；配置生命周期的原断言保留。新的测试驱动仍需托管实际验证。

f263ce6的[Settings41561858869](https://github.com/WeOpen/WeGit/actions/runs/41561858869)已取得HelpTag图像，但runner内Vision模型加载报告TextRecognition.CRImageReaderError1/unknownError，实际smoke1/1/0/0、专项1/0/1/0。[回执](settings-lifecycle-41561858869-failed.json)保留112,722,775bytes/SHA `57476000078bbf80e5b3f7ce540097f84f780a19751cf40d23f1ba7297a2207b`、2147CRC与25.113秒。测试负责留取原始提示图像及AX并执行完整配置/退出/取消过程；独立非XCTest验收工具随后核对该图像中的Git2.46+，文字检查失败仍保持验收失败。应用与系统权限不变。

PR #101 正常进入 main `297f15c` 后，[提交反馈专项 41540708075](https://github.com/WeOpen/WeGit/actions/runs/41540708075) 实际 smoke 1/1/0/0、专项 1/0/1/0。旧状态谓词与详情定位已通过，新的失败在私有 `pre-commit` shell hook 被托管应用沙盒拒绝执行，Git 返回 `Operation not permitted`；原断言期望 hook 自己输出的拒绝文案。

提交失败夹具改用暂存完成后建立的私有 `index.lock` 触发真实 commit 失败。详情必须包含自己的完整锁路径，锁和完整 index/工作文件字节必须保留；移除锁后继续原有取消、草稿、明暗主题及最终唯一新提交的断言。原测试超时、沙盒权限与全局 Git 配置保持。

独立真实 Git [检查回执](private-index-lock-check.json)确认失败退出128、自己的锁路径、HEAD/index/工作文件和锁字节保持，移除锁后只新增一个成功提交。7787f9b的[提交反馈41542561321](https://github.com/WeOpen/WeGit/actions/runs/41542561321)实际smoke/专项各1/1/0/0，77.527秒、194应用/33测试输入和四图四AX核验；该通过只属于该源码。视图修正后的托管专项和最终69方法仍待执行，本机不运行XCTest。

失败的完整 ZIP 为113,738,086bytes、2137项CRC，SHA256 `e1b452c5560a99db7720ebaa073b74ced2df4c40dbd975049135338ff2711149`；194应用和33测试输入逐项核对，显示已恢复，系统权限未改。[失败回执](feedback-commit-41540708075-failed.json)和[实际23.723333秒画面](feedback-commit-41540708075-visible.png)保留。反馈详情可伸出父窗口，后续成功证据使用完整屏幕截图并保留AX内容。

本轮仍通过 #98 收口：五个固定入口各须 smoke 及唯一专项实际1/1/0/0，再正常合入并完成同源码69/69/0/0的完整functional。剩余Issue、冗余PR和已归档分支只在该门禁通过后清理。正式验收沿用[维护者确认的延期条件](../../2026-11-01/v1-2-closeout/README.md)。
