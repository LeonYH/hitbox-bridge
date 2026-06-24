import AppKit
import ApplicationServices
import SwiftUI

private enum WindowMetrics {
    static let width: CGFloat = 820
    static let minimumWidth: CGFloat = 760
    static let compactHeight: CGFloat = 540
    static let logHeight: CGFloat = 720
}

private enum StatusKind {
    case running
    case pending
    case error
    case idle
}

private enum BridgeStatus {
    case stopped
    case starting
    case running
    case stopping
    case reconnecting(Double)
    case accessibilityNeeded
    case saveFailed
    case unavailable

    var text: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .reconnecting(let delay): return "Reconnecting in \(String(format: "%.1f", delay))s"
        case .accessibilityNeeded: return "Accessibility needed"
        case .saveFailed: return "Save failed"
        case .unavailable: return "Bridge unavailable"
        }
    }

    var kind: StatusKind {
        switch self {
        case .running: return .running
        case .starting, .stopping, .reconnecting: return .pending
        case .accessibilityNeeded, .saveFailed, .unavailable: return .error
        case .stopped: return .idle
        }
    }
}

struct ControlMapping: Identifiable, Equatable {
    let id = UUID()
    let control: String
    var key: String
}

private final class InputEngine {
    private let lock = NSLock()
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var controlKeyCodes: [String: CGKeyCode] = [:]
    private var activeControls: [String: CGKeyCode] = [:]
    private var keyDownCounts: [CGKeyCode: Int] = [:]

    func updateMappings(_ mappings: [String: CGKeyCode]) {
        lock.lock()
        releasePressedKeysLocked()
        controlKeyCodes = mappings
        lock.unlock()
    }

    func handle(control: String, down: Bool) {
        lock.lock()
        if down {
            guard let keyCode = controlKeyCodes[control] else {
                lock.unlock()
                return
            }
            pressLocked(control: control, keyCode: keyCode)
        } else {
            releaseLocked(control: control)
        }
        lock.unlock()
    }

    func releasePressedKeys() {
        lock.lock()
        releasePressedKeysLocked()
        lock.unlock()
    }

    private func pressLocked(control: String, keyCode: CGKeyCode) {
        if let oldKeyCode = activeControls[control] {
            if oldKeyCode == keyCode { return }
            releaseKeyLocked(oldKeyCode)
        }

        activeControls[control] = keyCode
        pressKeyLocked(keyCode)
    }

    private func releaseLocked(control: String) {
        guard let keyCode = activeControls.removeValue(forKey: control) else { return }
        releaseKeyLocked(keyCode)
    }

    private func pressKeyLocked(_ keyCode: CGKeyCode) {
        let count = keyDownCounts[keyCode, default: 0]
        keyDownCounts[keyCode] = count + 1
        if count == 0 {
            postKey(keyCode, down: true)
        }
    }

    private func releaseKeyLocked(_ keyCode: CGKeyCode) {
        let nextCount = max(0, keyDownCounts[keyCode, default: 0] - 1)
        keyDownCounts[keyCode] = nextCount
        if nextCount == 0 {
            keyDownCounts.removeValue(forKey: keyCode)
            postKey(keyCode, down: false)
        }
    }

    private func releasePressedKeysLocked() {
        for keyCode in keyDownCounts.keys {
            postKey(keyCode, down: false)
        }
        activeControls.removeAll()
        keyDownCounts.removeAll()
    }

    private func postKey(_ keyCode: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: down) else {
            return
        }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.post(tap: .cghidEventTap)
    }
}

private final class BridgeCallbackContext {
    let engine: InputEngine
    private let lock = NSLock()
    private var logHandler: ((String) -> Void)?
    private var eventLogHandler: ((String) -> Void)?
    private var connectionHandler: ((Bool) -> Void)?

    init(engine: InputEngine) {
        self.engine = engine
    }

    func setLogHandler(_ handler: ((String) -> Void)?) {
        lock.lock()
        logHandler = handler
        lock.unlock()
    }

    func setEventLogHandler(_ handler: ((String) -> Void)?) {
        lock.lock()
        eventLogHandler = handler
        lock.unlock()
    }

    func setConnectionHandler(_ handler: ((Bool) -> Void)?) {
        lock.lock()
        connectionHandler = handler
        lock.unlock()
    }

    func emitLog(_ message: String) {
        lock.lock()
        let handler = logHandler
        lock.unlock()
        handler?(message)
    }

