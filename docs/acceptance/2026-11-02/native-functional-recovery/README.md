# v1.2 完整原生回归的失败与恢复

## PR100之后的实际结果

main `f2e8f97e233b4487f81d58eb577f3bbfd5a43ecd` 的 [完整原生41453998072](https://github.com/WeOpen/WeGit/actions/runs/41453998072) 实际smoke1/1/0/0、functional69总/64通过/5失败/0跳过，全部预期69个方法执行。完整ZIP229,507,351bytes、2835CRC、GitHub摘要、194应用与33测试输入核验；显示恢复、系统权限未改，18项运行时warning保留。[原始失败回执](functional-41453998072-failed.json)包含每项时长与失败方法。

剩余为四项反馈和设置生命周期。Foundation的CONTAINS空字符串实际返回false，导致默认消息条件拒绝正确的成功/待核对label。谓词修正仍要求状态前缀和非空完整消息，明确传入的消息仍须匹配。Stash详情Button点击和设置help悬停的失败视频保留实际鼠标位置，采用控件中心coordinate并继续检查真实详情/帮助出现及内容。原HEAD/index/工作字节、草稿、取消、同目标单次推送及恢复核对断言均保持。

五个新固定诊断入口各只在真实smoke通过后运行一个已有方法，原120/180秒及失败/跳过停止门禁保留。本机仅编译原生测试目标；当前App/Core源码未改。入口与驱动通过PR和必需CI正常进入可信main后，先完成五项托管实际验证，再执行完整scope；#98和剩余清理继续开放。

同源 [main CI41453684671](https://github.com/WeOpen/WeGit/actions/runs/41453684671) 已独立核验三套Git各266/47，五份原始数组共450有效样本在原预算内，隔离签名9+9、实际模型64项、359包/194应用输入与普通Release包内外receipt一致。该CI成功不替代上面的五项原生失败；正式验收延期条件仍按原矩阵保留。

main `9ee1ab243ed7d886de78cde91882121fd5fb1e2f` 已包含 PR #87 的最终实现。当前收口仍需要完整 functional 实际通过；本页保留该主线的失败和同源单项诊断，最新候选、主线重跑及清理结果跟踪 [#98](https://github.com/WeOpen/WeGit/issues/98)。

| 执行 | 实际结果 |
| --- | --- |
| [完整 functional 41368232586](https://github.com/WeOpen/WeGit/actions/runs/41368232586) | smoke 1/1/0/0。Blame 在关闭来源提交后打开文件历史，`file-history-path` AX 查询超时；随后 ChangesList 用例停止进展。5400 秒外层截止触发，functional xcresult 未完成，job 在120分钟取消。不能提供完整套件通过计数。 |
| [同源 smoke + Blame 41383018010](https://github.com/WeOpen/WeGit/actions/runs/41383018010) | smoke 与专项各1/1/0/0，专项 summary 67.605秒，194输入逐SHA一致；完整ZIP 62,923,408bytes、2045个CRC、临时显示恢复均核验。该结果只覆盖一个用例。 |

原始失败 [回执](functional-41368232586-failed.json) 和同源专项 [回执](blame-main-41383018010-verified.json) 分别保留。ZIP、完整日志、xcresult 与导出的截图位于主检出 `.build/v1-2-closeout-2026-11-02/`，也由对应 Actions artifact 保存。

完整scope之前只设置了90分钟进程组上限。新增单用例截止时必须保留真实长矩阵：历史144组阅读矩阵1778.596秒，最小窗口控件矩阵268.186秒，不能统一套用专项180秒。完整模式普通用例默认300秒，这两项分别在setup设置2700/600秒，最大2700秒；专项120/180秒、专项进程组300秒及整套5400秒仍保持。新增Python契约先复现缺失设置，再确认完整范围、固定专项边界和失败报告保留；本机74项检查通过，原生只编译，XCTest仍在托管环境执行。

Blame 的历史 Sheet 宽1080，超过980宽父窗口。父窗口截图会裁掉该 Sheet 边缘；这不是产品内容被裁剪的证明。该步骤改为完整屏幕截图，并断言路径和关闭按钮可操作。原固定历史路径/提交、原始字节、分页、Escape、草稿、HEAD、index及工作文件断言全部保留。

应用和Core源码保持同源；候选变更只涉及可信测试驱动、固定长矩阵的截止设置、Blame用例的额外检查/截图和文档。仍须当前必需CI、可信候选专项、正常集成后完整functional及实际制品核验。正式发布和 [维护者明确延期的验收](../../2026-11-01/v1-2-closeout/README.md) 保留各自边界。


## PR #99 合入后的完整结果

[functional 41394863246](https://github.com/WeOpen/WeGit/actions/runs/41394863246) 在 main `37b7dfa55a31a8c6a2d7de037e1083bca92d557e` 实际执行69项：56通过、13失败、0跳过。smoke1/1/0/0；Blame81.322秒和144组阅读矩阵1997.575秒通过，完整进程未触发5400秒上限。完整制品293,000,459bytes、3209项CRC、GitHub SHA256与194输入均已核对，直接xcresult同样报告69/56/13/0，显示恢复确认。详细[原始失败回执](functional-41394863246-failed.json)保留。

失败涉及6项反馈、3项检查器，以及选中行、设置生命周期、主题焦点和回收恢复各1项。辅助访问树证实检查器是Group、反馈容器只提供包含明确状态的label、回收恢复通过详情Button呈现；设置Git要求已移至原生help，分类图标的蓝色不能被计作焦点框。旧查询修正保留原业务断言和实际截图要求。选中行整块暂存后的空Diff是产品读取衔接断点，仍须修复并实际重验。

本轮仍未满足开发收口；6个开放issue和1个冗余草稿PR保持到当前源码完整功能回归实际通过。批准延期的正式验收条件继续保留。


独立模型控制链接当前普通Debug应用的实际AppState对象，[原算法的预取消调用](diff-cancellation-model-baseline-failed.json)实际清空已加载Diff，独立诊断保留了临时插桩与偏好域的源码回执；入口取消检查修正后32次保持显示和32次后续读取全部通过，私有HEAD、index与工作字节未变。偏好域由检查器独立注入并清理，CLI不执行XCTest或显示验收窗口。完整[模型回执](diff-cancellation-model-passed.json)保留构建输入；复验入口为`WEGIT_NATIVE_BUILD_PATH=<Debug DerivedData> scripts/verify-diff-read-cancellation.sh`，现有必需CI也执行此项。仍需当前固定候选的可信原生和完整主线69项回归。


候选`630344c`的检查器边界、恢复、选中行专项已实际smoke/focus各1/1/0/0，194输入和显示恢复核验。恢复及选中行原图已审阅；边界无成功附件，因此当前增加截图与辅助访问树后重验。主题专项通过焦点段，随后在Inspector打开时查询普通History的隐藏作者正文失败；作者矩阵将先关闭Inspector，原断言保留。上述通过/失败均只属于各自固定源码，不替代新候选或完整功能结果。

主线`37b7dfa`的CI另有[LFS真实预算失败](main37-lfs-performance-failed.json)：三类各30个[完整原始样本](main37-lfs-performance-raw-failed.json)，大型loose首读P95 2002.024458ms超过原2000ms，其余LFS指标通过。94输入相同，后续CI阶段未执行。该失败保留，新候选继续按原预算验证；已批准的旧正式验收延期不替代本项。
