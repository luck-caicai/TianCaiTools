# 开发规范

## 新工具的最低目录

```text
tools/<id>/
  tool.json
  README.md
  CHANGELOG.md
  build.ps1
  src/<Project>.csproj
  scripts/                 可选，工具专属脚本
```

英文 ID 使用 `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`，保持永久稳定。中文产品名可调整，不影响更新识别。

`tool.json` 示例见 `templates/tool/tool.json.example`。`project` 必须是当前工具目录内的项目路径；`executable` 必须是发布后 EXE 的文件名。版本从项目 `<Version>` 读取，不在清单重复维护。

当前脚本约定 .NET 8 Windows 桌面项目，项目需设置 `<AssemblyName>` 对应 EXE 名称，以及明确的 `<Version>`、`<TargetFramework>`。自包含发布不使用裁剪，以免破坏 WinForms 和 Shell COM。

## 测试约定

工具通过命令行 `<exe> --self-test <报告绝对路径>` 执行非交互自检，成功退出码为 0，失败非 0，并写入 JSON 报告。该分支必须在启动托盘、单实例锁、快捷键或其他后台服务之前处理。

统一测试脚本先编译，再运行自检，设有超时，并验证报告存在且失败数为 0。报告至少包含 `passed` 和 `failed` 数值。不操作真实用户剪贴板、系统设置或外部账号。

UI、全局快捷键和实际文件管理器集成在本机另行验证；记录已验证场景、未验证场景和原因。

## 日常流程

1. 在对应工具目录中修改源码，涉及行为改变时补充相关验证。
2. 更新工具 README 和 CHANGELOG；准备发版时调整项目版本。
3. 运行 `scripts/validate.ps1`、相关工具的测试和构建。
4. 检查 `git diff`、`git status`，确认没有安装包、测试输出和个人信息。
5. 提交推送，由 Actions 再次校验、构建和自检。

PowerShell 脚本必须检查外部命令退出码。路径操作基于 `$PSScriptRoot`；移动或清理目录前确认路径位于预期项目内。

共享代码等出现实际复用需求再抽取。不要为了未来可能用到的更新、设置、日志功能，提前创建复杂公共框架。
