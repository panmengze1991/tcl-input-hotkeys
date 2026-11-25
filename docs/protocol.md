# T-Cast 局域网协议说明

Windows 与 macOS 两个平台的上层实现共同遵循同一套 TCL T-Cast「多屏互动」局域网协议。协议细节参考 [ha-tcl-tv protocol.md](https://github.com/DusKing1/ha-tcl-tv/blob/main/docs/protocol.md)。

## 1. 设备发现（UDP 6537）

- 客户端绑定本机 UDP `6537` 端口并启用广播。
- 向 `255.255.255.255` 以及各活跃 IPv4 网卡的子网广播地址周期性发送发现报文（以 `\0` 结尾）：

```text
1:<unix_timestamp_ms>:<client_name>:PHONE:1:<client_name>:<client_id>:0:0\0
```

- 电视回应报文按 `:` 分隔，当 `fields.count > 3` 且 `fields[3] == "TV"` 时，将来源 IPv4 地址和 `fields[2]`（电视名称）识别为可用设备。

## 2. 控制连接与帧格式（TCP 6553）

- 客户端连接电视 IPv4 的 TCP `6553` 端口（开启 `TCP_NODELAY`）。
- 每个消息帧由 **4 字节大端无符号长度** + **负载字节** 组成：

```text
[uint32_be length][payload]
```

## 3. 握手与可选加密

- 建立 TCP 连接后，先以明文发送握手帧：

```text
159>><client_name>>>1>><client_id>>>1
```

- 读取电视返回帧（忽略非 `159>>` 开头的通知帧），按 `>>` 拆分：
  - 当 `fields[0] == "159"` 时握手完成。
  - 若 `fields.count > 6` 且 `fields[6] == "1"`，后续发送的所有负载均需采用 **AES-128-CBC + PKCS7** 加密：
    - Key: `tnscreentnscreen`（16 字节 ASCII）
    - IV: `12 34 56 78 90 ab cd ef 12 34 56 78 90 ab cd ef`

## 4. 遥控指令与保活

- **发送按键**：`149>><key_code>`
- **连接保活**：每隔约 `4.5s` 发送 `150>>`

## 5. 常用遥控键码表

| 操作 | 键码 | CLI 命令名（macOS） |
| --- | --- | --- |
| 上 | `11` | `up` |
| 下 | `12` | `down` |
| 左 | `13` | `left` |
| 右 | `14` | `right` |
| 确定 | `15` | `ok` |
| 返回 | `16` | `back` |
| 电视主页 | `19` | `home` |
| 电源 | `20` | `power` |
| 音量加 | `21` | `volume-up` |
| 音量减 | `22` | `volume-down` |
| 静音 | `23` | `mute` |
| 信号源 | `29` | `source` |
