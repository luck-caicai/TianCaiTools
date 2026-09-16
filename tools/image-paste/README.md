# TianCai图片直粘

C# / WinForms 编写的 Windows 托盘工具。截图或在浏览器中“复制图片”后，在桌面、资源管理器文件列表按 **Ctrl + V**，自动保存 PNG。

## 使用

1. 解压 `image-paste-<版本>-win-x64.zip` 到一个固定目录。
2. 双击 `TianCai图片直粘.exe`，程序进入系统托盘（可能在托盘折叠菜单内）。
3. 截图或复制图片，点击目标文件夹的文件列表，再按 Ctrl + V。
4. 生成 `图片_年月日_时分秒_毫秒.png`，重名会加序号，不覆盖已有文件。

粘贴处理期间，普通鼠标箭头临时切换为 Windows 系统忙碌光标（随鼠标主题显示转圈或沙漏），完成或失败后恢复原样。不显示额外的进度浮窗或成功提示，失败仍给出具体错误。系统光标不影响正常点击，也不修改鼠标主题配置；文本光标等其他形状保持原样。配套后台进程负责在主程序意外退出时恢复光标。

右键托盘图标可暂停、设置开机启动、打开最近保存的位置或退出。双击图标打开最近图片的位置。开机启动默认关闭；启用后请勿移动 EXE，若移动则在新位置重新启用。

右键托盘选择“工具所在位置”，即可打开当前运行程序所在文件夹并选中 EXE，方便找到程序或手动更新。

右键托盘选择“检查更新”，手动查询 GitHub 上图片直粘的正式版本。有更新时可打开官方发布页下载；没有更新或网络失败时会明确提示。检查期间仍可正常粘贴。不自动下载安装，不在后台定时联网。

程序无需管理员权限，发布包内置 .NET。支持 Windows 10/11 x64。剪贴板不会被替换，不会上传图片、不保存剪贴板历史，也不记录输入内容。

## 支持与边界

- 支持 PNG、DIB/DIBV5、Bitmap 图片数据，PNG 和常见 32 位 DIB 尽量保留透明度。
- 剪贴板已有文件对象时交给 Windows 正常复制，保留原文件格式与名称。
- 微信、QQ、编辑器以及资源管理器地址栏、搜索框、重命名不接管。
- 桌面使用系统实际桌面目录，支持桌面重定向。
- 支持桌面图标位于独立 WorkerW 宿主、以及显示桌面后焦点停在宿主的情况。
- 普通本地文件夹、可写的网络共享及移动磁盘可以保存；权限和网络故障会提示失败。
- 多标签页按活动文件视图匹配，无法确认目标时提示失败，不猜测目录。
- 搜索结果、回收站、此电脑、压缩包内部、手机 MTP 等虚拟位置不支持。
- 第一版仅接管 Ctrl + V，不接管右键粘贴、Shift + Insert、第三方文件管理器、打开/保存文件对话框。
- 只有图片 URL 或 HTML、没有图片数据时不会下载图片。剪贴板只含静态帧时不会恢复 GIF 动画。
- 单次原始数据限 256 MB，解码图片限 6400 万像素。
- 保存完成会通知资源管理器刷新；不会抢焦点或强制切换窗口。需要定位图片时双击托盘图标。
- 直接生成文件不进入资源管理器的复制/撤销历史，**不能用 Ctrl + Z 撤销本工具生成的图片**；可正常选中删除。
- 剪贴板或焦点在开始处理前变化会取消本次操作；开始编码后使用已固定的图片和目录。

## 构建

安装 .NET 8 SDK，在项目根目录运行：

```powershell
.\build.ps1
# 如果 SDK 不在 PATH：
.\build.ps1 -Dotnet 'C:\path\to\dotnet.exe'
```

输出在本工具的 `release\TianCai图片直粘` 和 `release\image-paste-<版本>-win-x64.zip`，同时生成更新元数据及 SHA-256 文件。当前没有实现客户端自动更新。

也可以从仓库根目录运行 `./scripts/build.ps1 -Tool image-paste`。稳定工具 ID 为 `image-paste`，源码项目在 `src/ImagePaste.csproj`。

## 验证

```powershell
Start-Process .\release\TianCai图片直粘\TianCai图片直粘.exe -ArgumentList '--self-test', "$PWD\artifacts\self-test.json" -Wait
```

请先创建 `artifacts` 目录。自检覆盖透明度、位图方向、通道掩码、24 位填充、损坏输入、PNG 回退及并发保存不覆盖文件。自检不会修改剪贴板。

1.3.1 验证：增加桌面宿主焦点、分离宿主、无焦点、重命名及菜单排除的自检；本机只读检查确认桌面图标位于 WorkerW 且焦点停在宿主。为保留旧版供检查更新测试，未运行新版托盘程序，截图到桌面、Win+D 后粘贴和失败后光标恢复仍需实机验收。

人工验收：Windows 截图粘贴到桌面；浏览器复制透明 PNG 粘贴到文件夹；多窗口及多标签页核对目标；复制普通文件后正常粘贴；地址栏、搜索、重命名及其他软件正常粘贴；长按 V 只生成一次；暂停和退出后不再接管。

异常日志：`%LOCALAPPDATA%\ImagePaste\error.log`，轮转到 `.old`，日志可能包含出错文件路径，不含图片内容或按键历史。

卸载：先在托盘取消开机启动，再退出并删除程序目录；可按需删除上述日志目录。

## 代码结构

- `PasteHook.cs`：独立消息线程上的低级键盘钩子，焦点判定及长按去重。
- `ShellFolder.cs`：Shell COM 活动视图与真实路径匹配。
- `ClipboardImage.cs`：带重试的剪贴板快照、PNG / DIB 解码。
- `ImageFile.cs`：先写临时文件再无覆盖重命名。
- `Program.cs`：托盘、单实例、开机启动及错误提示。
- `BusyCursor.cs`：系统忙碌光标及独立恢复进程。

接口参考：[Windows 剪贴板格式](https://learn.microsoft.com/zh-cn/windows/win32/dataxchg/standard-clipboard-formats)、[低级键盘钩子](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)、[Shell 活动视图](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishellbrowser-queryactiveshellview)。
