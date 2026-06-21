import AppKit
import ApplicationServices
import SwiftUI

struct ControlMapping: Identifiable, Equatable {
    let id = UUID()
    let control: String
    var key: String
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var mappings: [ControlMapping]
    @Published var logText = ""
    @Published var recordingControl: String?

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

    private let controlNames: Set<String> = [
        "UP", "DOWN", "LEFT", "RIGHT", "X", "Y", "RB", "A", "B", "RT", "LSB", "RSB", "LB", "LT"
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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var restartAfterTermination = false
    private var stdoutBuffer = ""
    private var activeControls: [String: CGKeyCode] = [:]
    private var keyDownCounts: [CGKeyCode: Int] = [:]
    private var keyMonitor: Any?

    init() {
        mappings = defaults.map { ControlMapping(control: $0.0, key: $0.1) }
        loadMappings()
    }

    var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("8BitDo Hitbox Bridge", isDirectory: true)
            .appendingPathComponent("keymap.conf")
    }

    func setBridgeEnabled(_ enabled: Bool) {
        enabled ? startBridge() : stopBridge()
    }

    func applyMappings() {
        do {
            try saveMappings()
            releasePressedKeys()
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
        restartAfterTermination = false
        stopBridge()
    }

    private func startBridge() {
        guard process == nil || process?.isRunning == false else { return }

        guard ensureAccessibilityPermission() else {
            isRunning = false
            statusText = "Accessibility needed"
            appendLog("Accessibility permission is required for the app before enabling the bridge.\n")
            return
        }

        do {
            try saveMappings()
        } catch {
            statusText = "Save failed"
            appendLog("Save failed: \(error.localizedDescription)\n")
            return
        }

        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "hitbox_bridge") else {
            statusText = "Helper missing"
            appendLog("Cannot find bundled hitbox_bridge helper.\n")
            return
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let child = Process()
        child.executableURL = helperURL
        child.arguments = ["--forever"]
        child.standardOutput = stdout
        child.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.handleStdout(text)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        child.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }

        do {
            appendLog("Starting bridge...\n")
            try child.run()
            process = child
            stdoutPipe = stdout
            stderrPipe = stderr
            stdoutBuffer = ""
            isRunning = true
            statusText = "Running"
        } catch {
            statusText = "Start failed"
            appendLog("Start failed: \(error.localizedDescription)\n")
            clearProcess()
        }
    }

    private func stopBridge() {
        releasePressedKeys()

        guard let process, process.isRunning else {
            isRunning = false
            statusText = "Stopped"
            clearProcess()
            return
        }

        statusText = restartAfterTermination ? "Restarting" : "Stopping"
        process.terminate()
    }

    private func handleTermination(status: Int32) {
        releasePressedKeys()
        clearProcess()
        isRunning = false

        if restartAfterTermination {
            restartAfterTermination = false
            appendLog("Bridge stopped. Restarting with new keymap...\n")
            startBridge()
            return
        }

        statusText = status == 0 ? "Stopped" : "Exited \(status)"
        appendLog("Bridge exited with status \(status).\n")
    }

    private func clearProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        stdoutBuffer = ""
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

    private func handleStdout(_ text: String) {
        appendLog(text)
        stdoutBuffer.append(text)

        while let newline = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newline.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(..<newline.upperBound)
            handleEventLine(line)
        }
    }

    private func handleEventLine(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count == 2 else { return }

        let control = String(parts[0]).uppercased()
        let state = String(parts[1]).lowercased()
        guard controlNames.contains(control), state == "down" || state == "up" else {
            return
        }

        if state == "down" {
            guard let keyCode = keyCodeForControl(control) else { return }
            press(control: control, keyCode: keyCode)
        } else {
            release(control: control)
        }
    }

    private func keyCodeForControl(_ control: String) -> CGKeyCode? {
        guard let label = mappingDictionary()[control], let keyCode = keyCodes[label] else {
            appendLog("No key code for \(control).\n")
            return nil
        }
        return keyCode
    }

    private func mappingDictionary() -> [String: String] {
        Dictionary(uniqueKeysWithValues: mappings.map { ($0.control, $0.key) })
    }

    private func press(control: String, keyCode: CGKeyCode) {
        if let oldKeyCode = activeControls[control] {
            if oldKeyCode == keyCode { return }
            releaseKey(oldKeyCode)
        }

        activeControls[control] = keyCode
        pressKey(keyCode)
    }

    private func release(control: String) {
        guard let keyCode = activeControls.removeValue(forKey: control) else { return }
        releaseKey(keyCode)
    }

    private func pressKey(_ keyCode: CGKeyCode) {
        let count = keyDownCounts[keyCode, default: 0]
        keyDownCounts[keyCode] = count + 1
        if count == 0 {
            postKey(keyCode, down: true)
        }
    }

    private func releaseKey(_ keyCode: CGKeyCode) {
        let nextCount = max(0, keyDownCounts[keyCode, default: 0] - 1)
        keyDownCounts[keyCode] = nextCount
        if nextCount == 0 {
            keyDownCounts.removeValue(forKey: keyCode)
            postKey(keyCode, down: false)
        }
    }

    private func releasePressedKeys() {
        for keyCode in keyDownCounts.keys {
            postKey(keyCode, down: false)
        }
        activeControls.removeAll()
        keyDownCounts.removeAll()
    }

    private func postKey(_ keyCode: CGKeyCode, down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            return
        }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.post(tap: .cghidEventTap)
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
                    .foregroundStyle(model.isRunning ? .green : .secondary)
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
                Button {
                    model.openAccessibilitySettings()
                } label: {
                    Label("Accessibility", systemImage: "switch.2")
                }
            }

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
