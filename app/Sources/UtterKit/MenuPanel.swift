import AppKit
import SwiftUI
import UtterCore

/// A snapshot of the controller for the menu bar panel. The controller isn't
/// observable, so the status item refreshes this on open and on every state change.
@MainActor @Observable
final class MenuPanelModel {
    let controller: DictationController
    var state: DictationController.State = .starting
    var message: String?
    var secureInputNotice: String?
    var lastText: String?
    var modelLoaded = false
    var shortcut = ""
    var mode = DictationMode.pushToTalk
    var textMode = TextPipelineSettings.Mode.clean
    var microphoneUID = ""
    var needsSetup = false
    var copied = false

    /// Actions that belong to the status item (windows, quitting).
    var open: (SettingsSection) -> Void = { _ in }
    var openPermissions: () -> Void = {}
    var close: () -> Void = {}

    init(controller: DictationController) {
        self.controller = controller
        refresh()
    }

    func refresh() {
        state = controller.state
        message = controller.lastMessage.flatMap { controller.state == .failed($0) ? nil : $0 }
        secureInputNotice = controller.secureInputNotice
        lastText = controller.lastPipeline?.final.nilIfEmpty
        modelLoaded = controller.modelLoaded
        shortcut = controller.hotkey.shortcut.displayString
        mode = controller.mode
        textMode = controller.textSettings.mode
        microphoneUID = controller.preferredMicrophoneUID ?? ""
        needsSetup = !PermissionSnapshot.current().allGranted || !controller.hotkey.isRunning
    }

    var isRecording: Bool { state == .recording }

    var statusTitle: String {
        switch state {
        case .starting: "Starting…"
        case .loadingModel: "Loading model…"
        case .ready: "Ready"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .failed: "Needs attention"
        }
    }

    var statusColor: Color {
        switch state {
        case .ready: .green
        case .recording: .red
        case .transcribing, .loadingModel, .starting: .orange
        case .failed: .yellow
        }
    }

    var hint: String {
        if case .failed(let message) = state { return message }
        return "\(mode == .toggle ? "Press" : "Hold") \(shortcut) anywhere to dictate."
    }

    func toggleDictation() {
        close()
        controller.toggleFromMenu()
        refresh()
    }

    func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
        copied = true
    }

    func setTextMode(_ mode: TextPipelineSettings.Mode) {
        controller.textSettings.mode = mode
        textMode = mode
    }

    func setMicrophone(_ uid: String) {
        controller.selectMicrophone(uid: uid.isEmpty ? nil : uid)
        microphoneUID = uid
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct MenuPanelView: View {
    @Bindable var model: MenuPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                dictateButton
                notices
                if let text = model.lastText { lastDictation(text) }
            }
            .padding(14)
            Divider()
            pickers.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            footer.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Utter").font(.system(size: 14, weight: .semibold))
                Text(model.hint).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle().fill(model.statusColor).frame(width: 7, height: 7)
                Text(model.statusTitle).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(model.statusColor.opacity(0.14), in: Capsule())
        }
    }

    private var dictateButton: some View {
        Button { model.toggleDictation() } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                Text(model.isRecording ? "Stop Dictation" : "Start Dictation").fontWeight(.semibold)
                Spacer()
                if !model.isRecording {
                    Text(model.shortcut).font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(.white)
            .background((model.isRecording ? Color.red : Color.accentColor).gradient,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!(model.modelLoaded || model.isRecording))
        .opacity(model.modelLoaded || model.isRecording ? 1 : 0.5)
    }

    @ViewBuilder private var notices: some View {
        if let notice = model.secureInputNotice { Notice(symbol: "lock.fill", text: notice, tint: .orange) }
        if let message = model.message { Notice(symbol: "info.circle.fill", text: message, tint: .blue) }
        if model.needsSetup {
            HStack {
                Notice(symbol: "exclamationmark.triangle.fill", text: "Utter needs a permission to work.", tint: .yellow)
                Spacer()
                Button("Set Up…") { model.close(); model.openPermissions() }.controlSize(.small)
            }
        }
    }

    private func lastDictation(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last dictation").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(model.copied ? "Copied" : "Copy") { model.copyLast() }
                    .buttonStyle(.link).font(.caption)
            }
            Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                label("Model", "cpu")
                Picker("Model", selection: Binding(get: { model.controller.models.defaultModelID },
                                                   set: { model.controller.models.setDefault($0) })) {
                    ForEach(model.controller.models.installedEntries, id: \.id) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                label("Mode", "text.bubble")
                Picker("Mode", selection: Binding(get: { model.textMode }, set: { model.setTextMode($0) })) {
                    ForEach(TextPipelineSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                label("Microphone", "mic")
                Picker("Microphone", selection: Binding(get: { model.microphoneUID }, set: { model.setMicrophone($0) })) {
                    Text("System Default").tag("")
                    ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            .frame(width: 104, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "History", symbol: "clock") { model.close(); model.open(.history) }
            FooterButton(title: "Models", symbol: "cpu") { model.close(); model.open(.models) }
            FooterButton(title: "Settings", symbol: "gearshape") { model.close(); model.open(.general) }
            Spacer()
            FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
        }
    }
}

private struct Notice: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        Label { Text(text).font(.caption).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.caption2)
            }
            .frame(width: 58, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
    }
}
