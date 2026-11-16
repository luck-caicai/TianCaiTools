# 验证记录

## 自动检查

在 macOS 27.0.1、Apple Silicon、Swift 6.4 环境验证：

- `scripts/validate.ps1 -AsJson` 正确发现 `ctrl-switch` 与已有 `image-paste`，分别选择 macOS 和 Windows runner。
- 原生脚本与统一 PowerShell 入口均通过 534 项断言，报告写入 `artifacts/self-test.json`。
- 覆盖七组快捷键、左右 Ctrl、其他按键直通、额外修饰键、Caps Lock、终端例外、长按重复、按键松开配对和关闭后还原。
- 原生脚本与统一入口均能生成 Apple Silicon 的 APP、版本化 ZIP、SHA-256 文件和发布元数据。
- 打包应用通过 `codesign --verify --deep --strict`，ZIP 与发布元数据的大小、SHA-256 一致。

自检只对内存中的键盘事件标记做断言，不安装事件监听器，不修改系统设置、剪贴板或鼠标。

## 本机交互验证

导入仓库前，同版快捷键程序已在实机中授权运行；实际键盘的 Ctrl+A 全选和 Ctrl+F 查找由用户确认生效，菜单栏常驻与系统登录启动已确认。

仓库接入调整了目录、发布品牌和构建流程，键盘转换实现保持一致。新打包产物尚未替换本机正在使用的应用；没有把构建成功当作全部 UI 验证。

## 尚需的交互验证

- 在目标 Mac 上安装发布包并完成首次系统授权。
- 在浏览器、文档编辑器中逐项试用复制、粘贴、保存、全选、文本剪切、查找和撤销。
- 确认 Win Ctrl / Mac Ctrl 显示、开关关闭、退出、睡眠唤醒及登录启动的实际行为。
- 验证目标终端中的 Ctrl+C 中断保持可用；IDE 内嵌终端需要手动暂停转换。

Windows 图片直粘的运行验证交给 Windows CI；不在 Mac 上尝试执行 Windows 桌面程序。
