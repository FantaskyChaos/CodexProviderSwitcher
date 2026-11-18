# Codex 提供商切换

一个 macOS 菜单栏工具，用于管理和切换 Codex CLI 的模型供应商配置。

## 功能

- 在 OpenAI 官方与本机已有外部供应商之间切换 Codex 会话。
- `Command` 多选多个主会话，一次预检、备份和切换，最后只重启一次 Codex。
- 自动包含所选主会话的子代理，并在批量写入前检查每个独立主会话。
- 切换后自动将 Codex 置于前台，等待定时任务退出确认，再重新打开目标会话。
- 检测跨供应商持久化 item ID；遇到无法可靠迁移的历史时阻止原地切换，避免会话进入不可继续状态。
- 跨供应商切换时清理旧推理缓存及远端引用，保留聊天正文、工具结果和调用关系。
- 加密消息若带有明文 `input_text`/`output_text`，迁移时保留明文并清理供应商绑定密文；确无明文替代的历史仍先提示，只有用户二次确认后才从活动副本移除，完整原件保留在 JSONL 备份中。
- 支持修复 `invalid_encrypted_content`、`persisted-item lookup` 以及切换后历史回放相关的 `Bad Request`；其他网络或服务错误仍需单独排查。
- 兼容新版 Codex 分页索引：修复保留每条原记录的字节位置和文件长度。
- 较大的历史工具图片无损归档到 `~/.codex/provider-switch-assets/<thread-id>/`，回放改用文件路径，降低大请求导致的断流风险。
- 所有写入均保留数据库和 rollout 备份。

## 要求

- macOS 14 或更新版本
- Swift 6 工具链

## 构建

```sh
swift build -c release
```

运行自测：

```sh
xcrun swiftc -parse-as-library -swift-version 6 \
  -Xcc -fmodule-map-file=Sources/CSQLite/module.modulemap -lsqlite3 \
  Tests/SelfTest.swift Sources/CodexProviderSwitcher/Models.swift \
  Sources/CodexProviderSwitcher/CodexStore.swift \
  Sources/CodexProviderSwitcher/ReplayCompatibility.swift \
  Sources/CodexProviderSwitcher/CodexForkClient.swift \
  Sources/CodexProviderSwitcher/CodexCurrentThreadDetector.swift \
  -o .build/SelfTest
.build/SelfTest
```

打包为 macOS 应用：

```sh
./Packaging/build-app.sh
```

打包后的 `.app` 位于 `dist/`。构建产物不纳入 Git；从源码构建即可重新生成。