    func emitEventLog(_ message: String) {
        lock.lock()
        let handler = eventLogHandler
        lock.unlock()
        handler?(message)
    }

    func emitConnection(_ connected: Bool) {
        lock.lock()
        let handler = connectionHandler
        lock.unlock()
        handler?(connected)
    }
}

private func bridgeEventCallback(_ context: UnsafeMutableRawPointer?,
                                 _ control: UnsafePointer<CChar>?,
                                 _ down: Bool) {
    guard let context, let control else { return }
    let callbackContext = Unmanaged<BridgeCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let controlName = String(cString: control)
    callbackContext.engine.handle(control: controlName, down: down)
    callbackContext.emitEventLog("\(controlName) \(down ? "down" : "up")\n")
}

private func bridgeLogCallback(_ context: UnsafeMutableRawPointer?,
                               _ message: UnsafePointer<CChar>?) {
    guard let context, let message else { return }
    let callbackContext = Unmanaged<BridgeCallbackContext>.fromOpaque(context).takeUnretainedValue()
    callbackContext.emitLog(String(cString: message))
}

private func bridgeConnectionCallback(_ context: UnsafeMutableRawPointer?,
                                      _ connected: Bool) {
    guard let context else { return }
    let callbackContext = Unmanaged<BridgeCallbackContext>.fromOpaque(context).takeUnretainedValue()
    callbackContext.emitConnection(connected)
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var isRunning = false
    @Published var devicePresent = false
    @Published fileprivate var bridgeStatus: BridgeStatus = .stopped
    @Published var mappings: [ControlMapping]
    @Published var logText = ""
    @Published var recordingControl: String?
    @Published var logsEnabled = false
    @Published var accessibilityTrusted = false
    @Published var mappingFeedback = ""
    @Published var mappingFeedbackIsError = false

    private let defaults: [(String, String)] = [
        ("UP", "W"),
        ("DOWN", "S"),
        ("LEFT", "A"),
        ("RIGHT", "D"),
        ("X", "U"),
        ("Y", "I"),
        ("RB", "O"),
        ("LB", "P"),
        ("A", "J"),
        ("B", "K"),
        ("RT", "L"),
        ("LT", ";"),
        ("LSB", "Y"),
        ("RSB", "H"),
    ]

    private let recordableKeyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
        6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        49: "SPACE", 50: "`",
    ]
    private lazy var keyCodes: [String: CGKeyCode] = Dictionary(
        uniqueKeysWithValues: recordableKeyLabels.map { ($0.value, CGKeyCode($0.key)) }
    )

    private let inputEngine = InputEngine()
    private lazy var callbackContext = BridgeCallbackContext(engine: inputEngine)
    private let bridgeQueue = DispatchQueue(label: "com.local.hitboxbridge.usb", qos: .userInteractive)
    private let deviceMonitorQueue = DispatchQueue(label: "com.local.hitboxbridge.device-monitor", qos: .utility)
    private var bridge: OpaquePointer?
    private var bridgeRunning = false
    private var deviceMonitor: DispatchSourceTimer?
    private var keyMonitor: Any?
    private var reconnectWorkItem: DispatchWorkItem?
    private var accessibilityWorkItem: DispatchWorkItem?
    private var mappingFeedbackWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var bridgeStartTime: Date?

    init() {
        mappings = defaults.map { ControlMapping(control: $0.0, key: $0.1) }
        loadMappings()
        refreshControlKeyCodes()
        refreshAccessibilityStatus()
    }

    var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("8BitDo Hitbox Bridge", isDirectory: true)
            .appendingPathComponent("keymap.conf")
    }

    var deviceStatusText: String {
        devicePresent ? "Connected" : "Disconnected"
    }

    func setBridgeEnabled(_ enabled: Bool) {
        if enabled {
            recordingControl = nil
            isRunning = true
            reconnectAttempt = 0
            cancelReconnect()
            startBridge()
        } else {
            isRunning = false
            cancelReconnect()
            cancelAccessibilityPolling()
            stopBridge()
        }
    }

    @discardableResult
    func applyMappings() -> Bool {
        guard !isRunning else { return false }

        do {
            refreshControlKeyCodes()
            try saveMappings()
            inputEngine.releasePressedKeys()
            bridgeStatus = .stopped
            appendLog("Saved keymap: \(configURL.path)\n")
            showMappingFeedback("Saved")
            return true
        } catch {
            bridgeStatus = .saveFailed
            showMappingFeedback("Save failed", isError: true, autoClear: false)
            appendLog("Save failed: \(error.localizedDescription)\n")
            return false
        }
    }

    func resetDefaults() {
        guard !isRunning else { return }

        mappings = defaults.map { ControlMapping(control: $0.0, key: $0.1) }
        if applyMappings() {
            showMappingFeedback("Defaults restored")
        }
    }

    func setLogsEnabled(_ enabled: Bool) {
        guard logsEnabled != enabled else { return }

        logsEnabled = enabled
        refreshEventLogHandler()
        resizeWindowForLogs(enabled)
        if enabled {
            appendLog("Log enabled.\n")
        } else {
            logText = ""
        }
    }

    func beginRecording(control: String) {
        guard !isRunning else { return }

        recordingControl = control
        appendLog("Recording \(control). Press a letter, number, punctuation key, or Space.\n")
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    func startDeviceMonitoring() {
        guard deviceMonitor == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: deviceMonitorQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(750), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let present = hitbox_bridge_device_present()
            Task { @MainActor in
                self?.devicePresent = present
            }
        }
        deviceMonitor = timer
        timer.resume()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        refreshAccessibilityStatus()
        if isRunning && !accessibilityTrusted {
            bridgeStatus = .accessibilityNeeded
            scheduleAccessibilityPolling()
        }
        NSWorkspace.shared.open(url)
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func stopForAppQuit() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRunning = false
        cancelReconnect()
        cancelAccessibilityPolling()
        cancelMappingFeedbackClear()
        deviceMonitor?.cancel()
        deviceMonitor = nil
        stopBridge()
    }

    private func startBridge() {
        guard isRunning else { return }
        guard bridge == nil else { return }

        guard ensureAccessibilityPermission() else {
            bridgeRunning = false
            bridgeStatus = .accessibilityNeeded
            appendLog("Accessibility permission is required for the app before enabling the bridge.\n")
            scheduleAccessibilityPolling()
            return
        }
        cancelAccessibilityPolling()

        do {
            try saveMappings()
        } catch {
            isRunning = false
            bridgeRunning = false
            bridgeStatus = .saveFailed
            appendLog("Save failed: \(error.localizedDescription)\n")
            return
        }

        callbackContext.setLogHandler { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        callbackContext.setConnectionHandler { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if connected && self.isRunning {
                    self.bridgeStatus = .running
                }
            }
        }
        refreshEventLogHandler()

        guard let nextBridge = hitbox_bridge_create(bridgeEventCallback,
                                                    bridgeLogCallback,
                                                    bridgeConnectionCallback,
                                                    Unmanaged.passUnretained(callbackContext).toOpaque()) else {
            isRunning = false
            bridgeRunning = false
            bridgeStatus = .unavailable
            appendLog("Cannot create embedded USB bridge.\n")
            return
        }

        appendLog("Starting embedded bridge...\n")
        bridge = nextBridge
        bridgeRunning = true
        bridgeStartTime = Date()
        bridgeStatus = .starting

        let bridgeAddress = UInt(bitPattern: nextBridge)
        bridgeQueue.async { [weak self, bridgeAddress] in
            guard let runningBridge = OpaquePointer(bitPattern: bridgeAddress) else { return }

            let status = hitbox_bridge_run(runningBridge, true, 0)

            Task { @MainActor in
                if let self {
                    self.handleTermination(bridge: runningBridge, status: status)
                } else {
                    hitbox_bridge_destroy(runningBridge)
                }
            }
        }
    }

    private func stopBridge() {
        inputEngine.releasePressedKeys()

        guard let bridge else {
            bridgeRunning = false
            bridgeStatus = .stopped
            return
        }

        bridgeStatus = .stopping
        hitbox_bridge_stop(bridge)
    }

    private func handleTermination(bridge finishedBridge: OpaquePointer, status: Int32) {
        guard bridge == finishedBridge else { return }

        if let bridgeStartTime, Date().timeIntervalSince(bridgeStartTime) > 10 {
            reconnectAttempt = 0
        }

        inputEngine.releasePressedKeys()
        hitbox_bridge_destroy(finishedBridge)
        clearBridge()
        bridgeRunning = false

        if isRunning {
            appendLog("Embedded bridge exited with status \(status). Reconnecting...\n")
            scheduleReconnect()
            return
        }

        bridgeStatus = .stopped
        appendLog("Embedded bridge exited with status \(status).\n")
    }

    private func clearBridge() {
        bridge = nil
        bridgeStartTime = nil
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func cancelAccessibilityPolling() {
        accessibilityWorkItem?.cancel()
        accessibilityWorkItem = nil
    }

    private func scheduleAccessibilityPolling() {
        guard isRunning else { return }

        cancelAccessibilityPolling()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning, !self.bridgeRunning else { return }
                self.accessibilityWorkItem = nil
                self.refreshAccessibilityStatus()
                if self.accessibilityTrusted {
                    self.reconnectAttempt = 0
                    self.startBridge()
                } else {
                    self.scheduleAccessibilityPolling()
                }
            }
        }
        accessibilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        guard accessibilityTrusted else {
            bridgeStatus = .accessibilityNeeded
            scheduleAccessibilityPolling()
            return
        }

        cancelReconnect()
        let delay = min(5.0, 0.5 * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        bridgeStatus = .reconnecting(delay)

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.reconnectWorkItem = nil
                self.startBridge()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            accessibilityTrusted = true
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityTrusted = trusted
        return trusted
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard let control = recordingControl else {
            return event
        }

        if event.keyCode == 53 {
            recordingControl = nil
            appendLog("Recording cancelled.\n")
            return nil
        }

        guard let label = recordableKeyLabels[event.keyCode] else {
            appendLog("Unsupported key. Use letters, numbers, punctuation, or Space.\n")
            return nil
        }

        updateMapping(control: control, key: label)
        recordingControl = nil
        if applyMappings() {
            showMappingFeedback("\(control) mapped to \(label)")
        }
        appendLog("\(control) mapped to \(label).\n")
        return nil
    }

    private func updateMapping(control: String, key: String) {
        guard let index = mappings.firstIndex(where: { $0.control == control }) else {
            return
        }
        mappings[index].key = key
    }

    private func loadMappings() {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }

        var loaded = Dictionary(uniqueKeysWithValues: defaults)
        for rawLine in text.components(separatedBy: .newlines) {
            let content = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let pieces = content.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { continue }
            loaded[pieces[0].uppercased()] = pieces[1].uppercased()
        }

        mappings = defaults.map { pair in
            ControlMapping(control: pair.0, key: loaded[pair.0] ?? pair.1)
        }
        refreshControlKeyCodes()
    }

    private func refreshControlKeyCodes() {
        var next: [String: CGKeyCode] = [:]
        for mapping in mappings {
            if mapping.key.isEmpty {
                continue
            }
            guard let keyCode = keyCodes[mapping.key] else {
                appendLog("No key code for \(mapping.control)=\(mapping.key).\n")
                continue
            }
            next[mapping.control] = keyCode
        }
        inputEngine.updateMappings(next)
    }

    private func saveMappings() throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let body = mappings
            .map { "\($0.control)=\($0.key)" }
            .joined(separator: "\n") + "\n"
        try body.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func appendLog(_ text: String) {
        guard logsEnabled else { return }

        logText.append(text)
        if logText.count > 12_000 {
            logText.removeFirst(logText.count - 12_000)
        }
    }

    private func refreshEventLogHandler() {
        if logsEnabled {
            callbackContext.setEventLogHandler { [weak self] message in
                Task { @MainActor in
                    self?.appendLog(message)
                }
            }
        } else {
            callbackContext.setEventLogHandler(nil)
        }
    }

    private func showMappingFeedback(_ text: String, isError: Bool = false, autoClear: Bool = true) {
        cancelMappingFeedbackClear()
        mappingFeedback = text
        mappingFeedbackIsError = isError

        guard autoClear else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.mappingFeedback == text else { return }
                self.mappingFeedback = ""
                self.mappingFeedbackIsError = false
                self.mappingFeedbackWorkItem = nil
            }
        }
        mappingFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func cancelMappingFeedbackClear() {
        mappingFeedbackWorkItem?.cancel()
        mappingFeedbackWorkItem = nil
    }

    private func resizeWindowForLogs(_ enabled: Bool) {
        let targetContentHeight = enabled ? WindowMetrics.logHeight : WindowMetrics.compactHeight

        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }

            let currentFrame = window.frame
            let currentContentRect = window.contentRect(forFrameRect: currentFrame)
            var targetContentRect = currentContentRect
            targetContentRect.size.height = targetContentHeight

            var targetFrame = window.frameRect(forContentRect: targetContentRect)
            targetFrame.origin.x = currentFrame.origin.x
            targetFrame.origin.y = currentFrame.maxY - targetFrame.height

            if let visibleFrame = window.screen?.visibleFrame {
                targetFrame.origin.y = max(visibleFrame.minY, targetFrame.origin.y)
                targetFrame.origin.x = min(
                    max(visibleFrame.minX, targetFrame.origin.x),
                    visibleFrame.maxX - targetFrame.width
                )
            }

            window.contentMinSize = NSSize(
                width: WindowMetrics.minimumWidth,
                height: targetContentHeight
            )

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().setFrame(targetFrame, display: true)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        ZStack {
            MaterialTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TopAppBar()
                    KeyMappingPanel()
                    LogPanel()
                }
                .padding(20)
            }
        }
        .frame(minWidth: WindowMetrics.minimumWidth, minHeight: WindowMetrics.compactHeight)
        .tint(MaterialTheme.primary)
        .onAppear {
            model.refreshAccessibilityStatus()
        }
    }
}

