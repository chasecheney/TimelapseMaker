import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            settingsPane
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 400)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .alert("Render failed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Preview

    private var previewPane: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let img = model.previewImage, model.sourceSize.width > 0 {
                    CropEditorView(image: img, sourceSize: model.sourceSize,
                                   lockedAspect: model.cropAspectPreset.ratio, crop: $model.crop)
                        .padding(16)
                } else {
                    emptyState
                }
            }
            Divider()
            scrubber
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(model.isScanning ? "Scanning…" : "Drop a folder of images here")
                .font(.title3)
            Button("Choose Folder…") { model.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Text("Drag a crop rectangle on the preview to trim the frame.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Text("Preview frame")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(model.previewIndex) },
                    set: { model.previewIndex = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, model.totalFrames - 1)),
                step: 1
            )
            .disabled(model.totalFrames < 2)
            .onChange(of: model.previewIndex) { _, _ in model.loadPreview() }
            Text(model.totalFrames > 0
                 ? "#\(model.previewIndex + 1) / \(model.totalFrames)"
                 : "–")
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Settings

    private var settingsPane: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                timingSection
                cropSection
                scaleSection
                stabilizeSection
                labelSection
                encodingSection
            }
            .formStyle(.grouped)
            .disabled(model.isRendering)

            Divider()
            renderBar
        }
    }

    private var sourceSection: some View {
        Section("Source") {
            HStack {
                Text(model.sourceFolder?.lastPathComponent ?? "No folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.sourceFolder?.path ?? "")
                Spacer()
                Button("Choose…") { model.chooseFolder() }
            }
            LabeledContent("Images") {
                Text(model.totalFrames > 0
                     ? "\(model.totalFrames)  ·  \(Int(model.sourceSize.width))×\(Int(model.sourceSize.height))"
                     : "—")
            }
            HStack {
                Text("Range")
                Spacer()
                TextField("Start", value: $model.startFrame, format: .number)
                    .frame(width: 70)
                Text("to")
                TextField("End", value: $model.endFrame, format: .number)
                    .frame(width: 70)
            }
            .disabled(model.totalFrames == 0)
            LabeledContent("Using") {
                Text("\(model.selectedCount) frames")
            }
        }
    }

    private var timingSection: some View {
        Section("Frame rate") {
            HStack {
                Slider(value: $model.fps, in: 1...60, step: 1)
                TextField("", value: $model.fps, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 56)
                Text("fps")
            }
            LabeledContent("Video length") {
                Text(model.estimatedDurationText)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var cropSection: some View {
        Section {
            let c = model.effectiveCrop
            HStack {
                numberField("X", value: Int(c.minX)) { model.setCrop(x: $0, y: Int(c.minY), width: Int(c.width), height: Int(c.height)) }
                numberField("Y", value: Int(c.minY)) { model.setCrop(x: Int(c.minX), y: $0, width: Int(c.width), height: Int(c.height)) }
            }
            HStack {
                numberField("W", value: Int(c.width)) { model.setCrop(x: Int(c.minX), y: Int(c.minY), width: $0, height: Int(c.height)) }
                numberField("H", value: Int(c.height)) { model.setCrop(x: Int(c.minX), y: Int(c.minY), width: Int(c.width), height: $0) }
            }
            HStack {
                Picker("Aspect", selection: $model.cropAspectPreset) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                Spacer()
                Button("Reset") {
                    model.cropAspectPreset = .free
                    model.resetCrop()
                }
                .disabled(model.crop == nil && model.cropAspectPreset == .free)
            }
        } header: {
            Text("Crop")
        } footer: {
            Text("Drag on the preview to draw a crop; drag inside it to move, corners to resize. Hold ⇧ while dragging to keep the aspect ratio.")
        }
        .disabled(model.totalFrames == 0)
    }

    private var scaleSection: some View {
        Section {
            HStack {
                TextField("Width", value: Binding(
                    get: { model.outputWidth },
                    set: { model.widthChanged($0) }
                ), format: .number)
                .frame(width: 70)
                Text("×")
                TextField("Height", value: Binding(
                    get: { model.outputHeight },
                    set: { model.heightChanged($0) }
                ), format: .number)
                .frame(width: 70)
                Text("px")
                Spacer()
                Toggle("Lock", isOn: $model.lockAspect)
                    .toggleStyle(.checkbox)
                    .help("Keep the crop's aspect ratio when editing width or height")
            }
            HStack {
                Text("Scale")
                Spacer()
                ForEach([100, 75, 50, 25], id: \.self) { pct in
                    Button("\(pct)%") { model.setOutputScale(Double(pct) / 100) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.currentScalePercent == pct ? .accentColor : nil)
                }
            }
        } header: {
            Text("Output size")
        } footer: {
            Text("Defaults to the crop size. Values are rounded to even numbers for the encoder.")
        }
        .disabled(model.totalFrames == 0)
    }

    private var stabilizeSection: some View {
        Section {
            Toggle("Lock frames to anchor", isOn: $model.stabilizeEnabled)
            if model.stabilizeEnabled {
                HStack {
                    Text("Anchor")
                    Spacer()
                    Text("frame #\(model.effectiveAnchorFrame + 1)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Use preview frame") { model.useCurrentPreviewAsAnchor() }
                        .controlSize(.small)
                        .disabled(model.previewIndex == model.effectiveAnchorFrame)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Scene-change sensitivity")
                        Spacer()
                        Text("\(Int((0.50 + 0.45 * model.stabilizeSensitivity) * 100))% match")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    Slider(value: $model.stabilizeSensitivity, in: 0...1)
                }
                Toggle("Drift back to center near the edge", isOn: $model.stabilizeRecenter)
                    .help("When the correction has used more than half the margin on one side, slowly pan the locked view back toward the crop's original position.")
                if let summary = model.stabilizeSummary {
                    LabeledContent("Last render") { Text(summary) }
                }
            }
        } header: {
            Text("Stabilize")
        } footer: {
            Text(model.stabilizeEnabled
                 ? "Each frame is shifted so the area inside your crop lines up with the anchor (only the crop is analyzed, so a static sidebar or toolbar outside it is ignored). Frames that match less than the threshold count as a scene change and become the new anchor. The correction is limited to the margin around your crop, so the picture never leaves the frame — more margin allows more correction."
                 : "Compensates for a bumped camera or a moved window by aligning every frame to one anchor frame.")
        }
        .disabled(model.totalFrames == 0)
    }

    private var labelSection: some View {
        Section("Label overlay") {
            Picker("Show", selection: $model.labelMode) {
                ForEach(LabelMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.labelMode == .timestamp {
                Picker("Time zone", selection: $model.labelTimeZone) {
                    ForEach(LabelTimeZone.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if model.labelMode != .none {
                HStack {
                    Text("Font size")
                    Slider(value: $model.labelFontSize, in: 12...72, step: 1)
                    Text("\(Int(model.labelFontSize))")
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    private var encodingSection: some View {
        Section {
            Picker("Codec", selection: $model.codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Text("Quality")
                Slider(value: $model.quality, in: 0.1...1.0)
                Text(qualityLabel)
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Encoding")
        } footer: {
            Text("Uses Apple's hardware encoder. HEVC gives smaller files at the same quality; H.264 plays everywhere.")
        }
    }

    private var qualityLabel: String {
        let s = RenderSettings(
            frames: [], fps: model.fps, crop: nil,
            outputWidth: model.outputWidth, outputHeight: model.outputHeight,
            codec: model.codec, quality: model.quality, label: LabelSettings(),
            outputURL: URL(fileURLWithPath: "/")
        )
        let mbps = Double(s.bitrate) / 1_000_000
        return String(format: "%.1f Mb/s", mbps)
    }

    // MARK: - Render bar

    private var renderBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRendering {
                ProgressView(value: model.progress)
            }
            HStack {
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if model.lastOutput != nil && !model.isRendering {
                    Button("Show in Finder") { model.revealLastOutput() }
                }
                if model.isRendering {
                    Button("Cancel") { model.cancelRender() }
                } else {
                    Button("Make Video…") { model.chooseOutputAndRender() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRender)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func numberField(_ label: String, value: Int, onCommit: @escaping (Int) -> Void) -> some View {
        NumberField(label: label, value: value, onCommit: onCommit)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            guard let dropped = url else { return }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dropped.path, isDirectory: &isDir)
            let folder = isDir.boolValue ? dropped : dropped.deletingLastPathComponent()
            Task { @MainActor in model.loadFolder(folder) }
        }
        return true
    }
}

/// A small integer text field that only commits when editing ends,
/// so partially typed values don't fight with the crop editor.
private struct NumberField: View {
    let label: String
    let value: Int
    let onCommit: (Int) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 16)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: value) { _, v in if !focused { text = String(v) } }
                .onAppear { text = String(value) }
        }
    }

    private func commit() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)), v != value {
            onCommit(v)
        } else {
            text = String(value)
        }
    }
}
