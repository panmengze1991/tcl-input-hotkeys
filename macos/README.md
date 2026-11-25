# TCL 电视快捷键 for macOS

原生 Swift 菜单栏应用与命令行工具，用于在 macOS 上通过局域网控制支持 T-Cast「多屏互动」的 TCL 电视，运行时仅使用 macOS 自带系统框架（要求 macOS 13.0 及以上）。

## 构建与启动

安装 Apple 命令行工具（`xcode-select --install`）后，在 `macos` 目录运行：

```sh
./build-app
```

构建完成后会生成 `TCL 遥控器.app`：

- 双击 `TCL 遥控器.app`（或双击 `启动 TCL 快捷键.command`）启动应用；
- 电视开机并与 Mac 连接同一局域网后，点击菜单栏中的电视图标打开遥控面板；
- 首次打开时，请允许「TCL 遥控器」访问本地网络。

> 如果直接运行 `./tcl` 或双击 `启动 TCL 快捷键.command` 时本地尚未构建 `TCL 遥控器.app`，脚本会自动先执行 `./build-app`。

## 全局键盘与鼠标控制

面板按钮可立即使用。需要全局快捷键或滚轮控制时，点击面板里的「启用全局键盘控制」，按 macOS 提示给「TCL 遥控器」开启 **辅助功能** 和 **输入监控** 权限。

| 快捷键 | 电视操作 |
| --- | --- |
| `Command + Control + I` | 打开信号源选择菜单 |
| `Command + Control + H` | 打开电视主页 |
| `Command + Control + 方向键 / Return / Esc` | 导航、确定、返回 |
| `Command + Control + 音量键` | 调整音量和静音 |
| `Command + Control + 滚轮或鼠标中键` | 调整音量或静音 |
| `Command + Control + = / - / M` | 音量加、音量减、静音 |

### 键盘控制电视（锁定模式）

打开面板里的「键盘控制电视」开关后，无需按住修饰键，可直接使用方向键、`Return`、`Esc`、`I`、`H`、音量键、`=`、`-`、`M`、滚轮或鼠标中键控制电视。

此时菜单栏会显示锁图标，其他普通键盘按键会被拦截，鼠标左键仍可正常操作 Mac。关闭开关或按 `Command + Control + L` 即可切回 Mac。

### 设备切换

可从面板里的设备菜单切换电视、重新搜索或手动输入电视的 IPv4 地址。右上角的更多菜单可退出应用。

## 命令行用法（CLI）

```sh
./tcl discover
./tcl source
./tcl volume-up --ip 192.168.1.10
./tcl hotkeys [--ip 192.168.1.10]
```

支持的遥控命令：`source`、`home`、`up`、`down`、`left`、`right`、`ok`、`back`、`volume-up`、`volume-down`、`mute`。

## 代码结构

- `src/TCast.swift`：T-Cast UDP 发现、TCP 连接、握手、AES 加密与保活
- `src/TCLRemoteApp.swift`：`RemoteKey` 键码表、`RemoteService` 设备与发送队列、CLI 与 `@main` 入口
- `src/Hotkeys.swift`：`CGEventTap` 全局键鼠拦截、键盘锁定状态、SwiftUI 遥控面板与菜单栏弹窗
- `src/GenerateIcon.swift`：生成 `Remote.icns` 应用图标
- `src/Info.plist`：应用 Bundle 配置与本地网络权限描述

## 参考

- 公共协议说明：[docs/protocol.md](../docs/protocol.md)
- Windows 版本：[windows/README.md](../windows/README.md)
- 返回总览：[README.md](../README.md)
