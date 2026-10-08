# Codex 提供商切换

一个 macOS 菜单栏工具，用于管理和切换 Codex CLI 的模型供应商配置。

## 功能

- 在 OpenAI 官方与本机已有外部供应商之间切换 Codex 会话。
- `Command` 多选多个主会话，一次预检、备份和切换，最后只重启一次 Codex。
- 自动包含所选主会话的子代理，并在批量写入前检查每个独立主会话。
- 切换后自动将 Codex 置于前台，等待定时任务退出确认，再重新打开目标会话。
- 检测跨供应商持久化 item ID；遇到无法可靠迁移的历史时阻止原地切换，避免会话进入不可继续状态。
- 所有写入均保留数据库和 rollout 备份。

## 要求

- macOS 14 或更新版本
- Swift 6 工具链

## 构建

```sh
swift build -c release
```

运行测试：

```sh
swift test
```

打包为 macOS 应用：

```sh
./Packaging/build-app.sh
```

打包后的 `.app` 位于 `dist/`。构建产物不纳入 Git；从源码构建即可重新生成。
