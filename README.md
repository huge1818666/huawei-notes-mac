# 华为备忘录（macOS）

`华为备忘录` 是一个基于 `Swift + AppKit + WebKit` 的 macOS 原生小应用，用来更稳定地访问华为云空间备忘录。它把网页能力包装成独立桌面应用，并通过轻量保活、网络恢复检测和前后台切换检查，尽量减少长时间挂着不用后掉线的问题。

## 适合谁用

- 想把华为备忘录当成单独的 macOS 应用来用
- 不想依赖 Safari 标签页一直开着
- 希望登录态和浏览数据与 Safari 分开保存
- 希望在网络波动或应用切回前台时自动补做连接检查

## 主要特性

- 独立 `WKWebView` 数据存储，登录态不会和 Safari 混在一起
- 定时执行轻量保活，默认不是整页强刷
- 检测到页面疑似离线时自动重载
- 检测网络恢复后自动重试连接
- 从后台回到前台时自动触发一次连接检查
- 尽量避开正在编辑输入的时机，减少打断

## 系统要求

- macOS 13 及以上
- 已安装 Xcode Command Line Tools
- 需要你自行登录华为账号

如果你的 Mac 还没装命令行工具，可以先执行：

```bash
xcode-select --install
```

## 构建与启动

在仓库根目录执行：

```bash
chmod +x build-app.sh
./build-app.sh
open "build/华为备忘录.app"
```

构建完成后，应用会输出到：

```text
build/华为备忘录.app
```

第一次打开后，请在应用内重新登录华为云空间。这个应用使用独立容器，不会直接复用 Safari 已保存的登录状态。

## 可选配置

应用通过 `defaults` 读取启动页和保活策略，可按需调整：

```bash
defaults write com.codex.huaweinotes HomeURL -string "https://cloud.huawei.com/"
defaults write com.codex.huaweinotes StartURL -string "https://cloud.huawei.com/home#/notepad/note/allNote"
defaults write com.codex.huaweinotes KeepAliveSeconds -float 180
defaults write com.codex.huaweinotes ReloadOnEveryProbe -bool false
```

配置项说明：

- `HomeURL`：点击“主页”时打开的地址，默认是华为云空间首页
- `StartURL`：点击“备忘录”或默认进入时使用的地址
- `KeepAliveSeconds`：保活间隔，默认 `240` 秒，最小有效值为 `60`
- `ReloadOnEveryProbe`：是否每次探测都整页刷新，默认 `false`

恢复默认配置：

```bash
defaults delete com.codex.huaweinotes
```

## 已知限制

- 如果华为服务端主动要求重新登录，这个应用只能缓解掉线，不能保证永不失效
- 初次登录、验证码、二次验证等流程仍需手动完成
- 这是非官方桌面包装器，与华为官方没有从属关系

## 项目结构

```text
.
├── AppBundle/                  # Info.plist 与应用图标资源
├── Sources/HuaweiNotesNative/  # Swift 源码
├── build-app.sh                # 一键构建 .app
├── Package.swift               # Swift Package 定义
└── huawei-notes-keepalive.applescript
```

## 许可证

默认按 MIT License 发布，欢迎自行修改、分发和继续完善。
