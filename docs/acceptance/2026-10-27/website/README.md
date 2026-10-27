# 网站集成验收 · 2026-10-27

范围为 [Issue #66](https://github.com/WeOpen/WeGit/issues/66) 的双语网站迁移、主题中心、404 恢复与相关构建/CI；不包含客户端功能或版本发布。集成分支为 `codex/66-website-refresh`，基于 main `596bec6edf9ef340f76abfed57f180bab5710daf`。最终提交、必需 CI 和合并结果以关联 PR 为准；编写本记录时托管检查尚待执行。

## 保留证据的来源

本目录原有 JPEG 和 JSON 来自此前本地网站复核。`verified-source-sha256.json` 记录当时的 72 个源码/素材输入，保留原始摘要，不改写为最终分支的验收。导入键盘入口与构建目录归属修复后，下列四项已不同于该清单：

- `site/scripts/build.py`
- `site/src/pages/themes.html`
- `site/src/scripts/app.js`
- `site/tests/test_build.py`

`theme-layout.json` 是 Codex/Chrome、中英文、7 个宽度共 28 组主题布局记录；`shared-navigation-footer.json` 是两种浏览器、中英文、浅深色、3 个宽度共 24 组共享页头/页脚对照。下载、导入提示、手机预览、搜索和菜单 JSON 分别记录当时的实际交互。它们说明历史源码的结果，不代表最终分支已经重新执行全部组合。

## 本次集成复核

集成执行者在修复后的分支运行以下检查，并保留实际结果：

| 检查 | 命令 | 结果与边界 |
| --- | --- | --- |
| JavaScript | `node --test site/tests/*.test.mjs` | 9/9，通过；发布行为测试文件另包含 11 个子场景 |
| 网站构建与 HTTP | `python3 -m unittest discover -s site/tests -p 'test_*.py' -v` | 11/11，通过；包括三种 base path、中英文、真实 404/HEAD、模块缓存、非归属目录拒绝和重复构建 |
| 原生主题协议 | `scripts/verify-themes.sh` | 373 项独立 Swift 行为检查通过；使用客户端模型与私有偏好，不执行 XCTest |
| 仓库策略 | `python3 scripts/ci/check_policy.py` | 通过；托管凭据扫描与必需 CI 仍单独执行 |
| 静态构建 | `python3 site/scripts/build.py --base-path ''` | 约 2.47 MB，低于 3 MB；逐文件预算检查通过 |

目录归属回归先在修复前复现：其他网站只含通用 `.nojekyll` 时，构建会错误替换其内容。修复后必须精确匹配非符号链接的 WeGit 专用标记；私有临时夹具的拒绝检查与可重复构建检查通过。

本次 Codex 浏览器在 382px 根路径预览中，通过 Tab 聚焦「导入主题文件」，Enter 打开文件选择器，并选择 `site/public/themes/ink.json`。预览显示 Ink 和导入成功提示；一次 Escape 关闭后焦点恢复到 `theme-import-button`，没有横向溢出，目标页控制台 error/warning 为空。Chrome 在 1512px 的真实缺失文档中输入“主题”，搜索仅保留主题中心；一次 Escape 关闭并恢复搜索按钮焦点，无损坏图片或横向溢出，目标页控制台 error/warning 为空。Chrome 已在最后的导入/目录归属修复后重载最终构建并重复搜索、Escape 与焦点恢复检查。新增截图和本轮原始日志由集成执行者留在当前会话的私有可视化目录，并在关联 PR 中引用。

## 限制

未在本机执行 XCTest。托管 `PR policy`、`Repository policy`、`Native macOS` 和网站构建结果仍以最终 PR 的实际运行记录为准。gstack 自动预检因测试映射和扫描子进程问题保留为 incomplete，不作为完整自动门禁通过的证明。

本记录属于本地网站与协议验收，未据此宣称部署完成、线上 LCP/CLS 达标或客户端发布验收完成。原作者报告和早期本地性能样本仍保留各自源码、环境和时间边界。
