# TCL 电视信号源和音量快捷键

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

在装有 .NET Framework 4.x 的 64 位 Windows 上，从 PowerShell 运行：

```powershell
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /codepage:65001 /target:exe /optimize+ /r:System.Windows.Forms.dll /r:System.Drawing.dll /out:TclInputHotkeys.exe TclInputHotkeys.cs
.\TclInputHotkeys.exe
```

默认自动连接发现的唯一一台 TCL 电视。如果有多台电视，先运行 `TclInputHotkeys.exe --discover` 查看地址，再用 `TclInputHotkeys.exe --ip TV_IP` 指定要控制的电视。保持电视开机，并将电视和电脑连接到同一个局域网。

协议参考 [T-Cast 局域网协议](https://github.com/DusKing1/ha-tcl-tv/blob/main/docs/protocol.md)。Windows 输入接口参考 [RegisterHotKey](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-registerhotkey) 和 [LowLevelMouseProc](https://learn.microsoft.com/windows/win32/winmsg/lowlevelmouseproc)。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。
