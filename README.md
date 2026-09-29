# Codex 提供商切换

一个 macOS 菜单栏工具，用于管理和切换 Codex CLI 的模型供应商配置。

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
