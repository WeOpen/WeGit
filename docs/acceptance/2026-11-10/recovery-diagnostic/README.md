# M1 恢复性能托管诊断

2026-11-10 的[诊断 42826412388](https://github.com/WeOpen/WeGit/actions/runs/42826412388)从可信 main `5c46c6348934e51691bd87f98bffff61769c1a74`运行，固定 PR132 源码 `028b627a6950afe370e1eb14f018818087b25738`。这是一份诊断记录，`canonicalValidation=false`；未执行 XCTest、UI 或完整版本验收。

可信入口由[PR137](https://github.com/WeOpen/WeGit/pull/137)正常合入。其[PR CI42826080946](https://github.com/WeOpen/WeGit/actions/runs/42826080946)和[main CI42826338680](https://github.com/WeOpen/WeGit/actions/runs/42826338680)的144项工具及适用策略通过。非产品范围的Native/Core/前端/site job依分流未执行；旧路径触发的场景诊断42826081045明确取消，不能当作通过。

## 原预算与结果

普通100文件/16,751,600bytes，大型1000文件/268,179,000bytes，各30个串行有效样本。所有原时间和RSS门槛保持；未使用重复的incompleteSamples增加计数。

| p95 | 普通 | 大型 | 原预算 |
| --- | ---: | ---: | ---: |
| 预览 | 317.59ms | 1017.79ms | <2000ms |
| Reset | 515.29ms | 1492.51ms | <2000ms |
| 恢复预览 | 173.75ms | 1119.77ms | <2000ms |
| 恢复 | 364.79ms | 1341.04ms | <2000ms |
| Reflog | 64.51ms | 55.98ms | <2000ms |
| 取消 | 1.43ms | 1.15ms | <500ms |
| RSS | 16,760,832bytes | 24,313,856bytes | 256/512MiB |

大型最慢Reset完整调用约1642.91ms，其中Git命令区间并集1408.60ms、未被命令覆盖234.31ms。进程外时间包含队列/Swift调度、路径与索引核对、备份复制/哈希/fsync等，且部分非命令I/O与Git重叠，不能单独归因为fsync。并发命令总和不等于墙钟。

同一产品源码本次未复现[CI42243209630](https://github.com/WeOpen/WeGit/actions/runs/42243209630)大型Reset p95 2209.83ms的超标。原失败仍保留；本次未改变产品保护、预算或必要门禁，也不将诊断替代正式批次结果。原失败没有内部时序，当前证据不足以确认其根因。

## 来源核验

原artifact ZIP为2,217,108bytes、18个CRC项，SHA-256 `698c4921357dea0c15787aa1dcf5e07bb126b9ce2d9d2d2662d1e6e97380fbcb`，与GitHub artifact digest一致。97个源码/资源blob逐项对照固定Git对象，编译前后摘要一致；可信Python/Swift及workflow对照main Git对象，实际检查器/资源与回执摘要一致，所有原数组重新计算p95后与回执一致。

- [原始样本与完整时序](result.json)
- [固定源解析](source-resolution.json)
- [源码、编译与诊断回执](diagnostic-receipt.json)
- [独立核验与慢样本分段](independent-verification.json)
- [实际GitHub作业状态](run.json)

原ZIP、二进制与编译/运行日志保留于可信工具工作树`.build/hosted-recovery-42826412388`；本目录保存可长期核对的原始JSON，不收录编译二进制。托管环境为arm64/macOS27.0.1/Xcode27.1、3CPU、image20261104.0337.1，文件系统缓存未控制，不能外推Intel/macOS26或生产安装性能。
