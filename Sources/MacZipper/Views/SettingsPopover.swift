import SwiftUI

struct SettingsPopover: View {
    @ObservedObject var viewModel: ExtractorViewModel
    @State private var copiedCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preferences")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-extract on drop", isOn: $viewModel.autoExtractOnDrop)
                Toggle("Reveal in Finder when done", isOn: $viewModel.revealInFinder)
                Toggle("Move archive to Trash after", isOn: $viewModel.trashArchiveAfterExtract)
                Toggle("Quit app after extraction", isOn: $viewModel.autoQuitAfterExtract)

                HStack {
                    Text("If exists")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Spacer()
                    Picker("", selection: $viewModel.conflictPolicyRaw) {
                        ForEach(ConflictPolicy.allCases, id: \.rawValue) { policy in
                            Text(policy == .rename ? "Rename" : "Replace").tag(policy.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.85))

            Divider()
                .background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("Engines")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .textCase(.uppercase)

                HStack {
                    Text("ZIP")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green.opacity(0.85))
                            .frame(width: 6, height: 6)
                        Text(viewModel.backendStatus.zipEngine)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }

                HStack {
                    Text("RAR")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(viewModel.backendStatus.rarBackend.isFullRarSupport ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                            .frame(width: 6, height: 6)
                        Text(viewModel.backendStatus.rarBackend.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }

                if !viewModel.backendStatus.rarBackend.isFullRarSupport {
                    Button {
                        viewModel.copyBrewInstallCommand()
                        copiedCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            copiedCommand = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedCommand ? "checkmark" : "terminal")
                                .font(.system(size: 10))
                            Text(copiedCommand ? "Copied: brew install unar" : "Copy: brew install unar")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Install unar for full RAR5 & encrypted RAR support")
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            HStack {
                Text("By Aaron Lacap")
                Spacer()
                Text("2026")
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(16)
        .frame(width: 260)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .preferredColorScheme(.dark)
    }
}
