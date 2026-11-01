# 调查与验证边界

以下为本轮工具观察的调查笔记，非重新生成的原始失败日志。

- WindowStateProbe 初次运行时，toolbar 只有一个 SwiftUI 随机标识的仓库 item。之后添加完成的侧栏标识为 `com.apple.SwiftUI.navigationSplitView.toggleSidebar`，不等于 AppKit `.toggleSidebar`。使用 NSToolbar 公开 willAddItemNotification 延后配置，匹配当前 SwiftUI 元数据并保留原生追踪分隔及布局。元数据改变时保留可用的系统按钮；其他 OS/SwiftUI 版本待验。
- 初次误用不存在的 `NSToolbar.didAddItemNotification`，编译拒绝。核对本地 SDK 公开头文件后改用 willAddItemNotification，后续编译通过。
- 内嵌玻璃按钮和工具栏材质叠加造成双圆。内嵌标签改用 plain，由原生 toolbar 提供材质。底部 Add 使用 26 pt 标签与原生按钮内边距，视觉约 34 pt，与顶部图标按钮匹配；增强原生回归的精确尺寸断言尚未执行。
- List 默认滚动背景造成灰色列底，原生置顶 Section header 仍有灰色。关闭滚动背景，组标题改为有标题辅助访问 trait 的普通行，阅读底色与 Diff 共用 controlBackgroundColor；保留 inset 列表的原生选中反馈。
- 高层 sidebar-identity 标识覆盖子控件标识，已移除高层标识并给品牌与 Add 单独标识。实际 Add 打开/取消原生选择器通过。
- 应用级 darkAqua 覆盖会影响模板状态图标所继承的 appearance。主题改为仅覆盖应用窗口，状态窗口由系统继承。实际快捷弹层明暗与内边距通过；工具截图不包含整条系统菜单栏，不宣称已完成其对比度测量。
