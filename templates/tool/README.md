# 新工具接入模板

此目录只是模板说明，不是实际工具，不参与构建。

1. 创建 `tools/<稳定英文ID>/src/`。
2. 把 `tool.json.example` 复制为该目录的 `tool.json`，填写 ID、品牌名、简介、项目路径及 EXE 文件名。
3. 创建 .NET 8 Windows 项目，设置 AssemblyName、RootNamespace 和 Version。
4. 实现不会弹窗或修改用户状态的 `--self-test <报告路径>`，报告含 passed、failed 字段，失败返回非 0。
5. 编写 README（用途、使用、限制、构建、配置位置和卸载方法）及 CHANGELOG。
6. 添加 `build.ps1` 便捷入口，参照 `tools/image-paste/build.ps1`，将 Tool 参数换成新 ID。
7. 更新根目录 README 工具目录。
8. 执行根目录统一校验、测试和构建命令。

不要把已有工具的 bin、obj、release、artifacts 或个人配置复制进新工具。
