import AppKit
import ApplicationServices
import Combine
import SwiftUI

final class KeyboardLock: ObservableObject {
    @Published var routesKeyboardToTV = false
    @Published var shortcutsAvailable = false
}

let keyboardLock = KeyboardLock()
private let controls: [Int64: RemoteKey] = [
    34: .source, 4: .home, 126: .up, 125: .down, 123: .left, 124: .right,
    36: .ok, 53: .back, 24: .volumeUp, 27: .volumeDown, 46: .mute,
]
private let mediaKeys: [Int: RemoteKey] = [0: .volumeUp, 1: .volumeDown, 7: .mute]
private let mediaEvent: UInt32 = 14
private let unlockKey: Int64 = 37 // L
private let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl]
private let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
private var tap: CFMachPort?
private var handledKeys = Set<Int64>()
private var handledMedia = Set<Int>()
private var handledMiddle = false
private var lastScroll = -Double.infinity

private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                    _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let shortcut = event.flags.intersection(modifiers) == shortcutModifiers
    let routesInput = shortcut || keyboardLock.routesKeyboardToTV
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        keyboardLock.routesKeyboardToTV = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .keyDown:
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat, handledKeys.contains(key), !routesInput || key == unlockKey { return nil }
        if keyboardLock.routesKeyboardToTV, shortcut, key == unlockKey {
            handledKeys.insert(key)
            keyboardLock.routesKeyboardToTV = false
            return nil
        }
        if routesInput, let command = controls[key] {
            handledKeys.insert(key)
            if command != .mute || !isRepeat { remote.send(command) }
            return nil
        }
        if keyboardLock.routesKeyboardToTV {
            handledKeys.insert(key)
            return nil
        }
    case .keyUp:
        let handled = handledKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
        if handled || keyboardLock.routesKeyboardToTV { return nil }
    case .scrollWheel:
        let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if routesInput && vertical != 0 {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastScroll >= 0.08 {
                remote.send(vertical > 0 ? .volumeUp : .volumeDown)
                lastScroll = now
            }
            return nil
        }
    case .otherMouseDown:
        if routesInput && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
            handledMiddle = true
            remote.send(.mute)
            return nil
        }
    case .otherMouseUp:
        if handledMiddle && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
            handledMiddle = false
            return nil
        }
    default:
        guard type.rawValue == mediaEvent else { break }
        if let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 {
            let code = (key.data1 >> 16) & 0xffff
            let state = (key.data1 >> 8) & 0xff
            if state == 0x0a, routesInput, let command = mediaKeys[code] {
                handledMedia.insert(code)
                if command != .mute || (key.data1 & 1) == 0 { remote.send(command) }
                return nil
            }
            if state == 0x0b && handledMedia.remove(code) != nil { return nil }
            if state == 0x0a && handledMedia.contains(code) { return nil }
            if keyboardLock.routesKeyboardToTV { return nil }
        }
    }
    return Unmanaged.passUnretained(event)
}

private struct RemoteButton: View {
    let symbol: String
    let label: String
    let command: RemoteKey
    let width: CGFloat
    var filled = true
    var primary = false

