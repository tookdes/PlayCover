//
//  AppViewModel.swift
//  PlayCover
//

import Foundation

@MainActor
class AppsVM: ObservableObject {

    public static let appDirectory = PlayTools.playCoverContainer.appendingPathComponent("Applications")

    static let shared = AppsVM()

    private init() {
        try? AppsVM.ensureBaseDirectoriesExist()
        PlayTools.installOnSystem()
        fetchApps()
    }

    static func ensureBaseDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
    }

    @Published var filteredApps: [PlayApp] = []
    @Published var apps: [PlayApp] = []
    @Published var searchText: String = ""
    @Published var updatingApps = true

    private var fetchTask: Task<Void, Never>?

    func fetchApps() {
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            updatingApps = true

            filteredApps.removeAll()
            apps.removeAll()

            do {
                let directoryContents = try FileManager.default
                    .contentsOfDirectory(at: AppsVM.appDirectory, includingPropertiesForKeys: nil, options: [])

                let subdirs = directoryContents.filter { $0.hasDirectoryPath }

                for sub in subdirs {
                    try Task.checkCancellation()
                    if sub.pathExtension.contains("app") &&
                        FileManager.default.fileExists(atPath: sub.appendingPathComponent("Info")
                                                                  .appendingPathExtension("plist")
                                                                  .path) {
                        let app = PlayApp(appUrl: sub)
                        print("Application installed:", sub.lastPathComponent)

                        apps.append(app)
                        if searchText.isEmpty || app.searchText.contains(searchText.lowercased()) {
                            filteredApps.append(app)
                        }
                    }
                }
            } catch is CancellationError {
                updatingApps = false
                return
            } catch {
                print(error)
            }

            filteredApps.sort(by: { $0.name.lowercased() < $1.name.lowercased() })

            do {
                if !FileManager.default.fileExists(atPath: PlayApp.bundleIDCacheURL.path),
                   let firstBundleID = apps.first?.info.bundleIdentifier {
                    try "\(firstBundleID)\n"
                        .write(to: PlayApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
                }

                var cachedBundleIDs = Set(try PlayApp.bundleIDCache)
                let cacheFile = try FileHandle(forUpdating: PlayApp.bundleIDCacheURL)
                defer { try? cacheFile.close() }
                try cacheFile.seekToEnd()

                for bundleId in apps.map({ $0.info.bundleIdentifier })
                    where !cachedBundleIDs.contains(bundleId) {
                    if let bundleID = "\(bundleId)\n".data(using: .utf8) {
                        try cacheFile.write(contentsOf: bundleID)
                        cachedBundleIDs.insert(bundleId)
                    }
                }
            } catch {
                Log.shared.error(error)
            }

            updatingApps = false
        }
    }
}
