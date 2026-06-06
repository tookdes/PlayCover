//
//  Installer.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 24.11.2021.
//

import Foundation

class Installer {
    private static let installStateLock = NSLock()
    private static var installInFlight = false

    private static func beginInstallIfPossible() -> Bool {
        installStateLock.lock()
        defer { installStateLock.unlock() }
        guard !installInFlight else { return false }
        installInFlight = true
        return true
    }

    private static func finishInstall() {
        installStateLock.lock()
        installInFlight = false
        installStateLock.unlock()
    }

    @MainActor
    private static func updateInstallProgress(_ step: InstallStepsNative,
                                              _ startProgress: Double,
                                              _ stopProgress: Double) {
        InstallVM.shared.next(step, startProgress, stopProgress)
    }

    @MainActor
    static func installPlayToolsPopup() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.install.injectPlayToolsQuestion", comment: "")
        alert.informativeText = NSLocalizedString("alert.install.playToolsInformative", comment: "")

        alert.alertStyle = .informational

        alert.showsSuppressionButton = true
        alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "String")

        let yes = alert.addButton(withTitle: NSLocalizedString("button.Yes", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.No", comment: ""))

        // Set default button to install playtools
        yes.keyEquivalent = "\r"

        let response = alert.runModal()

        if alert.suppressionButton?.state == .on {
            InstallPreferences.shared.showInstallPopup = false
            InstallPreferences.shared.alwaysInstallPlayTools = response == .alertFirstButtonReturn
        }

        return response == .alertFirstButtonReturn
    }

    static private func returnErrorString(error: Error) -> String {
        switch error.localizedDescription {
        case let str where str.contains("(disk full?)"): NSLocalizedString("alert.notSpace", comment: "")
        case let str where str.contains(".html"): NSLocalizedString("alert.quota.limit", comment: "")
        case let str where str.contains(".ipa"): NSLocalizedString("alert.corrupted", comment: "")
        default: NSLocalizedString(error.localizedDescription, comment: "")
        }
    }

    // swiftlint:disable:next function_body_length
    static func install(ipaUrl: URL, export: Bool, returnCompletion: @escaping (URL?) -> Void) {
        guard beginInstallIfPossible() else {
            Task { @MainActor in
                Log.shared.error(PlayCoverError.waitInstallation)
                returnCompletion(nil)
            }
            return
        }

        Task { @MainActor in
            // If (the option key is held or the install playtools popup settings is true) and its not an export,
            //    then show the installer dialog
            let installPlayTools: Bool
            let applicationType = InstallPreferences.shared.defaultAppType

            if (ModifierKeyObserver.shared.isOptionKeyPressed
                    || InstallPreferences.shared.showInstallPopup) && !export {
                installPlayTools = installPlayToolsPopup()
            } else {
                installPlayTools = InstallPreferences.shared.alwaysInstallPlayTools
            }

            updateInstallProgress(.begin, 0.0, 0.0)

            Task.detached(priority: .userInitiated) {
                defer { finishInstall() }
                let ipa = IPA(url: ipaUrl)

                do {
                    await updateInstallProgress(.unzip, 0.0, 0.5)
                    try ipa.allocateTempDir()

                    let app = try ipa.unzip()
                    guard Entitlements.isBundleIDSafe(app.info.bundleIdentifier) else {
                        throw ShellError(output: "Unsafe bundle identifier: \(app.info.bundleIdentifier)")
                    }
                    if await ipa.checkOfficialMacOS(app: IPA.Application.base(app)) {
                        ipa.releaseTempDir()
                        await updateInstallProgress(.failed, 0.95, 1.0)
                        await MainActor.run {
                            returnCompletion(nil)
                        }
                        return
                    }
                    await updateInstallProgress(.library, 0.5, 0.55)
                    try saveEntitlements(app)
                    let machos = resolveValidMachOs(app)
                    app.validMachOs = machos

                    await updateInstallProgress(.playtools, 0.55, 0.85)

                    for macho in machos {
                        if try Macho.isMachoEncrypted(atURL: macho) {
                            throw PlayCoverError.appEncrypted
                        }

                        if !export {
                            try Macho.convertMacho(macho)
                            try Shell.signMacho(macho)
                        }
                    }

                    if export {
                        try await PlayTools.injectInIPA(app.executable, payload: app.url)
                    } else if installPlayTools {
                        try await PlayTools.installInIPA(app.executable)
                    }

                    app.info.applicationCategoryType = applicationType

                    if !export {
                        // -rwxr-xr-x
                        try app.executable.setBinaryPosixPermissions(0o755)
                        try removeMobileProvision(app)
                    }

                    let info = app.info
                    info.assert(minimumVersion: 11.0)
                    try info.write()
                    await updateInstallProgress(.wrapper, 0.85, 0.95)

                    var finalURL: URL

                    if export {
                        finalURL = try ipa.packIPABack(app: app.url)
                    } else {
                        finalURL = try wrap(app)
                        let installedApp = PlayApp(appUrl: finalURL)

                        installedApp.sign()
                    }

                    ipa.releaseTempDir()
                    try ipa.removeQuarantine(finalURL)
                    await updateInstallProgress(.finish, 0.95, 1.0)
                    await MainActor.run {
                        returnCompletion(finalURL)
                    }
                } catch {
                    Log.shared.error(returnErrorString(error: error))
                    ipa.releaseTempDir()

                    await updateInstallProgress(.failed, 0.95, 1.0)
                    await MainActor.run {
                        returnCompletion(nil)
                    }
                }
            }
        }
    }

    static func fromIPA(detectingAppNameInFolder folderURL: URL) throws -> BaseApp {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)

        var url: URL?

        for entry in contents {
            guard entry.hasSuffix(".app") else {
                continue
            }

            let entryURL = folderURL.appendingEscapedPathComponent(entry)
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            url = entryURL
            break
        }

        guard let url = url else {
            throw PlayCoverError.infoPlistNotFound
        }

        return BaseApp(appUrl: url)
    }

    /// Returns an array of URLs to MachO files within the app
    static func resolveValidMachOs(_ baseApp: BaseApp) -> [URL] {
        if let validMachOs = baseApp.validMachOs {
            return validMachOs
        }

        var resolved: [URL] = []
        let serialQueue = DispatchQueue(label: "baseAppUrlResolver")

        baseApp.url.enumerateContents { url, attributes in
            guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize > 4 else {
                return
            }

            if !url.pathExtension.isEmpty && url.pathExtension != "dylib" {
                return
            }

            let handle = try FileHandle(forReadingFrom: url)

            defer {
                do {
                    try handle.close()
                } catch {
                    print("Failed to close FileHandle for \(url.absoluteString): \(error.localizedDescription)")
                }
            }

            guard let data = try handle.read(upToCount: 4) else {
                return
            }

            serialQueue.sync {
                switch Array(data) {
                case [202, 254, 186, 190]: resolved.append(url)
                case [207, 250, 237, 254]: resolved.append(url)
                default: return
                }
            }
        }

        return resolved
    }

    /// Wrapper for codesign, applies the given entitlements to the application and all of its contents
    static func saveEntitlements(_ baseApp: BaseApp) throws {
        let toSave = try Entitlements.dumpEntitlements(exec: baseApp.executable)
        try toSave.store(baseApp.entitlements)
    }

    static func removeMobileProvision(_ baseApp: BaseApp) throws {
        let provision = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }
    }

    /// Generates a wrapper bundle for an iOS app that allows it to be launched from Finder and other macOS UIs
    static func wrap(_ baseApp: BaseApp) throws -> URL {
        let info = AppInfo(contentsOf: baseApp.url
            .appendingPathComponent("Info")
            .appendingPathExtension("plist"))
        let location = AppsVM.appDirectory
            .appendingSafeFileNameComponent(info.bundleIdentifier)
            .appendingPathExtension("app")
        let backupLocation = location.deletingLastPathComponent()
            .appendingEscapedPathComponent(".\(location.lastPathComponent).backup.\(UUID().uuidString)")

        var createdBackup = false
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.moveItem(at: location, to: backupLocation)
            createdBackup = true
        }

        do {
            try FileManager.default.moveItem(at: baseApp.url, to: location)
            if createdBackup {
                FileManager.default.delete(at: backupLocation)
            }
        } catch {
            if createdBackup && !FileManager.default.fileExists(atPath: location.path) {
                try? FileManager.default.moveItem(at: backupLocation, to: location)
            }
            throw error
        }
        return location
    }
}
