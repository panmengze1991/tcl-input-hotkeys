using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class TclInputHotkeys
{
    private const string ClientName = "Windows TV Hotkeys";
    private static readonly string ClientId = Guid.NewGuid().ToString("N").Substring(0, 16);
    private const int SourceKey = 29;
    private const int HomeKey = 19;
    private const int VolumeUpKey = 21;
    private const int VolumeDownKey = 22;
    private const int MuteKey = 23;

    private static readonly Dictionary<Keys, int> TvKeys = new Dictionary<Keys, int>
    {
        { Keys.I, SourceKey }, { Keys.H, HomeKey }, { Keys.Up, 11 }, { Keys.Down, 12 },
        { Keys.Left, 13 }, { Keys.Right, 14 }, { Keys.Enter, 15 }, { Keys.Escape, 16 },
        { Keys.VolumeUp, VolumeUpKey }, { Keys.VolumeDown, VolumeDownKey }, { Keys.VolumeMute, MuteKey }
    };

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--discover")
            {
                var devices = Discover();
                foreach (var device in devices)
                    Console.WriteLine("{0}  {1}", device.Key, device.Value);
                if (devices.Count == 0) Console.WriteLine("No TCL T-Cast TVs found.");
                return devices.Count == 0 ? 1 : 0;
            }

            if (args.Length == 1 && args[0] == "--check-hotkeys")
            {
                using (var hotkeys = new HotkeyWindow(key => { }))
                using (var mouse = new MouseShortcuts(key => { }))
                    Console.WriteLine("Registered all {0} global hotkeys and the mouse shortcuts.", TvKeys.Count);
                return 0;
            }

            bool sendOnce = args.Length > 0 && args[0] == "--source";
            int arg = sendOnce ? 1 : 0;
            IPAddress address = null;
            if (args.Length != arg &&
                (args.Length != arg + 2 || args[arg] != "--ip" ||
                 !IPAddress.TryParse(args[arg + 1], out address) ||
                 address.AddressFamily != AddressFamily.InterNetwork))
            {
                Console.Error.WriteLine("Usage: TclInputHotkeys [--source] [--ip TV_IP] | --discover | --check-hotkeys");
                return 2;
            }

            if (address == null)
            {
                Console.WriteLine("Looking for a TCL T-Cast TV...");
                var devices = Discover();
                if (devices.Count > 1)
                    throw new InvalidOperationException("Multiple TCL TVs found. Use --discover and then --ip TV_IP.");
                foreach (var device in devices)
                {
                    address = device.Key;
                    Console.WriteLine("Found {0}.", device.Value);
                }
                if (address == null)
                    throw new InvalidOperationException("TV not found. Turn on the TV, open Multi-Screen Interaction, or run with --ip TV_IP.");
            }

            if (sendOnce)
            {
                using (var tv = new TvConnection(address)) tv.SendKey(SourceKey);
                Console.WriteLine("Sent the Source key to {0}.", address);
                return 0;
            }

            using (var queue = new BlockingCollection<int>(32))
            using (var hotkeys = new HotkeyWindow(key => queue.TryAdd(key)))
            using (var mouse = new MouseShortcuts(key => queue.TryAdd(key)))
            using (var tray = new NotifyIcon())
            using (var menu = new ContextMenuStrip())
            {
                menu.Items.Add("信号源  Ctrl+Alt+I", null, (sender, e) => queue.TryAdd(SourceKey));
                menu.Items.Add("电视主页  Ctrl+Alt+H", null, (sender, e) => queue.TryAdd(HomeKey));
                menu.Items.Add("电视音量  Ctrl+Alt+音量键或滚轮").Enabled = false;
                menu.Items.Add("电视静音  Ctrl+Alt+静音键或鼠标中键").Enabled = false;
                menu.Items.Add("退出 TCL 信号源快捷键", null, (sender, e) => hotkeys.RequestExit());
                tray.Icon = SystemIcons.Application;
                tray.Text = "TCL 快捷键  Ctrl+Alt+I 信号源  Ctrl+Alt+H 主页";
                tray.ContextMenuStrip = menu;
                tray.Visible = true;
                var ui = SynchronizationContext.Current;
                var tv = new TvConnection(address);
                var worker = new Thread(() => SendKeys(tv, queue, error =>
                {
                    Console.Error.WriteLine("TV {0}: {1}", address, error);
                    if (ui != null && !queue.IsAddingCompleted)
                        ui.Post(_ => tray.ShowBalloonTip(3000, "TCL 信号源快捷键", "电视暂时无法接收指令。请检查电视是否开机并连接到同一网络。", ToolTipIcon.Warning), null);
                })) { IsBackground = true };
                worker.Start();
                Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
                {
                    e.Cancel = true;
                    hotkeys.RequestExit();
                };
                Console.WriteLine("TCL TV {0} | Ctrl+Alt+I: Source | Ctrl+Alt+H: Home", address);
                Console.WriteLine("Ctrl+Alt+arrows: Navigate | Ctrl+Alt+Enter: OK | Ctrl+Alt+Esc: Back");
                Console.WriteLine("Ctrl+Alt+Volume Up / Volume Down / Mute: TV audio");
                Console.WriteLine("Ctrl+Alt+mouse wheel: TV volume | Ctrl+Alt+middle button: TV mute");
                Console.WriteLine("To quit, use the tray icon or press Ctrl+C in this window.");
                Application.Run();
                queue.CompleteAdding();
                worker.Join();
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.GetBaseException().Message);
            return 1;
        }
    }

    private static Dictionary<IPAddress, string> Discover()
    {
        // T-Cast discovery responds on UDP 6537. Send to each local broadcast address.
        const int port = 6537;
        var destinations = new HashSet<IPAddress> { IPAddress.Broadcast };
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up) continue;
            foreach (var entry in adapter.GetIPProperties().UnicastAddresses)
            {
                if (entry.Address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(entry.Address)) continue;
                byte[] bytes = entry.Address.GetAddressBytes();
                byte[] mask = entry.IPv4Mask.GetAddressBytes();
                for (int i = 0; i < bytes.Length; i++) bytes[i] |= (byte)~mask[i];
                destinations.Add(new IPAddress(bytes));
            }
        }

        var devices = new Dictionary<IPAddress, string>();
        using (var udp = new UdpClient(port))
        {
            udp.EnableBroadcast = true;
            udp.Client.ReceiveTimeout = 350;
            var timer = Stopwatch.StartNew();
            var sender = new IPEndPoint(IPAddress.Any, 0);
            long nextBroadcast = 0;
            while (timer.ElapsedMilliseconds < 3800)
            {
                if (timer.ElapsedMilliseconds >= nextBroadcast)
                {
                    long timestamp = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                    byte[] packet = Encoding.UTF8.GetBytes(String.Format(
                        "1:{0}:{1}:PHONE:1:{1}:{2}:0:0\0", timestamp, ClientName, ClientId));
                    foreach (var destination in destinations)
                    {
                        try { udp.Send(packet, packet.Length, new IPEndPoint(destination, port)); }
                        catch (SocketException) { /* Another interface can still reach the TV. */ }
                    }
                    nextBroadcast = timer.ElapsedMilliseconds + 1100;
                }
                try
                {
                    string[] fields = Encoding.UTF8.GetString(udp.Receive(ref sender)).TrimEnd('\0').Split(':');
                    if (fields.Length > 3 && fields[3] == "TV") devices[sender.Address] = fields[2];
                }
                catch (SocketException error)
                {
                    if (error.SocketErrorCode != SocketError.TimedOut &&
                        error.SocketErrorCode != SocketError.ConnectionReset) throw;
                }
            }
        }
        return devices;
    }

    private static void SendKeys(TvConnection tv, BlockingCollection<int> queue, Action<string> reportError)
    {
        using (tv)
        {
            while (!queue.IsCompleted)
            {
                int key;
                bool hasKey = queue.TryTake(out key, 4500);
                if (queue.IsAddingCompleted) break;
                try
                {
                    if (hasKey)
                    {
                        tv.SendKey(key);
                        Console.WriteLine("Sent remote key {0}.", key);
                    }
                    else tv.KeepAlive();
                }
                catch (Exception error)
                {
                    tv.Disconnect();
                    if (hasKey) reportError(error.GetBaseException().Message);
                }
            }
        }
    }

    private sealed class TvConnection : IDisposable
    {
        private readonly IPAddress address;
        private readonly byte[] drainBuffer = new byte[4096];
        private TcpClient socket;
        private NetworkStream stream;
        private Aes cipher;

        internal TvConnection(IPAddress address) { this.address = address; }

        internal void SendKey(int key)
        {
            if (socket != null && socket.Client.Poll(0, SelectMode.SelectRead) && socket.Available == 0)
                Disconnect();
            if (stream == null) Connect();
            WriteFrame("149>>" + key);
            DrainNotifications();
        }

        internal void KeepAlive()
        {
            if (stream == null) return;
            WriteFrame("150>>");
            DrainNotifications();
        }

        private void Connect()
        {
            socket = new TcpClient { NoDelay = true, ReceiveTimeout = 2500, SendTimeout = 2500 };
            var attempt = socket.BeginConnect(address, 6553, null, null);
            using (var completed = attempt.AsyncWaitHandle)
            {
                if (!completed.WaitOne(2500)) throw new IOException("T-Cast connection timed out.");
                socket.EndConnect(attempt);
            }
            stream = socket.GetStream();
            WriteFrame("159>>" + ClientName + ">>1>>" + ClientId + ">>1");
            for (int i = 0; i < 12; i++)
            {
                int length = IPAddress.NetworkToHostOrder(BitConverter.ToInt32(ReadExactly(4), 0));
                if (length < 0 || length >= 1048576) throw new IOException("Invalid T-Cast frame length.");
                var fields = Encoding.UTF8.GetString(ReadExactly(length)).Split(new[] { ">>" }, StringSplitOptions.None);
                if (fields[0] != "159") continue; // The TV can send unsolicited frames before its handshake.
                if (fields.Length > 6 && fields[6] == "1")
                {
                    cipher = Aes.Create();
                    cipher.Key = Encoding.ASCII.GetBytes("tnscreentnscreen");
                    cipher.IV = new byte[] { 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF,
                                            0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF };
                }
                return;
            }
            throw new IOException("No T-Cast handshake received.");
        }

        private byte[] ReadExactly(int length)
        {
            var buffer = new byte[length];
            for (int offset = 0; offset < length;)
            {
                int count = stream.Read(buffer, offset, length - offset);
                if (count == 0) throw new EndOfStreamException("TV closed the connection.");
                offset += count;
            }
            return buffer;
        }

        private void WriteFrame(string text)
        {
            byte[] data = Encoding.UTF8.GetBytes(text);
            if (cipher != null)
            {
                using (var transform = cipher.CreateEncryptor())
                    data = transform.TransformFinalBlock(data, 0, data.Length);
            }
            byte[] frame = new byte[4 + data.Length];
            BitConverter.GetBytes(IPAddress.HostToNetworkOrder(data.Length)).CopyTo(frame, 0);
            data.CopyTo(frame, 4);
            stream.Write(frame, 0, frame.Length);
        }

        private void DrainNotifications()
        {
            for (int i = 0; i < 8 && stream.DataAvailable; i++)
                stream.Read(drainBuffer, 0, drainBuffer.Length);
        }

        internal void Disconnect()
        {
            if (socket != null) socket.Close();
            if (cipher != null) cipher.Dispose();
            stream = null;
            socket = null;
            cipher = null;
        }

        public void Dispose() { Disconnect(); }
    }

    private sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        private const int HotkeyMessage = 0x0312;
        private const int CloseMessage = 0x0010;
        private const uint Modifiers = 0x4003; // MOD_NOREPEAT | MOD_CONTROL | MOD_ALT
        private readonly List<int> registered = new List<int>();
        private readonly Action<int> onKey;

        internal HotkeyWindow(Action<int> onKey)
        {
            this.onKey = onKey;
            CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); // HWND_MESSAGE
            try
            {
                foreach (var binding in TvKeys)
                {
                    int id = (int)binding.Key;
                    if (!RegisterHotKey(Handle, id, Modifiers, (uint)binding.Key))
                        throw new InvalidOperationException("Unable to register Ctrl+Alt+" + binding.Key + ". Check for another copy or a shortcut conflict.");
                    registered.Add(id);
                }
            }
            catch { Dispose(); throw; }
        }

        internal void RequestExit() { PostMessage(Handle, CloseMessage, IntPtr.Zero, IntPtr.Zero); }

        protected override void WndProc(ref Message message)
        {
            int key;
            if (message.Msg == HotkeyMessage && TvKeys.TryGetValue((Keys)message.WParam.ToInt32(), out key))
                onKey(key);
            else if (message.Msg == CloseMessage)
                Application.ExitThread();
            else
                base.WndProc(ref message);
        }

        public void Dispose()
        {
            foreach (int id in registered) UnregisterHotKey(Handle, id);
            DestroyHandle();
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    }

    private sealed class MouseShortcuts : IDisposable
    {
        private const int LowLevelMouseHook = 14;
        private const int MiddleDown = 0x0207;
        private const int MiddleUp = 0x0208;
        private const int VerticalWheel = 0x020A;
        private const int WheelDelta = 120;
        private static readonly IntPtr Handled = new IntPtr(1);

        private readonly Action<int> onKey;
        private readonly MouseHookCallback callback;
        private readonly IntPtr hook;
        private bool middleDownHandled;
        private int wheelRemainder;

        internal MouseShortcuts(Action<int> onKey)
        {
            this.onKey = onKey;
            callback = OnMouseInput;
            hook = SetWindowsHookEx(LowLevelMouseHook, callback, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to register the mouse shortcuts.");
        }

        private IntPtr OnMouseInput(int code, IntPtr message, IntPtr data)
        {
            if (code == 0)
            {
                switch (message.ToInt32())
                {
                    case MiddleDown:
                        if (HasShortcutModifiers())
                        {
                            middleDownHandled = true;
                            onKey(MuteKey);
                            return Handled;
                        }
                        break;
                    case MiddleUp:
                        if (middleDownHandled)
                        {
                            middleDownHandled = false;
                            return Handled;
                        }
                        break;
                    case VerticalWheel:
                        if (HasShortcutModifiers())
                        {
                            var mouse = (MouseHookData)Marshal.PtrToStructure(data, typeof(MouseHookData));
                            wheelRemainder += unchecked((short)(mouse.MouseData >> 16));
                            int steps = wheelRemainder / WheelDelta;
                            wheelRemainder %= WheelDelta;
                            for (int i = 0; i < Math.Abs(steps); i++)
                                onKey(steps > 0 ? VolumeUpKey : VolumeDownKey);
                            return Handled;
                        }
                        wheelRemainder = 0;
                        break;
                }
            }
            return CallNextHookEx(hook, code, message, data);
        }

        private static bool HasShortcutModifiers()
        {
            return IsDown(Keys.ControlKey) && IsDown(Keys.Menu) && !IsDown(Keys.ShiftKey) &&
                   !IsDown(Keys.LWin) && !IsDown(Keys.RWin);
        }

        private static bool IsDown(Keys key) { return GetAsyncKeyState((int)key) < 0; }

        public void Dispose() { UnhookWindowsHookEx(hook); }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseHookData
        {
            public Point Position;
            public uint MouseData;
        }

        private delegate IntPtr MouseHookCallback(int code, IntPtr message, IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int id, MouseHookCallback callback, IntPtr module, uint threadId);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string moduleName);
    }
}
