import SwiftUI

private func megabytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A row in the menu bar panel, shown only while an update is waiting.
/// Its button opens the Health screen, where the notes and controls are.
struct MenuUpdateRow: View {
    @ObservedObject var updater: Updater
    var open: () -> Void

    var body: some View {
        if let release = updater.release {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WheelBridge \(release.version)").font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: open) { Text(buttonTitle) }
                    .glassProminentButton()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)
        }
    }

    private var detail: String {
        switch updater.state {
        case .downloading(_, let done, let total): return "Downloading, \(total > 0 ? Int(Double(done) / Double(total) * 100) : 0)%"
        case .paused: return "Download paused"
        case .verifying: return "Checking the download"
        case .ready: return "Ready to install"
        case .installing: return "Installing"
        case .failed: return "Update needs attention"
        default: return "New version available"
        }
    }

    private var buttonTitle: String {
        switch updater.state {
        case .ready: return "Install"
        case .available: return "Update"
        default: return "View"
        }
    }
}

/// The Updates section of the Health inspector.
struct UpdatesSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates").font(.system(size: 17, weight: .semibold))
            fact("This version", Updater.currentVersion)
            if let from = updater.updatedFrom {
                fact("Updated from", from)
            }
            HStack {
                Text("Check every day").foregroundStyle(.secondary)
                Spacer()
                Toggle("Check every day", isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .font(.system(size: 13))

            if let release = updater.release {
                releaseCard(release)
            } else {
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(isFailure ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    updater.check(manual: true)
                } label: {
                    Text(updater.state == .checking ? "Checking…" : "Check Now").frame(maxWidth: .infinity)
                }
                .glassButton()
            }
        }
    }

    // MARK: No update

    private var isFailure: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var statusLine: String {
        switch updater.state {
        case .checking: return "Checking GitHub for a new version."
        case .upToDate(let date): return "Up to date. Checked \(date.formatted(date: .omitted, time: .shortened))."
        case .failed(let message, _): return message
        default:
            if let last = updater.lastChecked {
                return "Last checked \(last.formatted(.relative(presentation: .named)))."
            }
            return "Not checked yet."
        }
    }

    // MARK: An update

    @ViewBuilder
    private func releaseCard(_ release: Updater.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(release.version) is available").font(.system(size: 13, weight: .semibold))
                Spacer()
                if release.size > 0 {
                    Text(megabytes(release.size)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if !release.notes.isEmpty {
                // Short notes take only their own height; long ones scroll.
                if release.notes.count > 280 || release.notes.split(whereSeparator: \.isNewline).count > 7 {
                    ScrollView { notesText(release.notes) }.frame(height: 120)
                } else {
                    notesText(release.notes)
                }
            }
            progress
            actions(release)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    private func notesText(_ markdown: String) -> some View {
        Text(notes(markdown))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// GitHub release notes are Markdown. Inline styling and links are kept,
    /// and each line stays its own line.
    private func notes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let cleaned = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var line = String(line)
                while line.hasPrefix("#") { line.removeFirst() }
                if line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }
                return line.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }

    @ViewBuilder
    private var progress: some View {
        switch updater.state {
        case .downloading(_, let done, let total), .paused(_, let done, let total, _):
            LevelBar(fraction: total > 0 ? Double(done) / Double(total) : 0)
            Text(progressLine(done: done, total: total))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .verifying:
            Text("Checking the download.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .ready:
            Text(updater.installBlocker ?? "Downloaded and checked. Installing restarts WheelBridge and its helper.")
                .font(.system(size: 11))
                .foregroundStyle(updater.installBlocker == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .installing:
            Text("Installing. WheelBridge will reopen in a moment.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let message, _):
            Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private func progressLine(done: Int64, total: Int64) -> String {
        if case .paused(_, _, _, let reason?) = updater.state { return reason }
        let amount = "\(megabytes(done)) of \(megabytes(total))"
        if case .paused = updater.state { return "Paused, \(amount)" }
        return "Downloading, \(amount)"
    }

    @ViewBuilder
    private func actions(_ release: Updater.Release) -> some View {
        HStack(spacing: 8) {
            switch updater.state {
            case .available:
                wide("Update", prominent: true) { updater.download() }
            case .downloading:
                wide("Pause") { updater.pause() }
                wide("Cancel") { updater.cancel() }
            case .paused:
                wide("Resume", prominent: true) { updater.download() }
                wide("Cancel") { updater.cancel() }
            case .ready:
                wide("Install and Relaunch", prominent: true) { updater.install() }
            case .failed:
                wide("Try Again", prominent: true) { updater.download() }
                wide("Open Download") { updater.revealDownload() }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func wide(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }.glassProminentButton()
        } else {
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }.glassButton()
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 13))
    }
}

extension Updater {
    /// Sample states for the preview screens: `--update available` and so on.
    func applyPreview(_ name: String) {
        let release = Release(
            version: "0.2.0",
            notes: "## What's new\n- **G920 support** through HID++.\n- Smoother damper in ACC.\n- Fixes the range resetting after sleep.",
            dmgURL: Self.releasesPage, dmgName: "WheelBridge-0.2.0.dmg", size: 14_200_000, sumsURL: nil)
        switch name {
        case "available": preview(.available(release))
        case "downloading": preview(.downloading(release, done: 8_700_000, total: release.size))
        case "ready": preview(.ready(release))
        case "failed": preview(.failed("The download was damaged on the way. Its checksum doesn't match. Try again.", release))
        default: preview(.upToDate(Date()))
        }
    }
}
