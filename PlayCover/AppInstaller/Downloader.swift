//
//  Downloader.swift
//  PlayCover
//
//  Created by Amir Mohammadi on 9/26/1401 AP.
//

import Foundation
import DownloadManager

/// DownloaderManager can be configured through this struct, default values are as the same as below
/// `public struct DownloadManagerConfig {`
///    `public var maximumRetries = 3`
///    `public var exponentialBackoffMultiplier = 10`
///    `public var usesNotificationCenter = false`
///    `public var showsLocalNotifications = false`
///    `public var logVerbosity: LogVerbosity = .none
/// `}`
///  Use `downloader.configuration = DownloadManagerConfig()` in
///  `DownloadApp` class before `downloader.addDownload` to apply
///  More details: https://github.com/shapedbyiris/download-manager/blob/master/README.md

class DownloadApp {
    let url: URL?
    let app: SourceAppsData?
    let warning: String?

    init(url: URL?, app: SourceAppsData?, warning: String?) {
        self.url = url
        self.app = app
        self.warning = warning
    }

    let downloader = DownloadManager.shared

    @MainActor
    func start() {
        if InstallVM.shared.inProgress {
            Log.shared.error(PlayCoverError.waitInstallation)
        } else {
            if let app = app, PlayApp.PROHIBITED_APPS.contains(app.bundleID) {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("alert.error", comment: "")
                alert.informativeText = String(
                    format: NSLocalizedString("error.appProhibited", comment: ""),
                    arguments: [app.name]
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("Ok", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("alert.download.downloadAnyway", comment: ""))
                if alert.runModal() == .alertFirstButtonReturn {
                    return
                }
            }

            if let warningMessage = warning, let app = app {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString(warningMessage, comment: "")
                alert.informativeText = String(
                    format: NSLocalizedString("alert.install.anyway", comment: ""),
                    arguments: [app.name]
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("button.Yes", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("button.No", comment: ""))

                if alert.runModal() == .alertSecondButtonReturn {
                    return
                }
            }
            if let url = url, let app = app {
                let ipa = IPA(url: url)
                Task {
                    if await ipa.checkOfficialMacOS(app: IPA.Application.store(app)) {
                        cancel()
                    } else {
                        if url.isFileURL {
                            proceedInstall(url, deleteIPA: false)
                        } else {
                            NetworkVM.urlAccessible(url: url, popup: true) { finalURL, urlIsValid in
                                Task { @MainActor in
                                    if urlIsValid, let newWrappedURL = finalURL {
                                        self.proceedDownload(newWrappedURL)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func cancel() {
        downloader.cancelAllDownloads()

        DownloadVM.shared.next(.canceled, 0.95, 1.0)
        DownloadVM.shared.storeAppData = nil
    }

    @MainActor
    private func proceedDownload(_ finalURL: URL) {
        DownloadVM.shared.storeAppData = self.app
        DownloadVM.shared.next(.downloading, 0.0, 0.7)

        var tmpDir: URL?
        do {
            tmpDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: URL(fileURLWithPath: "/Users"),
                                                 create: true)

            if let tmpDir = tmpDir {
                downloader.addDownload(url: finalURL,
                                       destinationURL: tmpDir,
                                       onProgress: { progress in
                    Task { @MainActor in
                        DownloadVM.shared.progress = Double(progress)
                    }
                }, onCompletion: { error, fileURL in
                    Task { @MainActor in
                        DownloadVM.shared.next(.integrity, 0.7, 0.95)

                        if let error = error {
                            DownloadVM.shared.next(.failed, 0.95, 1.0)
                            DownloadVM.shared.storeAppData = nil
                            return Log.shared.error(error)
                        }

                        self.verifyChecksum(checksum: DownloadVM.shared.storeAppData?.checksum,
                                            file: fileURL) { completing in
                            Task { @MainActor in
                                DownloadVM.shared.next(completing ? .finish : .failed, 0.95, 1.0)
                                if completing {
                                    self.proceedInstall(fileURL)
                                }
                            }
                        }
                    }
                })
            }
        } catch {
            DownloadVM.shared.next(.failed, 0.95, 1.0)

            if let tmpDir = tmpDir {
                FileManager.default.delete(at: tmpDir)
            }
            Log.shared.error(error)
        }
    }

    private func verifyChecksum(checksum: String?, file: URL?, completion: @escaping (Bool) -> Void) {
        Task {
            if let originalSum = checksum, !originalSum.isEmpty, let fileURL = file {
                if let sha256 = fileURL.sha256, originalSum != sha256 {
                    checksumAlert(originalSum: originalSum, givenSum: sha256, completion: completion)
                    return
                }
            }

            completion(true)
        }
    }

    private func checksumAlert(originalSum: String, givenSum: String, completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("playapp.download.differentChecksum", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString("playapp.download.differentChecksumDesc", comment: ""),
                arguments: [originalSum, givenSum]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    @MainActor
    private func proceedInstall(_ url: URL?, deleteIPA: Bool = true) {
        if let url = url {
            Installer.install(ipaUrl: url, export: false, returnCompletion: { _ in
                Task { @MainActor in
                    if deleteIPA {
                        FileManager.default.delete(at: url)
                    }
                    AppsVM.shared.fetchApps()
                    StoreVM.shared.resolveSources()
                    NotifyService.shared.notify(
                        NSLocalizedString("notification.appInstalled", comment: ""),
                        NSLocalizedString("notification.appInstalled.message", comment: ""))
                    DownloadVM.shared.storeAppData = nil
                }
            })
        }
    }
}
