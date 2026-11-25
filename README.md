# TCL 电视快捷键（Windows & macOS）

在电脑上通过局域网控制支持 T-Cast「多屏互动」的 TCL 电视，支持切换信号源、主页、方向导航、确定/返回、音量与静音等操作。

本项目采用 **跨平台分目录结构**：底层遵循同一套 [T-Cast 局域网协议](docs/protocol.md)，Windows 与 macOS 的上层应用、系统热键/鼠标钩子和界面交互各自独立实现，均不依赖第三方库。

## 目录结构

```text
.
├── docs/
│   └── protocol.md        # 公共 T-Cast UDP 发现、TCP 握手与遥控键码约定
├── windows/               # Windows 上层实现（C# / .NET Framework 4.x，系统托盘 + 全局热键/鼠标钩子）
│   ├── README.md
│   └── TclInputHotkeys.cs
└── macos/                 # macOS 上层实现（Swift / AppKit & SwiftUI，菜单栏遥控面板 + 全局键鼠 + 键盘锁定 + CLI）
    ├── README.md
    ├── build-app          # 编译并签名「TCL 遥控器.app」
    ├── tcl                # CLI 与快捷启动脚本
    ├── 启动 TCL 快捷键.command
    └── src/
        ├── TCast.swift        # T-Cast 局域网发现、握手、加密与发送
        ├── TCLRemoteApp.swift # 遥控服务、设备管理、CLI 与应用入口
        ├── Hotkeys.swift      # CGEventTap 全局键鼠拦截、键盘锁定与 SwiftUI 菜单栏面板
        ├── GenerateIcon.swift # 生成应用图标
        └── Info.plist
```

## 平台能力对比

| 特性 | Windows（[`windows/`](windows/README.md)） | macOS（[`macos/`](macos/README.md)） |
| --- | --- | --- |
| 实现语言与依赖 | C#（.NET Framework 4.x 自带 `csc.exe`，零依赖） | Swift（macOS 自带系统框架，零依赖） |
| 运行形态 | 系统托盘图标 + 控制台 | 菜单栏图标 + SwiftUI 遥控弹窗面板 + CLI |
| 全局快捷键修饰键 | `Ctrl + Alt` | `Command + Control` |
| 滚轮调音量 / 中键静音 | 支持（`Ctrl + Alt` + 滚轮 / 中键） | 支持（`Command + Control` + 滚轮 / 中键） |
| 键盘锁定直控电视模式 | 暂未提供 | 支持（面板开关 / `Command + Control + L` 切回 Mac） |
| 设备切换与手动输入 IP | 命令行 `--discover` / `--ip` | 面板设备菜单切换 / 重新搜索 / 手动输入 IP + CLI |

## 快速开始

- **Windows**：查看 [windows/README.md](windows/README.md)
- **macOS**：查看 [macos/README.md](macos/README.md)
- **协议说明**：查看 [docs/protocol.md](docs/protocol.md)

## 许可证

本项目采用 [MIT 许可证](LICENSE)。
