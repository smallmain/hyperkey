import AppKit
import Foundation

enum AppUpdater {
    enum InstallError: LocalizedError {
        case missingDownloadURL
        case invalidDownloadURL
        case unsupportedInstallation
        case downloadFailed(Int)
        case networkFailure(String)
        case fileOperationFailed(String)
        case extractedAppNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingDownloadURL:
                return L10n.tr(
                    "updater.error.missing_download_url",
                    default: "This release does not include a downloadable app bundle."
                )
            case .invalidDownloadURL:
                return L10n.tr(
                    "updater.error.invalid_download_url",
                    default: "GitHub returned an invalid download URL for this release."
                )
            case .unsupportedInstallation:
                return L10n.tr(
                    "updater.error.unsupported_installation",
                    default: "Immediate update only works when %@ is running from a .app bundle.",
                    L10n.appName
                )
            case .downloadFailed(let statusCode):
                return L10n.tr(
                    "updater.error.download_failed",
                    default: "GitHub returned HTTP %d while downloading the update.",
                    statusCode
                )
            case .networkFailure(let message):
                return L10n.tr(
                    "updater.error.network_failure",
                    default: "Unable to download the update: %@",
                    message
                )
            case .fileOperationFailed(let message):
                return message
            case .extractedAppNotFound:
                return L10n.tr(
                    "updater.error.extracted_app_not_found",
                    default: "The downloaded archive did not contain a %@ bundle.",
                    Constants.appBundleName
                )
            case .commandFailed(let message):
                return message
            }
        }
    }

    static func install(update: UpdateChecker.UpdateInfo) async throws {
        guard let downloadURLString = update.downloadURL else {
            throw InstallError.missingDownloadURL
        }
        guard let downloadURL = URL(string: downloadURLString) else {
            throw InstallError.invalidDownloadURL
        }

        let fileManager = FileManager.default
        let currentAppURL = try currentAppBundleURL()
        let tempRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("hyperkey-update-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = tempRootURL.appendingPathComponent(Constants.releaseAssetName)
        let extractDirectoryURL = tempRootURL.appendingPathComponent("extract", isDirectory: true)

        do {
            try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: extractDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw InstallError.fileOperationFailed(
                L10n.tr(
                    "updater.error.prepare_temp_directory",
                    default: "Unable to prepare a temporary update directory."
                )
            )
        }

        let downloadedArchiveURL = try await downloadRelease(from: downloadURL)
        do {
            try fileManager.moveItem(at: downloadedArchiveURL, to: archiveURL)
        } catch {
            throw InstallError.fileOperationFailed(
                L10n.tr(
                    "updater.error.stage_download",
                    default: "Unable to stage the downloaded update."
                )
            )
        }

        try await runProcess(
            executablePath: "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, extractDirectoryURL.path],
            commandDescription: L10n.tr(
                "updater.error.unpack_download",
                default: "Unable to unpack the downloaded update."
            )
        )

        let newAppURL = try findExtractedApp(in: extractDirectoryURL)
        let scriptURL = tempRootURL.appendingPathComponent("install.sh")

        try writeInstallScript(to: scriptURL)
        try launchInstaller(
            scriptURL: scriptURL,
            processID: ProcessInfo.processInfo.processIdentifier,
            sourceAppURL: newAppURL,
            targetAppURL: currentAppURL,
            releasePageURL: update.releasePageURL,
            tempRootURL: tempRootURL
        )

        await MainActor.run {
            HIDMapping.clearMapping()
            NSApplication.shared.terminate(nil)
        }
    }

    private static func currentAppBundleURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundleURL.pathExtension == "app" else {
            throw InstallError.unsupportedInstallation
        }
        return bundleURL
    }

    private static func downloadRelease(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        do {
            let (downloadedFileURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw InstallError.networkFailure(
                    L10n.tr(
                        "updater.error.invalid_response",
                        default: "GitHub returned an invalid response."
                    )
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                throw InstallError.downloadFailed(http.statusCode)
            }
            return downloadedFileURL
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.networkFailure(error.localizedDescription)
        }
    }

    private static func findExtractedApp(in directoryURL: URL) throws -> URL {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw InstallError.fileOperationFailed(
                L10n.tr(
                    "updater.error.inspect_download",
                    default: "Unable to inspect the downloaded update."
                )
            )
        }

        if let appURL = entries.first(where: { $0.lastPathComponent == Constants.appBundleName })
            ?? entries.first(where: { $0.pathExtension == "app" }) {
            return appURL
        }

        throw InstallError.extractedAppNotFound
    }

    private static func writeInstallScript(to scriptURL: URL) throws {
        let script = """
        #!/bin/sh
        set -eu

        install() {
          SOURCE_APP="$1"
          TARGET_APP="$2"
          TARGET_DIR=$(/usr/bin/dirname "$TARGET_APP")
          STAGED_APP="$TARGET_DIR/.Hyperkey.app.update.$$"
          BACKUP_APP="$TARGET_DIR/.Hyperkey.app.backup.$$"

          /bin/rm -rf "$STAGED_APP" "$BACKUP_APP"
          /usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
          /usr/bin/xattr -dr com.apple.quarantine "$STAGED_APP" >/dev/null 2>&1 || true
          if [ -e "$TARGET_APP" ]; then
            /bin/mv "$TARGET_APP" "$BACKUP_APP"
          fi
          if /bin/mv "$STAGED_APP" "$TARGET_APP"; then
            /bin/rm -rf "$BACKUP_APP"
          else
            if [ -e "$BACKUP_APP" ]; then
              /bin/mv "$BACKUP_APP" "$TARGET_APP"
            fi
            /bin/rm -rf "$STAGED_APP"
            exit 1
          fi
        }

        wait_and_install() {
          PID="$1"
          SOURCE_APP="$2"
          TARGET_APP="$3"
          RELEASE_URL="$4"
          TEMP_ROOT="$5"
          SCRIPT_PATH="$6"

          exec >>/tmp/hyperkey-updater.log 2>&1

          cleanup() {
            /bin/rm -rf "$TEMP_ROOT"
          }

          fail() {
            if [ -e "$TARGET_APP" ]; then
              /usr/bin/open "$TARGET_APP" >/dev/null 2>&1 || /usr/bin/open "$RELEASE_URL" >/dev/null 2>&1 || true
            else
              /usr/bin/open "$RELEASE_URL" >/dev/null 2>&1 || true
            fi
            cleanup
            exit 1
          }

          while kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
          done

          TARGET_DIR=$(/usr/bin/dirname "$TARGET_APP")
          if [ -w "$TARGET_DIR" ]; then
            if ! install "$SOURCE_APP" "$TARGET_APP"; then
              fail
            fi
          else
            if ! /usr/bin/osascript <<'APPLESCRIPT' "$SCRIPT_PATH" "$SOURCE_APP" "$TARGET_APP"
        on run argv
            set scriptPath to quoted form of item 1 of argv
            set sourceApp to quoted form of item 2 of argv
            set targetApp to quoted form of item 3 of argv
            do shell script "/bin/sh " & scriptPath & " --install " & sourceApp & " " & targetApp with administrator privileges
        end run
        APPLESCRIPT
            then
              fail
            fi
          fi

          if ! /usr/bin/open "$TARGET_APP"; then
            fail
          fi

          cleanup
        }

        case "${1:-}" in
          --install)
            install "$2" "$3"
            ;;
          --wait-and-install)
            wait_and_install "$2" "$3" "$4" "$5" "$6" "$7"
            ;;
          *)
            exit 64
            ;;
        esac
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw InstallError.fileOperationFailed(
                L10n.tr(
                    "updater.error.prepare_installer",
                    default: "Unable to prepare the update installer."
                )
            )
        }
    }

    private static func launchInstaller(
        scriptURL: URL,
        processID: Int32,
        sourceAppURL: URL,
        targetAppURL: URL,
        releasePageURL: String,
        tempRootURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            "--wait-and-install",
            String(processID),
            sourceAppURL.path,
            targetAppURL.path,
            releasePageURL,
            tempRootURL.path,
            scriptURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw InstallError.fileOperationFailed(
                L10n.tr(
                    "updater.error.launch_installer",
                    default: "Unable to launch the update installer."
                )
            )
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        commandDescription: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw InstallError.commandFailed(commandDescription)
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let stderr, !stderr.isEmpty {
                    throw InstallError.commandFailed(stderr)
                }
                throw InstallError.commandFailed(commandDescription)
            }
        }.value
    }
}
