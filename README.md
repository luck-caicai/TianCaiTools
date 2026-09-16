# TianCaiTools · TianCai 小工具集

面向 Windows 的实用小工具。一个仓库维护多个工具，每个工具独立运行、独立版本、独立发布。

## 工具目录

| 工具 | 标识 | 说明 |
|---|---|---|
| [TianCai图片直粘](tools/image-paste/README.md) | `image-paste` | 将截图或复制的图片用 Ctrl + V 直接保存到桌面、文件夹 |

[下载发布版本](https://github.com/luck-caicai/TianCaiTools/releases) · [开发规范](docs/development.md) · [发布流程](docs/releases.md)

首次仓库整理只提交源码与工作流；安装包由后续发布流程提供。本地现有程序仍在对应工具的 `release/` 目录。

## 仓库结构

```text
TianCaiTools/
├─ AGENTS.md                  AI 与开发者共同遵守的约定
├─ tools/
│  └─ image-paste/
│     ├─ tool.json            稳定标识、名称、项目路径
│     ├─ src/                 C# 项目与源码
│     ├─ scripts/             专属辅助脚本
│     ├─ build.ps1            从工具目录构建的便捷入口
│     ├─ README.md
│     └─ CHANGELOG.md
├─ scripts/                   统一校验、构建和测试
├─ templates/tool/            新工具接入清单与示例
├─ docs/                      开发、版本及发布规范
└─ .github/workflows/         自动检查与独立发布
```

`release/`、`artifacts/`、`bin/`、`obj/` 仅保存在本地或 Actions 产物中，不进入源码仓库。

## 本地开发

安装 .NET 8 SDK 和 PowerShell 7，在仓库根目录执行：

```powershell
./scripts/validate.ps1
./scripts/test.ps1 -Tool image-paste
./scripts/build.ps1 -Tool image-paste
```

如果 SDK 未加入 PATH，可向构建/测试命令传入 `-Dotnet 'C:\path\to\dotnet.exe'`。

构建默认生成内置运行时的 Windows x64 便携版。未来可增加精简版；目前没有统一启动器或客户端自动升级功能。

## 加入新工具

在 `tools/<英文标识>/` 下开发，参照 [接入模板](templates/tool/README.md)，注册 `tool.json` 并更新上面的工具目录。工作流会自动发现工具，不需要逐个手工追加 CI 列表。