    var body: some View {
        Button {
            remote.send(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primary ? Color.white : Color.primary)
                .frame(width: width, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteButtonStyle(filled: filled, primary: primary))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct RemoteButtonStyle: ButtonStyle {
    let filled: Bool
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill = primary ? Color(red: 0.16, green: 0.36, blue: 0.86) : Color.primary
        let idleOpacity = primary ? 1.0 : filled ? 0.065 : 0
        let pressedOpacity = primary ? 0.78 : 0.16
        configuration.label.background(fill.opacity(configuration.isPressed ? pressedOpacity : idleOpacity),
                                       in: RoundedRectangle(cornerRadius: 12))
    }
}

private final class PowerHoldController: ObservableObject {
    @Published var isHolding = false
    @Published var hasTriggered = false
    @Published var progress: CGFloat = 0

    let duration: TimeInterval = 1.0
    private var holdStart: Date?
    private var holdTimer: Timer?
    private var resetWorkItem: DispatchWorkItem?

    func startHold(action: @escaping () -> Void) {
        guard !isHolding, !hasTriggered else { return }
        resetWorkItem?.cancel()
        holdTimer?.invalidate()
        isHolding = true
        hasTriggered = false
        progress = 0
        holdStart = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.holdStart else { return }
            let fraction = min(1.0, Date().timeIntervalSince(start) / self.duration)
            self.progress = CGFloat(fraction)
            if fraction >= 1.0 {
                self.completeHold(action: action)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func completeHold(action: @escaping () -> Void) {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        hasTriggered = true
        progress = 1.0
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        action()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self.progress = 0
            }
            self.isHolding = false
            self.hasTriggered = false
        }
        resetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: item)
    }

    func endHold() {
        if !hasTriggered {
            cancelHold()
        } else {
            isHolding = false
        }
    }

    func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        guard isHolding || progress > 0 else { return }
        isHolding = false
        withAnimation(.easeOut(duration: 0.16)) {
            progress = 0
        }
    }

    func resetImmediately() {
        resetWorkItem?.cancel()
        resetWorkItem = nil
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        isHolding = false
        hasTriggered = false
        progress = 0
    }
}

private let powerHoldController = PowerHoldController()

private struct PowerHoldButton: View {
    let width: CGFloat
    @ObservedObject var controller: PowerHoldController
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    private let accent = Color(red: 0.86, green: 0.22, blue: 0.22)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(accent.opacity(controller.isHolding ? 0.16 : 0.10))

            GeometryReader { geo in
                Rectangle()
                    .fill(accent.opacity(0.92))
                    .frame(width: max(0, geo.size.width * controller.progress), height: geo.size.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            labelContent(foreground: accent)

            GeometryReader { geo in
                labelContent(foreground: Color.white)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(0, geo.size.width * controller.progress))
                    }
            }
        }
        .frame(width: width, height: 40)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .opacity(isEnabled ? 1 : 0.45)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled else { return }
                    let inside = value.location.x >= -16 && value.location.x <= width + 16 &&
                                 value.location.y >= -16 && value.location.y <= 56
                    if !inside {
                        controller.cancelHold()
                        return
                    }
                    controller.startHold(action: action)
                }
                .onEnded { _ in
                    controller.endHold()
                }
        )
        .onDisappear { controller.resetImmediately() }
        .help("长按 1 秒触发电视关机")
        .accessibilityLabel("长按关机")
    }

    @ViewBuilder
    private func labelContent(foreground: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: controller.hasTriggered ? "checkmark" : "power")
                .font(.system(size: 13, weight: .semibold))
            Text(controller.hasTriggered ? "已发送关机" : (controller.isHolding ? "继续按住关机…" : "长按关机"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(foreground)
    }
}

