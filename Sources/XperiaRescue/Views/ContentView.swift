import SwiftUI
import XperiaRescueCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VSplitView {
                VStack(spacing: 0) {
                    if let job = model.activeJob {
                        JobBanner(job: job)
                    }
                    if let outcome = model.lastOutcome {
                        OutcomeBanner(outcome: outcome)
                    }
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 320)
                LogConsoleView(log: model.log)
                    .frame(minHeight: 120, idealHeight: 200)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModeBadge(mode: model.usbMode)
                    .help("Live USB status of the phone")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingPrompt != nil },
            set: { if !$0 { model.pendingPrompt = nil } }
        )) {
            if let prompt = model.pendingPrompt {
                PromptSheet(prompt: prompt).environmentObject(model)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .start {
        case .start: StartView()
        case .device: DeviceView()
        case .firmware: FirmwareView()
        case .flash: FlashView()
        case .fastboot: FastbootView()
        case .adb: ADBView()
        case .setup: SetupView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Recover") {
                row(.start)
                row(.device)
                row(.firmware)
                row(.flash)
            }
            Section("Tools") {
                row(.fastboot)
                row(.adb)
                row(.setup)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ModeBadge(mode: model.usbMode)
                if let model = model.deviceModel {
                    Text("Model \(model)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage).tag(item)
    }
}

struct JobBanner: View {
    @EnvironmentObject private var model: AppModel
    let job: JobInfo
    @State private var confirmStop = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.headline)
                if job.isFlash {
                    Text("Do not unplug the phone or let the Mac sleep until this finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                if job.isFlash { confirmStop = true } else { model.stopActiveJob() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(job.isFlash ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.1))
        .confirmationDialog("Stop flashing?", isPresented: $confirmStop) {
            Button("Stop Flashing", role: .destructive) { model.stopActiveJob() }
            Button("Keep Flashing", role: .cancel) {}
        } message: {
            Text("Stopping in the middle can leave the phone unable to boot until you flash it again.")
        }
    }
}

struct OutcomeBanner: View {
    @EnvironmentObject private var model: AppModel
    let outcome: JobOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch outcome {
            case .success(let title, let detail):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }
            case .failure(let title, let detail, let hints):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(hints, id: \.self) { hint in
                        Label(hint, systemImage: "lightbulb").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            Button {
                model.lastOutcome = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(14)
        .background(background)
    }

    private var background: Color {
        switch outcome {
        case .success: return Color.green.opacity(0.12)
        case .failure: return Color.red.opacity(0.12)
        }
    }
}

struct PromptSheet: View {
    @EnvironmentObject private var model: AppModel
    let prompt: NewflasherPrompt
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("newflasher is asking a question", systemImage: "questionmark.bubble")
                .font(.headline)
            Text(prompt.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("This app did not recognise the question, so please answer it yourself. Check the log below for context.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Answer", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit { send(answer) }
                Spacer()
                Button("n") { send("n") }
                Button("y") { send("y") }
                Button("Send") { send(answer) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(answer.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func send(_ text: String) {
        guard !text.isEmpty else { return }
        model.answerPendingPrompt(text)
    }
}
