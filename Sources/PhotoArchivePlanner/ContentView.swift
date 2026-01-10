import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = PlannerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Main Content
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    HStack {
                        Image(systemName: "photo.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text("Photo Archive Planner")
                                .font(.title2)
                                .bold()
                            Text("Organize and Deduplicate Media")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 8)

                    // Step 1: Database
                    StepCard(title: "1. Database", icon: "database") {
                        planDatabaseSection
                    }

                    // Steps 2 & 3: I/O
                    HStack(alignment: .top, spacing: 20) {
                        StepCard(title: "2. Input Sources", icon: "arrow.down.doc") {
                            sourcesSection
                        }
                        .frame(maxWidth: .infinity)

                        StepCard(title: "3. Destination", icon: "externaldrive") {
                            destinationSection
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Step 4: Analysis
                    StepCard(title: "4. Analysis (Phase 1)", icon: "magnifyingglass") {
                        phase1Section
                    }

                    // Step 5: Execution
                    StepCard(title: "5. Execution (Phase 2)", icon: "play.fill") {
                        phase2Section
                    }
                }
                .padding(24)
            }
            .background(Color(NSColor.textBackgroundColor))  // Slightly different bg

            // Console / Log Panel
            ConsolePanel(vm: vm)
                .frame(height: 220)
        }
        .onAppear { vm.bootstrap() }
    }

    // MARK: - Sections

    private var planDatabaseSection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $vm.planMode) {
                    ForEach(PlanMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 4) {
                if let url = vm.planDBURL {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.blue)
                        Text(url.lastPathComponent)
                            .bold()
                    }
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No Database Selected")
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Button(vm.planMode == .new ? "Create / Save New..." : "Select Existing...") {
                    vm.openChooseDBPanel(merging: false)
                }

                if vm.planMode == .append {
                    Button("Merge Another Plan...") {
                        vm.openChooseDBPanel(merging: true)
                    }
                    .controlSize(.small)
                }

                Button("Show in Finder") {
                    vm.revealPlanDBInFinder()
                }
                .controlSize(.small)
                .disabled(vm.planDBURL == nil)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropZoneView(
                title: "Drop Libraries or Folders",
                subtitle: "Photos Libraries imply 'Originals' scan",
                onDropURLs: { vm.addSources(from: $0) }
            )

            HStack {
                Button(action: { vm.openAddSourcesPanel() }) {
                    Label("Add Source", systemImage: "plus")
                }
                Spacer()
                Button("Clear All") { vm.clearSources() }
                    .controlSize(.small)
                    .disabled(vm.sources.isEmpty || vm.isRunning)
            }

            if vm.sources.isEmpty {
                Text("No sources added")
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                    .foregroundStyle(.tertiary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
            } else {
                List {
                    ForEach(vm.sources) { s in
                        HStack {
                            Image(systemName: s.kind == .library ? "photo.on.rectangle" : "folder")
                            Text(s.displayName)
                            Spacer()
                            Text(s.url.path).font(.caption).foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                            Button {
                                vm.removeSource(s)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.gray)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropZoneView(
                title: "Drop Destination Folder",
                subtitle: "Root for YYYY/MM/DD archive",
                onDropURLs: { vm.setDestinationFromDrop($0) }
            )

            Button("Choose Destination...") { vm.openChooseDestPanel() }

            VStack(alignment: .leading, spacing: 4) {
                Text("Selected Destination:")
                    .font(.caption).bold().foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.orange)
                    if let dest = vm.destFolder {
                        Text(dest.path)
                            .bold()
                            .lineLimit(2)
                    } else {
                        Text("None selected")
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))

            Spacer()
        }
    }

    private var phase1Section: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Deep Scan & Planning")
                    .font(.headline)
                Text("Scans all sources, hashes files, and identifies duplicates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if vm.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning...")
                        .foregroundStyle(.blue)
                }
                Button("Cancel") { vm.cancel() }
            } else {
                Button(action: { vm.startPhase1() }) {
                    Text("Start Phase 1")
                        .font(.body.bold())
                        .frame(minWidth: 120)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!vm.canStart || vm.isRunningPhase2)
            }
        }
    }

    private var phase2Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p2 = vm.phase2, p2.isRunning {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Executing Plan").font(.headline)
                        Text(p2.progress.currentOp)
                            .font(.caption2)
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Cancel Phase 2") { vm.cancelPhase2() }
                        .keyboardShortcut(.cancelAction)
                }

                ProgressView(
                    value: Double(p2.progress.opsDone),
                    total: Double(max(1, p2.progress.opsTotal)))

                HStack {
                    Text("\(p2.progress.opsDone) / \(p2.progress.opsTotal) Ops")
                        .monospacedDigit()
                    Spacer()
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: p2.progress.bytesCopied, countStyle: .file)
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Execute Copy")
                            .font(.headline)
                        Text("Performs physical copy and verification.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if vm.planDBURL != nil && !vm.isRunning {
                        Button("Reset Ops (Retry)") {
                            vm.resetPhase2Ops()
                        }
                        .tint(.red)
                        .controlSize(.small)
                    }

                    Button(action: { vm.startPhase2() }) {
                        Text("Start Phase 2")
                            .font(.body.bold())
                            .frame(minWidth: 120)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(vm.planDBURL == nil || vm.isRunning)
                }
            }

            if let err = vm.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                }
                .foregroundStyle(.red)
                .font(.caption)
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(4)
            }
        }
    }
}

// MARK: - Components

struct StepCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                Rectangle().frame(height: 1).foregroundStyle(Color.gray.opacity(0.1)),
                alignment: .bottom)

            content
                .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct ConsolePanel: View {
    @ObservedObject var vm: PlannerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Status Bar
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(vm.isRunning ? "RUNNING" : (vm.lastError == nil ? "READY" : "ERROR"))
                    .font(.caption.bold())
                    .foregroundStyle(statusColor)

                Spacer()

                HStack(spacing: 12) {
                    Label("Files: \(vm.progress.discoveredFiles)", systemImage: "doc")
                    Label("Unique: \(vm.progress.uniqueBlobs)", systemImage: "star")
                    Label("Errs: \(vm.progress.errorCount)", systemImage: "exclamationmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Console
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.logs.indices, id: \.self) { i in
                            Text(vm.logs[i])
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color(red: 0.1, green: 0.1, blue: 0.12))  // Dark console bg
                .onChange(of: vm.logs.count) { _ in
                    if let last = vm.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    var statusColor: Color {
        if vm.lastError != nil { return .red }
        if vm.isRunning { return .blue }
        return .green
    }
}

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let onDropURLs: ([URL]) -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.title)
                .foregroundStyle(isTargeted ? .blue : .gray)
            Text(title)
                .font(.body).bold()
                .foregroundStyle(isTargeted ? .primary : .secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.blue : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6])
                )
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            DropUtil.loadFileURLs(from: providers) { urls in
                onDropURLs(urls)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }
}