private struct RemotePanel: View {
    @ObservedObject var capture: KeyboardLock
    @ObservedObject var remote: RemoteService

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("TCL 遥控器")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button("退出 TCL 快捷键") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多操作")
            }

            deviceMenu

            if capture.shortcutsAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("键盘控制电视", systemImage: capture.routesKeyboardToTV ? "lock.fill" : "lock.open")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("键盘控制电视", isOn: $capture.routesKeyboardToTV)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(remote.selected == nil)
                    }
                    Text(capture.routesKeyboardToTV ? "正在操作电视 · ⌘⌃L 切回 Mac" : "正在操作 Mac · ⌘⌃ 快捷键可控制电视")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("启用全局键盘控制", action: requestShortcutPermissions)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                RemoteButton(symbol: "arrow.right.to.line", label: "信号源", command: .source, width: 64)
                RemoteButton(symbol: "house", label: "电视主页", command: .home, width: 64)
                RemoteButton(symbol: "arrow.uturn.backward", label: "返回", command: .back, width: 64)
            }
            .disabled(remote.selected == nil)

            VStack(spacing: 2) {
                RemoteButton(symbol: "chevron.up", label: "上", command: .up, width: 40, filled: false)
                HStack(spacing: 2) {
                    RemoteButton(symbol: "chevron.left", label: "左", command: .left, width: 40, filled: false)
                    RemoteButton(symbol: "checkmark", label: "确定", command: .ok, width: 40, primary: true)
                    RemoteButton(symbol: "chevron.right", label: "右", command: .right, width: 40, filled: false)
                }
                RemoteButton(symbol: "chevron.down", label: "下", command: .down, width: 40, filled: false)
            }
            .padding(6)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 26))
            .disabled(remote.selected == nil)

            HStack(spacing: 8) {
                RemoteButton(symbol: "speaker.minus", label: "音量减", command: .volumeDown, width: 64)
                RemoteButton(symbol: "speaker.slash", label: "静音", command: .mute, width: 64)
                RemoteButton(symbol: "speaker.plus", label: "音量加", command: .volumeUp, width: 64)
            }
            .disabled(remote.selected == nil)

            PowerHoldButton(width: 208, controller: powerHoldController) { remote.powerOff() }
                .disabled(remote.selected == nil)
        }
        .padding(16)
        .fixedSize()
    }

    private var deviceMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(remote.devices) { device in
                    Button("\(device.name)（\(device.address)）") { remote.select(device) }
                }
                Button("重新搜索电视", action: remote.search)
                Button("手动输入 IP…", action: remote.enterAddress)
            } label: {
                Label(remote.selected?.name ?? (remote.isSearching ? "正在搜索电视…" : "选择电视"), systemImage: "tv")
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: 185, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            if let error = remote.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 208, alignment: .leading)
            } else if let status = remote.statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 208, alignment: .leading)
            } else if remote.selected == nil && !remote.isSearching && remote.devices.isEmpty {
                Text("未发现电视 · 请检查本地网络权限")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private final class RemotePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private func panelOrigin(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSPoint {
    let rightmost = max(visibleFrame.minX, visibleFrame.maxX - size.width)
    let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX), rightmost)
    return NSPoint(x: x, y: min(anchor.minY, visibleFrame.maxY) - size.height)
}

final class RemoteStatusItem: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = RemotePanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
    private var lockObservation: AnyCancellable?
    private var outsideClickMonitor: Any?
    private let hostingView: NSHostingView<RemotePanel>
    private var sizeObservations = Set<AnyCancellable>()

    init(capture: KeyboardLock, remote: RemoteService) {
        hostingView = NSHostingView(rootView: RemotePanel(capture: capture, remote: remote))
        super.init()
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        background.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.contentView = background
        lockObservation = capture.$routesKeyboardToTV.sink { [weak self] routesToTV in
            let label = routesToTV ? "TCL 遥控器：键盘控制电视" : "TCL 遥控器：键盘操作 Mac"
            self?.item.button?.image = NSImage(systemSymbolName: routesToTV ? "lock.fill" : "tv", accessibilityDescription: label)
            self?.item.button?.toolTip = label
        }
        capture.objectWillChange.merge(with: remote.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                self.placePanel()
            }
            .store(in: &sizeObservations)
    }

    @objc private func togglePanel(_ button: NSStatusBarButton) {
        if panel.isVisible {
            panel.close()
            return
        }
        placePanel()
        panel.orderFrontRegardless()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel.close()
        }
    }

    private func placePanel() {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return }
        let size = hostingView.fittingSize
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = panelOrigin(size: size, anchor: anchor, visibleFrame: screen.visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: panel.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

func installShortcutTap() {
    guard tap == nil, AXIsProcessTrusted() else { return }
    let types: [CGEventType] = [.keyDown, .keyUp, .scrollWheel, .otherMouseDown, .otherMouseUp]
    let mask = types.reduce(CGEventMask(1) << mediaEvent) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: handle, userInfo: nil) else { return }
    tap = eventTap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    keyboardLock.shortcutsAvailable = true
}

private func requestShortcutPermissions() {
    let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if !AXIsProcessTrustedWithOptions([option: true] as CFDictionary) {
        return
    }
    if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    installShortcutTap()
}
