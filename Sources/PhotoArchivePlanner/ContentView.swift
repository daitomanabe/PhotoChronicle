import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = PlannerViewModel()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                sourcesPanel
                    .frame(minWidth: 360, maxWidth: 480)
                planPanel
            }
            .frame(minHeight: 420)

            progressPanel
        }
        .padding(12)
        .onAppear { vm.bootstrap() }
    }

    private var sourcesPanel: some View {
        GroupBox("Sources") {
            VStack(alignment: .leading, spacing: 10) {
                DropZoneView(
                    title: "Drag & Drop Libraries (.photoslibrary/.photolibrary) or Folders here",
                    subtitle:
                        "Folders are scanned recursively. Libraries scan Originals/Masters only.",
                    acceptHint: "Drop here",
                    onDropURLs: { vm.addSources(from: $0) }
                )
                HStack {
                    Button("Add…") { vm.openAddSourcesPanel() }
                    Spacer()
                    Button("Clear") { vm.clearSources() }
                        .disabled(vm.sources.isEmpty || vm.isRunning)
                }

                List {
                    Section("Libraries") {
                        ForEach(vm.sources.filter { $0.kind == .library }) { s in
                            SourceRowView(source: s, onRemove: { vm.removeSource(s) })
                        }
                    }
                    Section("Folders") {
                        ForEach(vm.sources.filter { $0.kind == .folder }) { s in
                            SourceRowView(source: s, onRemove: { vm.removeSource(s) })
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            .padding(8)
        }
    }

    private var planPanel: some View {
        GroupBox("Plan / Destination") {
            VStack(alignment: .leading, spacing: 10) {
                DropZoneView(
                    title: "Destination Folder (DEST_ROOT)",
                    subtitle:
                        "Archive will be created under DEST_ROOT/YYYY/MM/DD/<sha256>/<filename>",
                    acceptHint: vm.destFolder != nil
                        ? "Change destination…" : "Drop destination folder here",
                    onDropURLs: { vm.setDestinationFromDrop($0) }
                )

                HStack {
                    Button("Choose DEST…") { vm.openChooseDestPanel() }
                    Spacer()
                    if let dest = vm.destFolder {
                        Text(dest.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("No destination selected").font(.caption).foregroundStyle(.secondary)
                    }
                }

                GroupBox(label: Label("Plan Database", systemImage: "server.rack")) {
                    VStack(alignment: .leading) {
                        Picker("Mode", selection: $vm.planMode) {
                            ForEach(PlanMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 4)

                        HStack {
                            Text(vm.planDBURL?.path ?? "Not Selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            // Context-aware button
                            Button(vm.planMode == .new ? "Create / Save..." : "Select Existing...")
                            {
                                vm.openChooseDBPanel(merging: false)
                            }
                        }

                        if vm.planMode == .append {
                            Button(
                                vm.planDBURL == nil
                                    ? "Load .sqlite for Phase 2" : "Append .sqlite for Phase 2"
                            ) {
                                if vm.planDBURL == nil {
                                    // Load
                                    vm.planMode = .append
                                    vm.openChooseDBPanel(merging: false)
                                } else {
                                    // Merge
                                    vm.planMode = .append
                                    vm.openChooseDBPanel(merging: true)
                                }
                            }
                            .padding(.top, 4)
                        }

                        Button("Reveal in Finder") {
                            vm.revealPlanDBInFinder()
                        }
                        .disabled(vm.planDBURL == nil)
                    }
                    .padding(8)
                }
                .disabled(vm.isRunning)

                Divider()

                HStack {
                    Button(vm.isRunning ? "Running Phase 1…" : "Start Phase 1 (Build Plan)") {
                        vm.startPhase1()
                    }
                    .disabled(!vm.canStart || vm.isRunningPhase2)

                    Button("Cancel") { vm.cancel() }
                        .disabled(!vm.isRunning)

                    Spacer()
                }

                Divider()

                HStack {
                    if let p2 = vm.phase2, p2.isRunning {
                        VStack(alignment: .leading) {
                            Text("Phase 2 Execution").font(.headline)
                            ProgressView(
                                value: Double(p2.progress.opsDone),
                                total: Double(max(1, p2.progress.opsTotal)))
                            Text("\(p2.progress.opsDone) / \(p2.progress.opsTotal) Ops")
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: p2.progress.bytesCopied, countStyle: .file))
                            Text(p2.progress.currentOp).font(.caption).lineLimit(1).truncationMode(
                                .middle)
                            Button("Cancel Phase 2") { vm.cancelPhase2() }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Start Phase 2 (Execute)") {
                                vm.startPhase2()
                            }
                            .disabled(vm.planDBURL == nil || vm.isRunning)

                            if vm.planDBURL != nil && !vm.isRunning {
                                Divider()
                                Button("Reset Phase 2 Ops (Retry All)") {
                                    vm.resetPhase2Ops()
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if let err = vm.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }

                Spacer()
            }
            .padding(8)
        }
    }

    private var progressPanel: some View {
        GroupBox("Progress / Log") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Stage: \(vm.progress.stage.rawValue)").font(.headline)
                    Spacer()
                    Text("Errors: \(vm.progress.errorCount)").font(.caption)
                }
                if !vm.progress.currentPath.isEmpty {
                    Text(vm.progress.currentPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 16) {
                    Text("Discovered: \(vm.progress.discoveredFiles)")
                    Text("Hashed: \(vm.progress.hashedFiles)")
                    Text("Unique: \(vm.progress.uniqueBlobs)")
                    Text("Duplicates: \(vm.progress.duplicateCount)")
                    Text(
                        "Read: \(ByteCountFormatter.string(fromByteCount: vm.progress.totalBytesRead, countStyle: .file))"
                    )
                }
                .font(.caption)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.logs.indices, id: \.self) { i in
                            Text(vm.logs[i]).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 140)
            }
            .padding(8)
        }
    }
}

private struct SourceRowView: View {
    let source: SourceItem
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text(source.displayName).lineLimit(1)
            Spacer()
            Text(source.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle)
            Button("Remove", action: onRemove)
                .buttonStyle(.borderless)
        }
    }
}

private struct DropZoneView: View {
    let title: String
    let subtitle: String
    let acceptHint: String
    let onDropURLs: ([URL]) -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : .secondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .frame(height: 54)
                .overlay(
                    Text(acceptHint).font(.caption).foregroundStyle(.secondary)
                )
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                    DropUtil.loadFileURLs(from: providers) { urls in
                        onDropURLs(urls)
                    }
                }
        }
        .padding(.vertical, 4)
    }
}