private enum MaterialTheme {
    static let background = Color(red: 0.949, green: 0.945, blue: 0.929)
    static let surface = Color(red: 0.988, green: 0.984, blue: 0.969)
    static let surfaceVariant = Color(red: 0.918, green: 0.910, blue: 0.886)
    static let logSurface = Color(red: 0.965, green: 0.957, blue: 0.937)

    static let primary = Color(red: 0.286, green: 0.427, blue: 0.561)
    static let primaryContainer = Color(red: 0.812, green: 0.871, blue: 0.914)
    static let outline = Color(red: 0.745, green: 0.733, blue: 0.698)
    static let text = Color(red: 0.165, green: 0.169, blue: 0.173)
    static let secondaryText = Color(red: 0.405, green: 0.410, blue: 0.402)

    static let direction = Color(red: 0.302, green: 0.502, blue: 0.396)
    static let directionContainer = Color(red: 0.820, green: 0.890, blue: 0.847)
    static let attack = Color(red: 0.651, green: 0.365, blue: 0.424)
    static let attackContainer = Color(red: 0.918, green: 0.804, blue: 0.831)
    static let function = Color(red: 0.420, green: 0.435, blue: 0.459)
    static let functionContainer = Color(red: 0.855, green: 0.859, blue: 0.871)

