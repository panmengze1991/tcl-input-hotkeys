import AppKit
import Combine

enum RemoteKey: UInt8 {
    case up = 11, down, left, right, ok, back
    case home = 19
    case volumeUp = 21, volumeDown, mute
    case source = 29

    static let commands: [String: RemoteKey] = [
        "source": .source, "home": .home, "up": .up, "down": .down, "left": .left, "right": .right,
        "ok": .ok, "back": .back, "volume-up": .volumeUp, "volume-down": .volumeDown, "mute": .mute,
    ]
}

final class RemoteService: ObservableObject {
    @Published private(set) var devices: [TVDevice] = []
    @Published private(set) var selected: TVDevice?
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private let client = TCastClient()
    private lazy var connection = TCastConnection(client: client)
    private let queue = DispatchQueue(label: "TCL 遥控指令", qos: .userInitiated)
    private let pending = DispatchSemaphore(value: 32)
    private let selectionLock = NSLock()
    private var selectedAddress: String?
    private let preferencesKey = "selectedTVAddress"
    private var keepAlive: DispatchSourceTimer?

    func start(preferredAddress: String?) {
        if let address = preferredAddress ?? UserDefaults.standard.string(forKey: preferencesKey),
           TCastClient.isAddress(address) {
            select(TVDevice(address: address, name: "TCL 电视"))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(4500), repeating: .milliseconds(4500))
        timer.setEventHandler { [weak self] in self?.connection.keepAlive() }
        timer.resume()
        keepAlive = timer
        search()
    }

    func select(_ device: TVDevice) {
        selected = device
        selectionLock.withLock { selectedAddress = device.address }
        UserDefaults.standard.set(device.address, forKey: preferencesKey)
        errorMessage = nil
    }

    func enterAddress() {
        keyboardLock.routesKeyboardToTV = false
        let alert = NSAlert()
        alert.messageText = "输入电视 IPv4 地址"
        alert.informativeText = "可以在电视的网络设置中查看地址。"
        let field = NSTextField(string: selected?.address ?? "")
        field.placeholderString = "192.168.1.10"
        field.frame.size.width = 200
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "使用此地址")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if TCastClient.isAddress(address) {
                select(devices.first { $0.address == address } ?? TVDevice(address: address, name: "TCL 电视"))
                return
            }
            alert.informativeText = "请输入有效的 IPv4 地址，例如 192.168.1.10。"
        }
    }

    func search() {
        guard !isSearching else { return }
        isSearching = true
        errorMessage = nil
        let client = client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try client.discover() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSearching = false
                switch result {
                case let .success(devices):
                    self.devices = devices
                    if let current = self.selected, let known = devices.first(where: { $0.address == current.address }) {
                        self.selected = known
                    } else if self.selected == nil, devices.count == 1, let only = devices.first {
                        self.select(only)
                    }
                case let .failure(error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func send(_ key: RemoteKey) {
        guard let address = selected?.address, pending.wait(timeout: .now()) == .success else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.pending.signal() }
            guard self.selectionLock.withLock({ self.selectedAddress == address }) else { return }
            let result = Result { try self.connection.send(key.rawValue, to: address) }
            DispatchQueue.main.async {
                guard self.selected?.address == address else { return }
                switch result {
                case .success: self.errorMessage = nil
                case let .failure(error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

let remote = RemoteService()

@main
enum TCLRemoteApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            do {
                try runCLI(Array(arguments.dropFirst()))
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let status = RemoteStatusItem(capture: keyboardLock, remote: remote)
        let preferredAddress = arguments.count == 2 && arguments[0] == "--ip" ? arguments[1] : nil
        remote.start(preferredAddress: preferredAddress)
        installShortcutTap()
        let permissionTimer = Timer(timeInterval: 1, repeats: true) { _ in installShortcutTap() }
        RunLoop.main.add(permissionTimer, forMode: .common)
        withExtendedLifetime(status) { app.run() }
    }

    private static func runCLI(_ arguments: [String]) throws {
        let client = TCastClient()
        if arguments == ["discover"] {
            let devices = try client.discover()
            guard !devices.isEmpty else { throw TCastError("未发现 TCL 电视。请确认电视开机且连接同一局域网。") }
            for device in devices { print("\(device.address)  \(device.name)") }
            return
        }
        guard let command = arguments.first, let key = RemoteKey.commands[command],
              arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--ip" && TCastClient.isAddress(arguments[2])) else {
            throw TCastError("用法：tcl discover | tcl <\(RemoteKey.commands.keys.sorted().joined(separator: "|"))|hotkeys> [--ip 电视地址]")
        }
        let address: String
        if arguments.count == 3 {
            address = arguments[2]
        } else {
            let devices = try client.discover()
            guard devices.count == 1, let device = devices.first else {
                throw TCastError(devices.isEmpty ? "未发现电视，请检查局域网或指定 --ip。" : "发现多台电视，请指定 --ip。")
            }
            address = device.address
        }
        try TCastConnection(client: client).send(key.rawValue, to: address)
        print("已向 \(address) 发送遥控指令 \(command)。")
    }
}
