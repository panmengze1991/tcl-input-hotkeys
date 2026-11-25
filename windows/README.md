# TCL 电视快捷键 for Windows

在 Windows 上用键盘和鼠标控制同一局域网内支持 T-Cast「多屏互动」的 TCL 电视。程序运行时会显示系统托盘图标，可从图标菜单退出。

| 按键 | 电视操作 |
| --- | --- |
| `Ctrl + Alt + I` | 打开信号源菜单 |
| `Ctrl + Alt + 方向键` | 移动电视菜单焦点 |
| `Ctrl + Alt + Enter` | 确定 |
| `Ctrl + Alt + Esc` | 返回 |
| `Ctrl + Alt + H` | 打开电视系统桌面 |
| `Ctrl + Alt + 音量加/减` | 调整电视音量 |
| `Ctrl + Alt + 静音键` | 切换电视静音 |
| `Ctrl + Alt + 滚动滚轮` | 调整电视音量 |
| `Ctrl + Alt + 按下滚轮` | 切换电视静音 |

单独使用音量键时，Windows 照常控制电脑的音量和静音。鼠标滚轮和中键在普通操作时照常交给当前应用。电视主页键打开系统桌面，恢复切换前的应用任务需要电视提供额外的控制接口。

## 编译和运行

在装有 .NET Framework 4.x 的 64 位 Windows 上，进入 `windows` 目录后从 PowerShell 运行：

```powershell
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /codepage:65001 /target:exe /optimize+ /r:System.Windows.Forms.dll /r:System.Drawing.dll /out:TclInputHotkeys.exe TclInputHotkeys.cs
.\TclInputHotkeys.exe
```

## 命令行参数

- `TclInputHotkeys.exe`：默认自动连接发现的唯一一台 TCL 电视并常驻托盘
- `TclInputHotkeys.exe --discover`：扫描并列出局域网内的 TCL 电视
- `TclInputHotkeys.exe --ip TV_IP`：指定目标电视的 IPv4 地址
- `TclInputHotkeys.exe --source [--ip TV_IP]`：单次发送信号源按键后退出
- `TclInputHotkeys.exe --check-hotkeys`：检测所有全局热键和鼠标钩子是否可正常注册

保持电视开机，并将电视和电脑连接到同一个局域网。

## 参考

- 公共协议说明：[docs/protocol.md](../docs/protocol.md)
- Windows 输入接口：[RegisterHotKey](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-registerhotkey) 与 [LowLevelMouseProc](https://learn.microsoft.com/windows/win32/winmsg/lowlevelmouseproc)
- 返回总览：[README.md](../README.md)
