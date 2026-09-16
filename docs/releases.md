# 独立版本与 GitHub 发布

## 版本约定

- 工具 ID：`image-paste`。
- 产品名：`TianCai图片直粘`。
- 版本来源：`tools/image-paste/src/ImagePaste.csproj` 中 `<Version>`。
- 标签：`image-paste/v1.2.0`。
- 安装包：`image-paste-1.2.0-win-x64.zip`。
- 更新元数据：`image-paste-update.json`。

每个工具各自发版，不因为一个工具升级就提高其他工具的版本。

## 发布操作

先确认该版本 CHANGELOG 和测试完整，并将提交推送到 main。然后在准备发布时执行：

```powershell
git tag image-paste/v1.2.0
git push origin image-paste/v1.2.0
```

`release.yml` 解析标签并验证它与项目版本一致，只构建对应工具。自检通过后上传 ZIP、更新元数据和 SHA-256 校验文件到 **草稿 Release**。在 GitHub 检查说明和附件后发布草稿，用户才会在公开发布列表看到它。

普通提交不会发布版本。不覆盖已有正式版本或移动已发布标签；修复发布问题时使用新版本号。工作流会拒绝向已有同名 Release 追加或替换附件。

也可以在明确要正式发布、草稿构建成功后，通过发布标签代替网页操作：

```powershell
git tag publish/image-paste/v1.2.0
git push origin publish/image-paste/v1.2.0
```

`Publish verified draft` 会核对原版本的成功构建、工具版本、三个附件及 SHA-256，再将现有草稿正式发布。这个标签表示明确的正式发布指令，不能在仅需生成草稿时推送。

## 自动更新的后续接入

当前工作流提供发布附件和元数据，**客户端自动检查、下载和替换程序尚未实现**。

后续客户端应按 `<tool-id>/v` 筛选正式 Release，再读取匹配的 `<tool-id>-update.json`。不能使用仓库全局 latest 作为每个工具的版本来源。先过滤工具、草稿和预发布，再按语义版本比较，不按字符串排序。

元数据包含工具 ID、版本、目标平台、下载链接、文件大小和 SHA-256。哈希用于完整性校验，不替代发布者身份验证；正式自动升级还需约束下载源和校验可信发布来源。

升级应保留用户配置，等待当前任务完成，停止主程序并等待恢复类子进程退出，失败能回退旧版本。网络不可达时不能影响现有功能。
