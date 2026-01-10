import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = PlannerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Main content scrollable
            ScrollView {
                VStack(spacing: 20) {
                    // Step 1: Plan Database
                    GroupBox(label: Label("Step 1: Plan Database", systemImage: "database")) {
                        planDatabaseSection
                            .padding(8)
                    }

                    // Step 2 & 3: Sources & Destination
                    HStack(alignment: .top, spacing: 20) {
                        // Step 2: Sources
                        GroupBox(
                            label: Label("Step 2: Sources (Input)", systemImage: "arrow.down.doc")
                        ) {
                            sourcesSection
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity)

                        // Step 3: Destination
                        GroupBox(
                            label: Label(
                                "Step 3: Destination (Output)", systemImage: "externaldrive")
                        ) {
                            destinationSection
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Step 4: Phase 1
                    GroupBox(
                        label: Label(
                            "Step 4: Phase 1 (Scan & Analysis)", systemImage: "magnifyingglass")
                    ) {
                        phase1Section
                            .padding(8)
                    }

                    // Step 5: Phase 2
                    GroupBox(label: Label("Step 5: Phase 2 (Execution)", systemImage: "play.fill"))
                    {
                        phase2Section
                            .padding(8)
                    }
                }
                .padding()
            }
            // Log panel fixed at bottom
            Divider()
            progressPanel
                .frame(height: 200)
                .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear { vm.bootstrap() }
    }

    // MARK: - Sections

    private var planDatabaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $vm.planMode) {
                ForEach(PlanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            HStack {
                Text(vm.planDBURL?.lastPathComponent ?? "No Database Selected")
                    .font(.headline)
                if let path = vm.planDBURL?.path {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(vm.planMode == .new ? "Create / Save..." : "Select Existing...") {
                    vm.openChooseDBPanel(merging: false)
                }
                Button("Reveal in Finder") {
                    vm.revealPlanDBInFinder()
                }
                .disabled(vm.planDBURL == nil)
            }

            if vm.planMode == .append {
                Button("Merge another plan...") {
                    vm.openChooseDBPanel(merging: true)
                }
                .font(.caption)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DropZoneView(
                title: "Drag & Drop Libraries/Folders",
                subtitle: "Photos Libraries or Folders",
                acceptHint: "Drop Sources Here",
                onDropURLs: { vm.addSources(from: $0) }
            )

            HStack {
                Button("Add Source…") { vm.openAddSourcesPanel() }
                Spacer()
                Button("Clear") { vm.clearSources() }
                    .disabled(vm.sources.isEmpty || vm.isRunning)
            }

            List {
                Section("Libraries") {
                    if vm.sources.filter({ $0.kind == .library }).isEmpty {
                        Text("No libraries").foregroundStyle(.secondary)
                    }
                    ForEach(vm.sources.filter { $0.kind == .library }) { s in
                        SourceRowView(source: s, onRemove: { vm.removeSource(s) })
                    }
                }
                Section("Folders") {
                    if vm.sources.filter({ $0.kind == .folder }).isEmpty {
                        Text("No folders").foregroundStyle(.secondary)
                    }
                    ForEach(vm.sources.filter { $0.kind == .folder }) { s in
                        SourceRowView(source: s, onRemove: { vm.removeSource(s) })
                    }
                }
            }
            .frame(minHeight: 150)
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DropZoneView(
                title: "Destination Folder",
                subtitle: "Where files will be copied",
                acceptHint: "Drop Destination Here",
                onDropURLs: { vm.setDestinationFromDrop($0) }
            )

            HStack {
                Button("Choose DEST…") { vm.openChooseDestPanel() }
                Spacer()
            }

            if let dest = vm.destFolder {
                Text(dest.path)
                    .font(.body)
                    .bold()
                    .lineLimit(2)
            } else {
                Text("No destination selected")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var phase1Section: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Scans sources, verifies consistency, and builds the plan database.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if vm.isRunning {
                ProgressView().controlSize(.small)
                Text("Running Phase 1...")
                Button("Cancel") { vm.cancel() }
            } else {
                Button("Start Phase 1") {
                    vm.startPhase1()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStart || vm.isRunningPhase2)
            }
        }
    }

    private var phase2Section: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p2 = vm.phase2, p2.isRunning {
                VStack(alignment: .leading) {
                    Text("Phase 2 Running...").font(.headline)
                    ProgressView(
                        value: Double(p2.progress.opsDone),
                        total: Double(max(1, p2.progress.opsTotal)))
                    HStack {
                        Text("\(p2.progress.opsDone) / \(p2.progress.opsTotal) Ops")
                        Spacer()
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: p2.progress.bytesCopied, countStyle: .file))
                    }
                    Text(p2.progress.currentOp)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Cancel Phase 2") { vm.cancelPhase2() }
                        .keyboardShortcut(.cancelAction)
                }
            } else {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Executes the copy operations defined in the plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button("Start Phase 2") {
                        vm.startPhase2()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.planDBURL == nil || vm.isRunning)

                    if vm.planDBURL != nil && !vm.isRunning {
                        Button("Reset Ops") {
                            vm.resetPhase2Ops()
                        }
                        .help("Resets all operations to PENDING state to retry.")
                    }
                }
            }

            if let err = vm.lastError {
                Text("Error: \(err)")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color(NSColor.separatorColor)).frame(height: 1)
            HStack {
                Text("Logs / Status").font(.headline)
                Spacer()
                Text(vm.progress.stage.rawValue)
            }
            .padding(8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.logs.indices, id: \.self) { i in
                        Text(vm.logs[i])
                            .font(.caption2)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 8)
            }
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
