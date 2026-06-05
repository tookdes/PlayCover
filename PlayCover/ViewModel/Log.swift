//
//  Logger.swift
//  PlayCover
//

import Foundation
import SwiftUI

class Log: ObservableObject {

    static let shared = Log()

    func error(_ err: Error) {
        Task { @MainActor in
            self.dialog(
                question: NSLocalizedString("alert.error", comment: ""),
                text: err.localizedDescription,
                style: NSAlert.Style.critical)
        }
    }

    func error(_ str: String) {
        Task { @MainActor in
            self.dialog(
                question: NSLocalizedString("alert.error", comment: ""),
                text: str,
                style: NSAlert.Style.critical)
        }
    }

    func error(localized str: String, args: [String] = []) {
        error(String(format: NSLocalizedString(str, comment: ""), arguments: args))
    }

    func msg(_ msg: String) {
        Task { @MainActor in
            self.log(msg)
            self.dialog(
                question: NSLocalizedString("alert.success", comment: ""),
                text: msg,
                style: NSAlert.Style.informational)
        }
    }

    private let logQueue = DispatchQueue(label: "io.playcover.log")
    private(set) var logdata = "\(ProcessInfo.processInfo.operatingSystemVersionString)\n"

    func log(_ str: String, isError: Bool = false) {
        print(str)
        logQueue.sync {
            if isError {
                logdata.append("ERROR: ")
            }
            logdata.append(str)
            logdata.append("\n")
        }
    }

    private func dialog(question: String, text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
        alert.runModal()
    }

    required init() { }
}