    static let green = Color(red: 0.271, green: 0.475, blue: 0.353)
    static let greenContainer = Color(red: 0.812, green: 0.890, blue: 0.839)
    static let orange = Color(red: 0.635, green: 0.404, blue: 0.196)
    static let orangeContainer = Color(red: 0.933, green: 0.843, blue: 0.745)
    static let red = Color(red: 0.647, green: 0.318, blue: 0.337)
    static let redContainer = Color(red: 0.933, green: 0.812, blue: 0.812)
    static let neutralContainer = Color(red: 0.890, green: 0.882, blue: 0.859)
}

private struct MaterialSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(MaterialTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MaterialTheme.outline.opacity(0.72), lineWidth: 1)
            )
            .shadow(color: MaterialTheme.text.opacity(0.035), radius: 3, x: 0, y: 1)
    }
}

private struct TopAppBar: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        MaterialSurface {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("8BitDo Hitbox Bridge")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(MaterialTheme.text)
                    Text("Arcade Controller for Xbox")
                        .font(.callout)
                        .foregroundStyle(MaterialTheme.secondaryText)
                }

                Spacer(minLength: 20)

                DeviceStatusBadge(value: model.deviceStatusText, kind: deviceStatusKind)
                BridgeStatusIndicator(text: model.bridgeStatus.text, kind: model.bridgeStatus.kind)

                Toggle("Enabled", isOn: Binding(
                    get: { model.isRunning },
                    set: { model.setBridgeEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Enable bridge")

                if !model.accessibilityTrusted {
                    Button {
                        model.openAccessibilitySettings()
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MaterialTheme.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Accessibility permission is needed before the bridge can run.")
                }

                Button {
                    model.quitApplication()
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(QuitButtonStyle())
                .help("Quit 8BitDo Hitbox Bridge")
            }
        }
    }

    private var deviceStatusKind: StatusKind {
        model.devicePresent ? .running : .idle
    }
}

private struct DeviceStatusBadge: View {
    let value: String
    let kind: StatusKind

    var body: some View {
        Text(value)
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help("Device: \(value)")
    }

    private var foreground: Color {
        switch kind {
        case .running: return MaterialTheme.green
        case .pending: return MaterialTheme.orange
        case .error: return MaterialTheme.red
        case .idle: return MaterialTheme.secondaryText
        }
    }

    private var background: Color {
        switch kind {
        case .running: return MaterialTheme.greenContainer
        case .pending: return MaterialTheme.orangeContainer
        case .error: return MaterialTheme.redContainer
        case .idle: return MaterialTheme.neutralContainer
        }
    }
}

private struct KeyMappingPanel: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        MaterialSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Label("Key Mapping", systemImage: "keyboard")
                        .font(.headline)
                        .foregroundStyle(MaterialTheme.text)
                    Spacer()
                    Button {
                        model.resetDefaults()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(OutlinedMaterialButtonStyle())

                    Button {
                        model.applyMappings()
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(FilledMaterialButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }

                if !model.mappingFeedback.isEmpty {
                    MappingFeedbackView(text: model.mappingFeedback, isError: model.mappingFeedbackIsError)
                }

                HStack(alignment: .center, spacing: 20) {
                    DirectionCluster()
                        .frame(width: 230)

                    Divider()

                    VStack(spacing: 14) {
                        AttackGrid()
                        FunctionRow()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(16)
                .background(MaterialTheme.surfaceVariant.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .disabled(model.isRunning)
    }
}

private struct MappingFeedbackView: View {
    let text: String
    let isError: Bool

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(isError ? MaterialTheme.red : MaterialTheme.green)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isError ? MaterialTheme.redContainer : MaterialTheme.greenContainer)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct DirectionCluster: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        VStack(spacing: 10) {
            HitboxButton(mapping: mapping("UP"), size: .large, role: .direction)
            HStack(spacing: 10) {
                HitboxButton(mapping: mapping("LEFT"), size: .large, role: .direction)
                HitboxButton(mapping: mapping("DOWN"), size: .large, role: .direction)
                HitboxButton(mapping: mapping("RIGHT"), size: .large, role: .direction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func mapping(_ control: String) -> ControlMapping {
        model.mappings.first { $0.control == control } ?? ControlMapping(control: control, key: "-")
    }
}

private struct AttackGrid: View {
    @EnvironmentObject private var model: BridgeModel

    private let rows = [
        ["X", "Y", "RB", "LB"],
        ["A", "B", "RT", "LT"],
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { control in
                        HitboxButton(mapping: mapping(control), size: .medium, role: .attack)
                    }
                }
            }
        }
    }

    private func mapping(_ control: String) -> ControlMapping {
        model.mappings.first { $0.control == control } ?? ControlMapping(control: control, key: "-")
    }
}

private struct FunctionRow: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            HitboxButton(mapping: mapping("LSB"), size: .small, role: .function)
            HitboxButton(mapping: mapping("RSB"), size: .small, role: .function)
            Spacer(minLength: 0)
        }
    }

    private func mapping(_ control: String) -> ControlMapping {
        model.mappings.first { $0.control == control } ?? ControlMapping(control: control, key: "-")
    }
}

