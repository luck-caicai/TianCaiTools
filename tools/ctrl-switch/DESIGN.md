# Alt+Tab 与按需缩略图

## 模块

- `ShortcutTransformer` 保留原来的七组 Ctrl 转换和终端例外。
- `SwitcherState` 包含无系统副作用的按键状态、固定顺序选择、窗口 MRU、解码图片预算和截图准入规则。
- `EventTapController` 为两项功能共用一个键盘事件入口，监听按下、松开和修饰键变化。只吞掉已匹配的 Tab/Esc 事件，不重映射 Ctrl、Command 或 Option。
- `WindowInventory` 在串行后台队列进行 AX 查询，通过应用及窗口通知刷新；激活使用单独队列，避免等待窗口扫描。AX 调用有短超时与每个应用的扫描时间预算。
- `WindowSwitcherController` 管理一次选择会话、150 毫秒面板延迟和窗口激活。快捷切换不启动截图。
- `SwitcherPanel` 使用非激活 NSPanel、少量 AppKit 视图和 CALayer 展示卡片，取消时不改变前台焦点。
- `WindowPreviewProvider` 负责单次截图、全局单请求、后台小位图复制、会话隔离与有上限的短期缓存。

## 截图与内存

macOS 26+ 使用公开 ScreenCaptureKit 的 `SCScreenshotManager.captureScreenshot`，直接请求最多 480×300 像素的 SDR 输出。只处理选中窗口和当前可见卡片；不创建常驻 SCStream、不取音频、不写截图文件，也没有网络连接。

操作提交完成不代表异步截图完成。真实请求在回调前占据唯一槽位；超过 2 秒后暂停后续提交，槽位仍保留，直到系统实际回调。旧会话的结果不得进入新面板。重新启用预览仅在没有真实请求未完成时清除暂停状态。

输出再复制成小的自有 CGImage，及时放开系统返回的缓冲区。缓存以实际 bytesPerRow×height 计费，同时执行最多 12 张及 8 MiB 两项限制；按最近使用顺序淘汰。图层与缓存共享图像，淘汰、关闭面板与禁用时解除相应引用。30 秒没有新的使用会清理短期缓存。内存压力或锁屏会终止当前截图会话并清理图片。

缓存预算无法限制系统截图服务和绘制图层的全部开销。性能记录必须使用同口径的物理内存，并同时观察 WindowServer 与 replayd。

## 窗口身份与兼容性

通过 AX 获得可切换窗口，通过 CGWindowID 与 ScreenCaptureKit 窗口关联。使用动态查找的 `_AXUIElementGetWindow` 作为小型可选身份桥接；它是未公开的系统符号，缺失时只采用唯一匹配的公开 CG 窗口元数据，无法可靠关联时显示图标。截图后端不使用私有 SkyLight API。

普通窗口只显示系统报告为在屏幕上的窗口；系统可枚举的最小化窗口也加入。AX 不提供最小化窗口的桌面归属，激活时桌面切换遵循 macOS 的设置。全屏、跨桌面与复杂多显示器情况尚未完整验证。旧 macOS 保留图标模式，不承诺未经实测的截图兼容性。

## 参考

研究了 [AltTab](https://github.com/lwouis/alt-tab-macos) 固定提交 `950c1a4e749aef53637bf2833b4a09328cdbce8e` 的 WindowCaptureEvents、WindowThumbnails、SwitcherSession 和 LightImageLayer。借鉴异步更新、分辨率控制、会话内缓存和真实异步请求限流的设计；本实现独立编写，未引入其源码、素材、运行时或配置系统。

AltTab 的当前版本已经对全分辨率大图进行按需加载和缓存限制。此工具目前只提供卡片缩略图，以减少对大图和复杂兼容分支的需求。

## 验证边界

无界面自检只验证纯状态，不安装事件监听、不读剪贴板、不改系统设置、不打开窗口。`--exercise-switcher` 是单独的本机演练：真实面板与截图、500 次选择变化，不发送全局键盘事件，也不自动激活用户窗口。真实键盘、权限和焦点仍需要本机单独确认。运行中只读诊断不包含窗口标题、输入内容或截图。
