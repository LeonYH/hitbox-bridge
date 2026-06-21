import AppKit
import ApplicationServices
import SwiftUI

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
    var logHandler: ((String) -> Void)?

    init(engine: InputEngine) {
        self.engine = engine
    }
}

private func bridgeEventCallback(_ context: UnsafeMutableRawPointer?,
                                 _ control: UnsafePointer<CChar>?,
                                 _ down: Bool) {
    guard let context, let control else { return }
    let callbackContext = Unmanaged<BridgeCallbackContext>.fromOpaque(context).takeUnretainedValue()
    callbackContext.engine.handle(control: String(cString: control), down: down)
}

private func bridgeLogCallback(_ context: UnsafeMutableRawPointer?,
                               _ message: UnsafePointer<CChar>?) {
    guard let context, let message else { return }
    let callbackContext = Unmanaged<BridgeCallbackContext>.fromOpaque(context).takeUnretainedValue()
    callbackContext.logHandler?(String(cString: message))
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var isRunning = false
    @Published var bridgeRunning = false
    @Published var statusText = "Stopped"
    @Published var mappings: [ControlMapping]
    @Published var logText = ""
    @Published var recordingControl: String?
    @Published var logsEnabled = false

    private let defaults: [(String, String)] = [
        ("UP", "W"),
        ("DOWN", "S"),
        ("LEFT", "A"),
        ("RIGHT", "D"),
        ("X", "U"),
        ("Y", "I"),
        ("RB", "O"),
        ("A", "J"),
        ("B", "K"),
        ("RT", "L"),
        ("LSB", "Y"),
        ("RSB", "H"),
        ("LB", "P"),
        ("LT", ";"),
    ]

    private let keyCodes: [String: CGKeyCode] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5,
        "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
        "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35,
        "ENTER": 36, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47,
        "TAB": 48, "SPACE": 49, "`": 50, "ESC": 53,
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

    private let inputEngine = InputEngine()
    private lazy var callbackContext = BridgeCallbackContext(engine: inputEngine)
    private let bridgeQueue = DispatchQueue(label: "com.local.hitboxbridge.usb", qos: .userInteractive)
    private var bridge: OpaquePointer?
    private var keyMonitor: Any?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var bridgeStartTime: Date?

    init() {
        mappings = defaults.map { ControlMapping(control: $0.0, key: $0.1) }
        loadMappings()
        refreshControlKeyCodes()
    }

    var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("8BitDo Hitbox Bridge", isDirectory: true)
            .appendingPathComponent("keymap.conf")
    }

    func setBridgeEnabled(_ enabled: Bool) {
        if enabled {
            isRunning = true
            reconnectAttempt = 0
            cancelReconnect()
            startBridge()
        } else {
            isRunning = false
            cancelReconnect()
            stopBridge()
        }
    }

    func applyMappings() {
        do {
            refreshControlKeyCodes()
            try saveMappings()
            inputEngine.releasePressedKeys()
            appendLog("Saved keymap: \(configURL.path)\n")
        } catch {
            statusText = "Save failed"
            appendLog("Save failed: \(error.localizedDescription)\n")
        }
    }

    func resetDefaults() {
        mappings = defaults.map { ControlMapping(control: $0.0, key: $0.1) }
        applyMappings()
    }

    func setLogsEnabled(_ enabled: Bool) {
        logsEnabled = enabled
        if enabled {
            appendLog("Log enabled.\n")
        } else {
            logText = ""
        }
    }

    func beginRecording(control: String) {
        recordingControl = control
        appendLog("Recording \(control). Press a letter, number, punctuation key, or Space.\n")
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func stopForAppQuit() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRunning = false
        cancelReconnect()
        stopBridge()
    }

    private func startBridge() {
        guard isRunning else { return }
        guard bridge == nil else { return }

        guard ensureAccessibilityPermission() else {
            isRunning = false
            bridgeRunning = false
            statusText = "Accessibility needed"
            appendLog("Accessibility permission is required for the app before enabling the bridge.\n")
            return
        }

        do {
            try saveMappings()
        } catch {
            isRunning = false
            bridgeRunning = false
            statusText = "Save failed"
            appendLog("Save failed: \(error.localizedDescription)\n")
            return
        }

        callbackContext.logHandler = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }

        guard let nextBridge = hitbox_bridge_create(bridgeEventCallback,
                                                    bridgeLogCallback,
                                                    Unmanaged.passUnretained(callbackContext).toOpaque()) else {
            isRunning = false
            bridgeRunning = false
            statusText = "Bridge unavailable"
            appendLog("Cannot create embedded USB bridge.\n")
            return
        }

        appendLog("Starting embedded bridge...\n")
        bridge = nextBridge
        bridgeRunning = true
        bridgeStartTime = Date()
        statusText = "Running"

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
            statusText = "Stopped"
            return
        }

        statusText = "Stopping"
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

        statusText = "Stopped"
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

    private func scheduleReconnect() {
        guard isRunning else { return }

        cancelReconnect()
        let delay = min(5.0, 0.5 * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        statusText = "Reconnecting in \(String(format: "%.1f", delay))s"

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
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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
        applyMappings()
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
}

struct ContentView: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Label("8BitDo Hitbox Bridge", systemImage: "cable.connector")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(model.statusText)
                    .foregroundStyle(model.bridgeRunning ? Color.green : (model.isRunning ? Color.orange : Color.secondary))
                Toggle("Enabled", isOn: Binding(
                    get: { model.isRunning },
                    set: { model.setBridgeEnabled($0) }
                ))
                .toggleStyle(.switch)
            }

            Divider()

            HStack {
                Label("Key Mapping", systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Button {
                    model.resetDefaults()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                Button {
                    model.applyMappings()
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
            }

            LazyVGrid(columns: [
                GridItem(.fixed(88), alignment: .leading),
                GridItem(.flexible(minimum: 120), alignment: .leading),
                GridItem(.fixed(88), alignment: .leading),
                GridItem(.flexible(minimum: 120), alignment: .leading),
            ], alignment: .leading, spacing: 10) {
                ForEach(model.mappings) { mapping in
                    Text(mapping.control)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    Button {
                        model.beginRecording(control: mapping.control)
                    } label: {
                        HStack {
                            Text(model.recordingControl == mapping.control ? "Press key" : mapping.key)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                            Spacer()
                            Image(systemName: model.recordingControl == mapping.control ? "keyboard.badge.ellipsis" : "keyboard")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            HStack {
                Label("Bridge Log", systemImage: "terminal")
                    .font(.headline)
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
            }

            if model.logsEnabled {
                ScrollView {
                    Text(model.logText.isEmpty ? "No log output yet." : model.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(minHeight: 140)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: BridgeModel?

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
                }
        }
        .windowStyle(.titleBar)
    }
}
