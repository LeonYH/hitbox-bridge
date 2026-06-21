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
    var eventLogHandler: ((String) -> Void)?

    init(engine: InputEngine) {
        self.engine = engine
    }
}

private func bridgeEventCallback(_ context: UnsafeMutableRawPointer?,
                                 _ control: UnsafePointer<CChar>?,
                                 _ down: Bool) {
    guard let context, let control else { return }
    let callbackContext = Unmanaged<BridgeCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let controlName = String(cString: control)
    callbackContext.engine.handle(control: controlName, down: down)
    callbackContext.eventLogHandler?("\(controlName) \(down ? "down" : "up")\n")
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
        if bridgeRunning { return "Connected" }
        return isRunning ? "Searching" : "Idle"
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
            cancelAccessibilityPolling()
            stopBridge()
        }
    }

    @discardableResult
    func applyMappings() -> Bool {
        do {
            refreshControlKeyCodes()
            try saveMappings()
            inputEngine.releasePressedKeys()
            appendLog("Saved keymap: \(configURL.path)\n")
            showMappingFeedback("Saved")
            return true
        } catch {
            statusText = "Save failed"
            showMappingFeedback("Save failed", isError: true, autoClear: false)
            appendLog("Save failed: \(error.localizedDescription)\n")
            return false
        }
    }

    func resetDefaults() {
        mappings = defaults.map { ControlMapping(control: $0.0, key: $0.1) }
        if applyMappings() {
            showMappingFeedback("Defaults restored")
        }
    }

    func setLogsEnabled(_ enabled: Bool) {
        logsEnabled = enabled
        refreshEventLogHandler()
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
        refreshAccessibilityStatus()
        if isRunning && !accessibilityTrusted {
            statusText = "Accessibility needed"
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
        stopBridge()
    }

    private func startBridge() {
        guard isRunning else { return }
        guard bridge == nil else { return }

        guard ensureAccessibilityPermission() else {
            bridgeRunning = false
            statusText = "Accessibility needed"
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
            statusText = "Save failed"
            appendLog("Save failed: \(error.localizedDescription)\n")
            return
        }

        callbackContext.logHandler = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        refreshEventLogHandler()

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
            statusText = "Accessibility needed"
            scheduleAccessibilityPolling()
            return
        }

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
            callbackContext.eventLogHandler = { [weak self] message in
                Task { @MainActor in
                    self?.appendLog(message)
                }
            }
        } else {
            callbackContext.eventLogHandler = nil
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
}

struct ContentView: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        ZStack {
            MaterialTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TopAppBar()
                    StatusPanel()
                    KeyMappingPanel()
                    LogPanel()
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            model.refreshAccessibilityStatus()
        }
    }
}

private enum MaterialTheme {
    static let background = Color(red: 0.965, green: 0.976, blue: 0.992)
    static let surface = Color.white
    static let surfaceVariant = Color(red: 0.925, green: 0.944, blue: 0.972)
    static let primary = Color(red: 0.075, green: 0.305, blue: 0.760)
    static let primaryContainer = Color(red: 0.855, green: 0.902, blue: 1.0)
    static let outline = Color(red: 0.760, green: 0.790, blue: 0.835)
    static let text = Color(red: 0.075, green: 0.090, blue: 0.125)
    static let secondaryText = Color(red: 0.325, green: 0.365, blue: 0.430)
    static let green = Color(red: 0.055, green: 0.500, blue: 0.250)
    static let greenContainer = Color(red: 0.820, green: 0.945, blue: 0.870)
    static let orange = Color(red: 0.705, green: 0.365, blue: 0.030)
    static let orangeContainer = Color(red: 1.0, green: 0.900, blue: 0.760)
    static let red = Color(red: 0.700, green: 0.075, blue: 0.085)
    static let redContainer = Color(red: 1.0, green: 0.860, blue: 0.850)
    static let neutralContainer = Color(red: 0.900, green: 0.920, blue: 0.950)
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
                    .stroke(MaterialTheme.outline.opacity(0.8), lineWidth: 1)
            )
    }
}

private struct TopAppBar: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        MaterialSurface {
            HStack(spacing: 16) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(MaterialTheme.primary)
                    .frame(width: 44, height: 44)
                    .background(MaterialTheme.primaryContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text("8BitDo Hitbox Bridge")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(MaterialTheme.text)
                    Text("Arcade Controller for Xbox")
                        .font(.callout)
                        .foregroundStyle(MaterialTheme.secondaryText)
                }

                Spacer(minLength: 20)

                StatusBadge(text: model.statusText, kind: statusKind)

                Toggle("Enabled", isOn: Binding(
                    get: { model.isRunning },
                    set: { model.setBridgeEnabled($0) }
                ))
                .toggleStyle(.switch)

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
            }
        }
    }

    private var statusKind: StatusBadge.Kind {
        if model.bridgeRunning { return .running }
        if model.statusText.localizedCaseInsensitiveContains("accessibility") { return .error }
        return model.isRunning ? .pending : .idle
    }
}

private struct StatusPanel: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        HStack(spacing: 12) {
            StatusMetric(title: "Device", value: model.deviceStatusText, systemImage: "gamecontroller")
        }
    }
}

private struct StatusMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        MaterialSurface {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(MaterialTheme.primary)
                    .frame(width: 32, height: 32)
                    .background(MaterialTheme.primaryContainer.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MaterialTheme.secondaryText)
                    Text(value)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MaterialTheme.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
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
                .background(MaterialTheme.surfaceVariant.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
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
            HitboxButton(mapping: mapping("UP"), size: .large)
            HStack(spacing: 10) {
                HitboxButton(mapping: mapping("LEFT"), size: .large)
                HitboxButton(mapping: mapping("DOWN"), size: .large)
                HitboxButton(mapping: mapping("RIGHT"), size: .large)
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
                        HitboxButton(mapping: mapping(control), size: .medium)
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
            HitboxButton(mapping: mapping("LSB"), size: .small)
            HitboxButton(mapping: mapping("RSB"), size: .small)
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

    @EnvironmentObject private var model: BridgeModel
    let mapping: ControlMapping
    let size: Size

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
                    .foregroundStyle(isRecording ? MaterialTheme.primary : MaterialTheme.secondaryText)
                Text(keyText)
                    .font(keyFont)
                    .foregroundStyle(isRecording ? MaterialTheme.primary : MaterialTheme.text)
            }
            .frame(width: dimension, height: dimension)
        }
        .buttonStyle(HitboxButtonStyle(active: isRecording, dimension: dimension))
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
                    .background(Color(red: 0.982, green: 0.986, blue: 0.994))
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

private struct StatusBadge: View {
    enum Kind {
        case running
        case pending
        case error
        case idle
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

private struct FilledMaterialButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(MaterialTheme.primary.opacity(configuration.isPressed ? 0.82 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct OutlinedMaterialButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(MaterialTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(MaterialTheme.surface.opacity(configuration.isPressed ? 0.55 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MaterialTheme.outline, lineWidth: 1)
            )
    }
}

private struct HitboxButtonStyle: ButtonStyle {
    let active: Bool
    let dimension: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: dimension, height: dimension)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(active ? MaterialTheme.primary : MaterialTheme.outline.opacity(0.85), lineWidth: active ? 2 : 1)
            )
            .shadow(color: Color.black.opacity(active ? 0.14 : 0.08),
                    radius: active ? 8 : 4,
                    x: 0,
                    y: active ? 4 : 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }

    private func background(isPressed: Bool) -> Color {
        if active { return MaterialTheme.primaryContainer }
        return isPressed ? MaterialTheme.neutralContainer : MaterialTheme.surface
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
