# 配色与设置名称的实际 UI 回归

[PR #27](https://github.com/WeOpen/WeGit/pull/27) 最终候选 `aa2bcca1d76d60ba4bec85cafdc037342604465a`，必需 CI 全绿后合入 main `734b8e1e5d02ea1548ac2a3cc3338d9621d48d7c`。两个候选运行都在新的 hosted macOS 27.0.1/Xcode 27 VM 中实际执行，工作区干净、无权限变更；每份 120 项应用输入与候选 Git 内容逐文件匹配。

| 实际运行 | smoke | focused | focused 命令耗时 |
| --- | --- | --- | ---: |
| [39134781896](https://github.com/WeOpen/WeGit/actions/runs/39134781896) 主题 | 1/1 | 1/1，零失败/跳过 | 95.576 秒 |
| [39134839759](https://github.com/WeOpen/WeGit/actions/runs/39134839759) 字号 | 1/1 | 1/1，零失败/跳过 | 45.428 秒 |

原主题、窗口、键盘焦点、Git/草稿、24pt 字形断言保留。主题用例新增设置名称和实际截屏文字对比度断言，浅深 PNG 随本目录保存。每条采样 frame、背景 RGB、ink luminance 和比值见 `actual-pixel-contrasts.json`。

| 区域 | Light | Dark |
| --- | ---: | ---: |
| 选中导航文字（包含主题切换中两个原生背景） | 4.6056 / 4.6205 | 4.6056 / 4.6205 |
| 作者次要文字 | 4.7417 | 8.9032 |
| 浏览范围、搜索字段、提交操作、阅读选项四个菜单文字 | 4.8733 | 7.5935 |

文字 ROI 排除圆角/边框，背景取最高重复像素，字迹取至少重复三次的亮度极值；这是一组可复查的实际控件回归，不能替代所有字形/状态、系统显示选项或完整辅助访问认证。中间 e21b3b7 的根 tint 回退在截图复核发现后已撤回；最终保持根原生 accent，菜单文字单独用 accentText。

[必需 CI 39134793090](https://github.com/WeOpen/WeGit/actions/runs/39134793090) 通过 Native macOS / Repository policy，PR policy 和独立场景控制亦通过。CI 合成提交为 `bba0a6a0b759a4c7210d4050acd6cd660c167273`；归档 Release 的全部 120 项应用输入匹配候选源文件。VM 主题 checker 实际通过 278 项（216 色对、28 色相及既有 34 项），结果在 `vm-theme-checks.json`。本机仅编译和独立 checker，没有 XCTest。

这两项候选回归不等于最终主分支 45 项完整功能或独立审查通过。bcca7f3 的 43/45、144 组合成功是此前基线；新的两处失败诊断与最终统一回归单独记录。VM 原始 SIP disabled / Gatekeeper enabled，因此不能替代受保护机器的安装或发布签收。无报告忽略规则，无系统授权或全局 Git 配置变更。

补充逐字区域复核排除菜单箭头：四个菜单 Light 均为 6.3230:1、Dark 均为 8.0529:1，ROI 与原始采样见 menu-title-pixel-probes.json。前述 4.8733 / 7.5935 是包含箭头的整个内部区域，两个范围分别保留，不改写原测试回执。
