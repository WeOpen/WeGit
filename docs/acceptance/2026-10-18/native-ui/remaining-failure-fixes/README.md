# 两处剩余功能失败的单项修正结果

[PR #28](https://github.com/WeOpen/WeGit/pull/28)，候选 `dfbbc198e0bfdd671ae142209002c970c4be5f13`，必需 CI 全绿后合入 main `2c2533c1f0ef7e084f57eae3144f616416e4d608`。

| 单项运行 | smoke | focused | focused 耗时 |
| --- | --- | --- | ---: |
| [39136314750](https://github.com/WeOpen/WeGit/actions/runs/39136314750) 搜索/键盘 | 1/1 | 1/1，零失败/跳过 | 62.191 秒 |
| [39136352333](https://github.com/WeOpen/WeGit/actions/runs/39136352333) 检查器恢复 | 1/1 | 1/1，零失败/跳过 | 57.099 秒 |

每个运行的 120 项应用输入与候选 Git 内容逐文件核对。相对 734b8e1，仅修正测试视口与探针同步，产品布局和键盘处理不变。失败原文与视频见相邻 remaining-failures 目录；通过后的几何、焦点树、浅深截图随本目录保存。

检查器实际覆盖恢复 History 与 Changes、最小宽度 1292、可见列表视口/检查器在窗口内且不重叠、内容可点击、关闭/重开和原 Git/文件数据断言。

键盘实际覆盖浅/深模式，方向键前 Unified 选中且 Keyboard Focused，RightArrow 后 Split 选中且 Keyboard Focused；原左键返回、分栏列标题、Git/文件状态不变以及 Option-Return 换行、Command-Return 提交与最终 Git message 断言均通过。

独立临时 Git 探针也确认：相同的空 porcelain 输出，默认 status 可刷新 index 字节/mtime，而 --no-optional-locks status 不写索引。只操作 mkdtemp 夹具，用户 HOME、全局 Git/GPG 配置均未写入。该探针支持测试同步原因，不替代实际 UI 结果。

main 2c2533c 的完整功能已独立派发 [39137123756](https://github.com/WeOpen/WeGit/actions/runs/39137123756)，已实际通过 45/45、144 个精确阅读组合通过，零失败/跳过；[完整证据](../final-functional/README.md) 保留全部计数与来源。因一次网络中断提前误派发到 734b8e1 的 39137078001 已取消，不计作验证。
