# v2 开发批次的实际回归记录

这些记录来自稳定候选 PR138 的前三轮集中验证；当前固定候选与后续结果见 [v2 进度](../../../V2_0_PROGRESS.md)。整体失败保留，只有实际成功且来源与工具链一致的子范围允许复用。它们不是 v2 发布验收。

| 固定候选 | 后端 CI | 实际通过与失败 | 工作区 UI |
| --- | --- | --- | --- |
| c8a3563 | [42832267661](https://github.com/WeOpen/WeGit/actions/runs/42832267661) | Apple Core407/70中6问题：私有配置夹具、旧am状态预期、公开下载错误类型；后续未执行 | [42832410175](https://github.com/WeOpen/WeGit/actions/runs/42832410175)：smoke1/1，专项0/7 |
| cfbbf9e | [42839694951](https://github.com/WeOpen/WeGit/actions/runs/42839694951) | 三套Git各407/70、OpenPGP各9通过；行为在迁移脚本缺rg处失败 | [42839695901](https://github.com/WeOpen/WeGit/actions/runs/42839695901)：smoke1/1，专项3/7（Submodule、快捷键、更新窗） |
| e9ae775 | [42848714148](https://github.com/WeOpen/WeGit/actions/runs/42848714148) | 同输入/工具链复用前轮Core和签名；迁移、685主题、42图标通过，独立菜单checker缺桥接源编译失败 | [42848712718](https://github.com/WeOpen/WeGit/actions/runs/42848712718)：smoke1/1，专项3/7（共享草稿模板、快捷键、更新窗） |

上述全部UI专项均实际执行7项，跳过为0；不能把跨不同源码轮次的通过项相加成完整通过。第三轮历史重开实际丢失选中提交，修补同步持久化；私有控制只证明同进程新AppState恢复，跨进程仍以正式UI为准。资源就绪、窗口遮挡、文本截断和AX字段的失败均以原截图/AX/执行日志定位，未增加timeout或放宽Git字节与对象断言。

每份JSON记录原ZIP大小/CRC/SHA、实际源码输入逐Git blob核验、job与测试结果。二进制、完整xcresult、截图与日志保留在原工作树`.build/v2-m5-flow/hosted-<run>`，不复制到文档或宣称已发布。

- [首轮后端来源核验](42832267661.json) · [首轮UI来源核验](42832410175.json)
- [第二轮后端来源核验](42839694951.json) · [第二轮UI来源核验](42839695901.json)
- [第三轮后端与复用核验](42848714148.json) · [第三轮UI来源核验](42848712718.json)

本机没有执行XCTest；实际XCTest均来自上述托管运行。生产更新key/feed、支持设备矩阵、正式性能、安装和发布仍保留独立门禁。