private struct HitboxButton: View {
    enum Size {
        case large
        case medium
        case small
    }

    enum Role {
        case direction
        case attack
        case function

        var foreground: Color {
            switch self {
            case .direction: return MaterialTheme.direction
            case .attack: return MaterialTheme.attack
            case .function: return MaterialTheme.function
            }
        }

        var container: Color {
            switch self {
            case .direction: return MaterialTheme.directionContainer
            case .attack: return MaterialTheme.attackContainer
            case .function: return MaterialTheme.functionContainer
            }
        }
    }

    @EnvironmentObject private var model: BridgeModel
    let mapping: ControlMapping
    let size: Size
    let role: Role

    private var isRecording: Bool {
        model.recordingControl == mapping.control
    }

    private var keyText: String {
        if isRecording {
            return "..."
        }
        return mapping.key.isEmpty ? "-" : mapping.key
    }

    private var dimension: CGFloat {
        switch size {
        case .large: return 68
        case .medium: return 62
        case .small: return 56
        }
    }

    private var labelFont: Font {
        size == .small ? .caption.weight(.semibold) : .callout.weight(.semibold)
    }

    private var keyFont: Font {
        size == .small
            ? .system(.body, design: .monospaced).weight(.bold)
            : .system(.title3, design: .monospaced).weight(.bold)
    }

