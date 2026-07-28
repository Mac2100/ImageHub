import SwiftUI

struct DrivesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if appState.drives.isEmpty {
                    EmptyStateView(
                        symbol: "externaldrive.badge.questionmark",
                        title: "No USB drives detected",
                        message: "Plug in a USB stick — 16 GB or larger for Windows 11. ImageHub only ever lists removable external media; internal disks are filtered out and can't be selected."
                    ) {
                        Button("Scan again") {
                            Task { await appState.refreshDrives() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 300)
                } else {
                    VStack(spacing: 0) {
                        ForEach(appState.drives) { drive in
                            DriveRow(
                                drive: drive,
                                isSelected: appState.selectedDriveID == drive.id,
                                onSelect: { appState.selectedDriveID = drive.id },
                                onEject: { Task { await DiskService.eject(drive.id) } }
                            )
                            if drive.id != appState.drives.last?.id {
                                Divider()
                            }
                        }
                    }
                    .glassCard(padding: 0)
                }

                NoticeBanner(
                    kind: .warning,
                    title: "Building erases the whole drive",
                    messages: [
                        "The selected drive is repartitioned and formatted FAT32 from scratch. Anything on it is gone.",
                        "FAT32 isn't a preference — UEFI firmware is only guaranteed to read FAT, so it's the one filesystem Windows Setup media can reliably boot from. That's also why install.wim gets split when it's over 4 GB."
                    ]
                )
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(
                title: "USB Drives",
                subtitle: appState.drives.isEmpty
                    ? "Nothing plugged in"
                    : "\(appState.drives.count) eligible drive\(appState.drives.count == 1 ? "" : "s")"
            ) {
                HStack(spacing: 8) {
                    if appState.isScanningDrives {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await appState.refreshDrives() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    Button {
                        appState.startBuild(template: nil)
                    } label: {
                        Label("Build USB Drive", systemImage: "externaldrive.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.drives.isEmpty || appState.isBuilding)
                }
            }
            .background(.bar)
        }
    }
}

struct DriveRow: View {
    let drive: USBDrive
    let isSelected: Bool
    let onSelect: () -> Void
    let onEject: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? AnyShapeStyle(theme.primary) : AnyShapeStyle(.tertiary))

            Image(systemName: "externaldrive.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(drive.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Chip(text: drive.id, tint: .secondary)
                }
                Text(drive.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if drive.sizeBytes < 16_000_000_000 {
                Chip(text: "Small", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help("Windows 11 media needs roughly 8–16 GB depending on the image.")
            }

            Button("Eject") { onEject() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
