# Project instructions

1. 使用第一性原理确认真实目标、约束和成功标准。
2. 新任务先读 HANDOFF.MD；将新的实质性陷阱写入该文件。
3. 浏览器默认使用 Codex 浏览器和 Ego Lite，既有用户授权的 API 路径继续有效。
4. 上线、部署和生产环境任务必须保留性能预算并验收实际开销。
5. UI 避免不必要的次级标签和说明，用布局表达关系。
6. 纯 site 改动只校验 site，不运行仓库通用校验、Swift/Core/XCTest、原生 UI、Git/GPG 兼容性或客户端打包。范围包含 site/、scripts/build_website.py、scripts/ci/tests/test_website.py，以及随 site 修改追加的 HANDOFF.MD 记录；单独修改 HANDOFF 不属于纯 site。
7. site 任务使用其 Node/Python 测试、构建、原资源预算、Wrangler dry-run 与本地 Worker 校验。CI 的 Change scope 和必需结果汇总仅负责分流，不额外执行其他产品检查。
8. 混合应用或共享 CI 改动、共享品牌输入和无法确认的 Git 范围继续使用完整对应校验。本机不执行 XCTest，实际 XCTest 使用托管环境。
