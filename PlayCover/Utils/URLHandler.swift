//
//  URIHandler.swift
//  PlayCover
//
//  Created by Venti on 14/02/2023.
//

import Foundation

enum URLTypes: Int, Equatable {
    case source
    case keymap
    case app
}

enum URLAction: Int, Equatable {
    case add
    case remove
    case update
    case install
    case open
}

@MainActor
class URLObservable: ObservableObject {
    @Published var url: String?
    @Published var type: URLTypes?
    @Published var action: URLAction?

    public static var shared = URLObservable()
}

struct URLHandler {
    public static var shared = URLHandler()

    @MainActor
    func processURL(url: URL) {
        if url.isFileURL && url.pathExtension.lowercased() == "ipa" {
            Installer.install(ipaUrl: url, export: false, returnCompletion: { _ in
                Task { @MainActor in
                    AppsVM.shared.fetchApps()
                    NotifyService.shared.notify(
                        NSLocalizedString("notification.appInstalled", comment: ""),
                        NSLocalizedString("notification.appInstalled.message", comment: "")
                    )
                }
            })
            return
        }

        // Validate URL scheme to prevent processing unexpected schemes
        guard url.scheme == "playcover" || url.scheme == "playcoverapp" else {
            NSLog("Rejected URL with unexpected scheme: \(url.scheme ?? "nil")")
            return
        }

        guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let uriHost = urlComponents.host,
              let params = urlComponents.queryItems else {
            NSLog("Unknown URL: \(url)")
            return
        }
        // URI format: playcoverapp://<object>?action=<action>&<param>=<value>
        // Example: playcoverapp://source?action=add&url=https://homebrew.playcover.io
        // Switch case for main uri path
        switch uriHost {
        case "source":
            processSourceURL(params: params)
        default:
            // Print URL to log and break
            NSLog("Unknown URL: \(url)")
        }
    }

    @MainActor
    func processSourceURL(params: [URLQueryItem]) {
        var paramValues: [String: String] = [:]
        for param in params {
            guard let value = param.value else { continue }
            paramValues[param.name] = value
        }

        guard let actionParam = paramValues["action"],
              let source = paramValues["url"],
              let sourceURL = URL(string: source),
              sourceURL.scheme == "https",
              sourceURL.host?.isEmpty == false else {
            // Print params to logs and break
            NSLog("Unknown source URL params: \(params)")
            return
        }

        let action: URLAction
        switch actionParam {
        case "add":
            action = .add
        case "remove":
            action = .remove
        case "update":
            action = .update
        default:
            NSLog("Unknown source URL params: \(params)")
            return
        }

        URLObservable.shared.type = .source
        URLObservable.shared.url = sourceURL.absoluteString
        URLObservable.shared.action = action
    }
}