    var body: some View {
        Button {
            model.beginRecording(control: mapping.control)
        } label: {
            VStack(spacing: 3) {
                Text(mapping.control)
                    .font(labelFont)
                    .foregroundStyle(isRecording ? MaterialTheme.primary : role.foreground)
                Text(keyText)
                    .font(keyFont)
                    .foregroundStyle(isRecording ? MaterialTheme.primary : MaterialTheme.text)
            }
            .frame(width: dimension, height: dimension)
        }
        .buttonStyle(HitboxButtonStyle(
            active: isRecording,
            dimension: dimension,
            roleColor: role.foreground,
            roleContainer: role.container
        ))
    }
}

private struct LogPanel: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        MaterialSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Bridge Log", systemImage: "terminal")
                        .font(.headline)
                        .foregroundStyle(MaterialTheme.text)
                    Spacer()
                    Toggle("Log", isOn: Binding(
                        get: { model.logsEnabled },
                        set: { model.setLogsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    Button {
                        model.openAccessibilitySettings()
                    } label: {
                        Label("Accessibility", systemImage: "switch.2")
                    }
                    .buttonStyle(OutlinedMaterialButtonStyle())
                }

                if model.logsEnabled {
                    ScrollView {
                        if model.logText.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(MaterialTheme.secondaryText)
                                Text("Bridge activity will appear here.")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(MaterialTheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 110)
                        } else {
                            Text(model.logText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(MaterialTheme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                    }
                    .frame(minHeight: 130)
                    .background(MaterialTheme.logSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(MaterialTheme.outline, lineWidth: 1)
                    )
                }
            }
        }
    }
}

