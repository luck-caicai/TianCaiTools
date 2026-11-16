# TianCai快捷键开关

面向 Apple Silicon Mac 的原生菜单栏程序。使用 Swift、AppKit 和系统键盘事件 API，无第三方依赖、无驱动、无主窗口，不占 Dock。

## 使用

将发布包中的 `CtrlSwitch.app` 放入「应用程序」后打开，右上角会出现一个小开关：开启时显示 `Win Ctrl`，关闭时显示 `Mac Ctrl`。自行编译时应用位于本工具的 `release/CtrlSwitch.app`。

- 单击：开启 Windows 常用快捷键，或恢复 Mac 原生快捷键。绿色为开启，灰色为关闭，橙色为等待授权。
- 右键：查看当前状态、设置登录时启动，或退出程序。
- 首次运行：在程序打开的系统权限列表中开启 `CtrlSwitch.app`。macOS 27 的页面名称为「设备控制和数据访问」，较早版本称为「辅助功能」，都位于「隐私与安全」中。列表中没有时，点击「＋」选择 `CtrlSwitch.app`。授权后会自动生效。

建议将程序放在「应用程序」文件夹后再授权，之后保持应用的位置不变。程序会记住开关状态；登录时启动默认关闭，可从右键菜单开启。

如果自行重新编译后出现「系统开关已开，但程序仍提示授权」：先在系统权限列表中选中本程序，用「－」移除旧记录，再用「＋」重新添加当前安装的 `/Applications/CtrlSwitch.app`。本机构建采用 ad-hoc 签名，编译变更会更新签名；单纯关闭再开启旧授权可能仍保留旧版本记录。

| 组合键 | 开启后的操作 |
| --- | --- |
| Ctrl+C | 复制（Command+C） |
| Ctrl+V | 粘贴（Command+V） |
| Ctrl+S | 保存（Command+S） |
| Ctrl+A | 全选（Command+A） |
| Ctrl+X | 文本剪切（Command+X） |
| Ctrl+F | 查找（Command+F） |
| Ctrl+Z | 撤销（Command+Z） |

左右 Ctrl 均可使用。Ctrl、Command、Win、Alt 的按键身份和位置保持原样，原有 Command 快捷键照常有效。其他组合键及带 Shift、Option、Command、Fn 的扩展组合保持原样。Caps Lock 状态会保留。

Terminal、iTerm2、Ghostty、Warp、kitty、Alacritty、WezTerm 等独立终端保留 Ctrl+C 中断及其他原有控制操作。IDE 内嵌终端不属于独立终端，使用时可点击开关暂停转换。Finder 的文件移动沿用 macOS 原生方式：Command+C 后用 Option+Command+V 移动；本程序不会把 Ctrl+X 改造成文件移动操作。

程序仅在当前登录会话工作。登录界面和系统启用安全输入的区域由 macOS 管理，系统可能暂停键盘事件转换。它不读取剪贴板、不保存按键内容，也没有联网功能。

## 还原与卸载

点击菜单栏开关关闭即可还原；右键退出也会停止转换。程序不会改写系统修饰键设置或其他应用的快捷键配置。

卸载前如曾开启登录时启动，先从右键菜单关闭，再退出并删除 `CtrlSwitch.app`。可在辅助功能设置中移除该应用的授权。

## 开发

需要 Apple Command Line Tools，macOS 13 或更新版本，Apple Silicon。

```sh
zsh scripts/test.sh
zsh scripts/build.sh
```

构建产物位于本工具的 `release/CtrlSwitch.app` 和 `release/ctrl-switch-<版本>-macos-arm64.zip`，使用 ad-hoc 签名，尚未经过 Apple Developer ID 签名与公证。

```sh
release/CtrlSwitch.app/Contents/MacOS/CtrlSwitch --diagnose
```

诊断仅显示权限、版本、安装位置等状态，不包含用户输入。
