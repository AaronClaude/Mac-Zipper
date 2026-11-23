import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: ExtractorViewModel
    @State private var isDropTargeted = false
    @State private var showSettings = false
    @State private var copiedBrew = false
    @FocusState private var isPasswordFocused: Bool

    private let surfaceColor = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let elevatedColor = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let borderColor = Color.white.opacity(0.09)

    var body: some View {
        ZStack {
            // Pure black canvas with ultra-subtle top ambient light
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [Color.white.opacity(0.045), Color.clear],
                center: .top,
                startRadius: 10,
                endRadius: 340
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                Divider()
                    .background(Color.white.opacity(0.06))

                mainContent
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 340, idealHeight: 380)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Leave space for macOS traffic lights on the left
            Spacer().frame(width: 58)

            HStack(spacing: 7) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("MacZipper")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
            }

            if !viewModel.queuedURLs.isEmpty {
                Text("+\(viewModel.queuedURLs.count) queued")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            Spacer()

            if viewModel.archiveURL != nil {
                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear current archive")
            }

            Button {
                viewModel.refreshBackendStatus()
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPopover(viewModel: viewModel)
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if let archiveURL = viewModel.archiveURL {
            archiveWorkspace(url: archiveURL)
        } else {
            dropZoneView
        }
    }

    private var dropZoneView: some View {
        VStack(spacing: 12) {
            VStack(spacing: 18) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(isDropTargeted ? 0.12 : 0.05))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(isDropTargeted ? 0.35 : 0.12), lineWidth: 1)
                        )

                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.to.line.compact")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.white)
                        .scaleEffect(isDropTargeted ? 1.08 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDropTargeted)
                }

                VStack(spacing: 6) {
                    Text(isDropTargeted ? "Release to extract" : "Drop archive to extract")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        formatBadge("ZIP")
                        formatBadge("RAR")
                        formatBadge("7Z")
                        formatBadge("TAR")
                    }
                }

                Button {
                    viewModel.openFilePicker()
                } label: {
                    Text("Choose File")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.white.opacity(0.45) : Color.white.opacity(0.09),
                        style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [5, 5])
                    )
            )
            .animation(.easeOut(duration: 0.18), value: isDropTargeted)

            outputFolderBar(
                pathText: viewModel.defaultOutputDisplayPath,
                showReset: viewModel.hasCustomOutputFolder
            )
        }
    }

    private func archiveWorkspace(url: URL) -> some View {
        VStack(spacing: 14) {
            // Archive Header Card
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(elevatedColor)
                        .frame(width: 42, height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(borderColor, lineWidth: 1)
                        )
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        if let format = ArchiveFormat.detect(from: url) {
                            formatBadge(format.label)
                        }
                        if let meta = viewModel.metadata {
                            Text(formatBytes(meta.compressedSize))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.55))

                            if meta.fileCount > 0 {
                                Text("·")
                                    .foregroundStyle(Color.white.opacity(0.3))
                                Text("\(meta.fileCount) \(meta.fileCount == 1 ? "item" : "items")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        } else {
                            Text("Inspecting…")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                }

                Spacer()

                if let meta = viewModel.metadata, !meta.entries.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.showContents.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.showContents ? "Hide" : "Contents")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: viewModel.showContents ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(surfaceColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )

            // Expandable Contents Preview
            if viewModel.showContents, let entries = viewModel.metadata?.entries {
                contentsPreview(entries: entries)
            }

            // Destination Row
            outputFolderBar(
                pathText: viewModel.destinationParent?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Same as archive",
                showReset: viewModel.hasCustomOutputFolder
            )

            Spacer(minLength: 0)

            // State Action Area
            stateArea
        }
    }

    private func contentsPreview(entries: [ArchiveEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(entries.prefix(150)) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(entry.isDirectory ? 0.65 : 0.4))
                            .frame(width: 14)
                        Text(entry.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !entry.isDirectory {
                            Text(formatBytes(entry.size))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                    }
                }
                if entries.count > 150 {
                    Text("…and \(entries.count - 150) more items")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.top, 4)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 130)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var stateArea: some View {
        switch viewModel.state {
        case .idle, .inspecting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading archive…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

        case .ready:
            Button {
                viewModel.startExtraction()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Extract Now")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)

        case .extracting(let progress, let status):
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    Button("Cancel") {
                        viewModel.cancel()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .buttonStyle(.plain)
                }

                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .animation(.easeOut(duration: 0.15), value: progress)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.white)
                }
            }
            .padding(14)
            .background(surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )

        case .needsPassword(let message):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange.opacity(0.9))
                    Text(message ?? "Password required")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                }

                HStack(spacing: 8) {
                    SecureField("Enter archive password", text: $viewModel.passwordInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(elevatedColor, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: 1)
                        )
                        .focused($isPasswordFocused)
                        .onSubmit {
                            viewModel.submitPassword()
                        }
                        .onAppear {
                            isPasswordFocused = true
                        }

                    Button("Unlock") {
                        viewModel.submitPassword()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )

        case .completed(let outputURL, let itemCount):
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.green.opacity(0.9))
                    Text("Extracted \(itemCount) \(itemCount == 1 ? "item" : "items")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(outputURL.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    Button {
                        viewModel.revealInFinder(outputURL)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                            Text("Reveal in Finder")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.openInFinder(outputURL)
                    } label: {
                        Text("Open")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(borderColor, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.green.opacity(0.28), lineWidth: 1)
            )

        case .failed(let message, let canInstallUnar):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.red.opacity(0.9))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Try Again") {
                        viewModel.startExtraction()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .buttonStyle(.plain)

                    if canInstallUnar {
                        Button {
                            viewModel.copyBrewInstallCommand()
                            copiedBrew = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                copiedBrew = false
                            }
                        } label: {
                            Text(copiedBrew ? "Copied: brew install unar" : "Copy: brew install unar")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.red.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - Helpers

    private func outputFolderBar(pathText: String, showReset: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
            Text("Output")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))

            Text(pathText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if showReset {
                Button {
                    viewModel.resetDefaultOutputFolder()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reset to same folder as archive")
            }

            Button("Choose…") {
                viewModel.chooseDestinationFolder()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func formatBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !validProviders.isEmpty else { return false }

        Task {
            var droppedURLs: [URL] = []
            for provider in validProviders {
                if let url = await loadFileURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            if !droppedURLs.isEmpty {
                viewModel.handleIncomingURLs(droppedURLs)
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