private struct BridgeStatusIndicator: View {
    let text: String
    let kind: StatusKind

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .padding(9)
            .background(color.opacity(0.14))
            .clipShape(Circle())
            .shadow(color: color.opacity(kind == .idle ? 0 : 0.32), radius: 4)
            .help("Bridge: \(text)")
            .accessibilityLabel("Bridge status: \(text)")
    }

    private var color: Color {
        switch kind {
        case .running: return MaterialTheme.green
        case .pending: return MaterialTheme.orange
        case .error: return MaterialTheme.red
        case .idle: return MaterialTheme.secondaryText
        }
    }
}

private struct FilledMaterialButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : MaterialTheme.secondaryText)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(background(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func background(configuration: Configuration) -> Color {
        guard isEnabled else { return MaterialTheme.neutralContainer }
        return MaterialTheme.primary.opacity(configuration.isPressed ? 0.82 : 1.0)
    }
}

private struct OutlinedMaterialButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? MaterialTheme.primary : MaterialTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(MaterialTheme.surface.opacity(configuration.isPressed ? 0.55 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isEnabled ? MaterialTheme.outline : MaterialTheme.outline.opacity(0.55),
                            lineWidth: 1)
            )
    }
}

private struct HitboxButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let active: Bool
    let dimension: CGFloat
    let roleColor: Color
    let roleContainer: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: dimension, height: dimension)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(active ? MaterialTheme.primary : roleColor.opacity(0.52),
                            lineWidth: active ? 2 : 1)
            )
            .shadow(color: MaterialTheme.text.opacity(active ? 0.13 : 0.07),
                    radius: isEnabled ? (active ? 7 : 3) : 0,
                    x: 0,
                    y: active ? 3 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.42)
    }

    private func background(isPressed: Bool) -> Color {
        if active { return MaterialTheme.primaryContainer }
        return isPressed ? roleContainer.opacity(0.78) : roleContainer.opacity(0.48)
    }
}

private struct QuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MaterialTheme.red)
            .frame(width: 30, height: 30)
            .background(MaterialTheme.redContainer.opacity(configuration.isPressed ? 1.0 : 0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: BridgeModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "EightBitDoAppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.contentMinSize = NSSize(
                width: WindowMetrics.minimumWidth,
                height: WindowMetrics.compactHeight
            )
            window.setContentSize(NSSize(
                width: WindowMetrics.width,
                height: WindowMetrics.compactHeight
            ))
            window.center()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopForAppQuit()
    }
}

@main
struct HitboxBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.model = model
                    model.installKeyMonitor()
                    model.startDeviceMonitoring()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: WindowMetrics.width, height: WindowMetrics.compactHeight)
    }
}
