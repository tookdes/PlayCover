//
//  GoogleDrive.swift
//  PlayCover
//
//  Created by Edoardo C. on 16/05/24.
//

import Foundation
import SwiftSoup

class RedirectHandler: NSObject, URLSessionTaskDelegate {
    private var finalURL: URL
    private var continuation: CheckedContinuation<Void, Never>?
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(url: URL) {
        self.finalURL = url
        super.init()
        if url.absoluteString.contains("drive.google.com") {
            if let myurl = self.convertGoogleDriveLink(url.absoluteString) {
                self.scrapeWebsite(from: URLRequest(url: myurl))
            }
        } else if url.absoluteString.contains("drive.usercontent.google.com") {
            self.scrapeWebsite(from: URLRequest(url: url))
        } else {
            self.redirectCatch(from: url)
        }
    }

    func getFinal() -> URL {
        return finalURL
    }

    /// Async wait for redirect resolution with timeout
    func resolve() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            // Check if all tasks are already done
            self.checkCompletion()
        }
    }

    private func checkCompletion() {
        // Use a short delay to allow pending callbacks to fire, then signal completion
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // Check if session has no outstanding tasks
            self.session.getTasksWithCompletionHandler { _, _, tasks in
                if tasks.isEmpty {
                    self.continuation?.resume()
                    self.continuation = nil
                } else {
                    // Wait a bit more and check again
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.session.getTasksWithCompletionHandler { _, _, tasks in
                            if tasks.isEmpty {
                                self?.continuation?.resume()
                                self?.continuation = nil
                            } else {
                                // Final timeout after 5 seconds total
                                DispatchQueue.global().asyncAfter(deadline: .now() + 4.4) { [weak self] in
                                    self?.continuation?.resume()
                                    self?.continuation = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func setFinal(url: URL) {
        self.finalURL = url
    }

    private func fetchGoogleDrivePageContent(url: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: url) else {
            completion(nil)
            return
        }
        let task = session.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                completion(nil)
                return
            }
            let htmlContent = String(data: data, encoding: .utf8)
            completion(htmlContent)
        }
        task.resume()
    }

    private func extractDownloadLink(from htmlContent: String) {
        do {
            let doc = try SwiftSoup.parse(htmlContent)
            guard let form = try doc.select("form#download-form").first() else {
                return
            }
            let action = try form.attr("action")
            let id = try form.select("input[name=id]").attr("value")
            let confirm = try form.select("input[name=confirm]").attr("value")
            let uuid = try form.select("input[name=uuid]").attr("value")
            let directDownloadLink = "\(action)?id=\(id)&confirm=\(confirm)&uuid=\(uuid)"
            let url = URL(string: directDownloadLink)
            if let url = url {
                setFinal(url: url)
            }
        } catch {
            return
        }
    }

    private func convertGoogleDriveLink(_ originalLink: String) -> URL? {
        guard let fileIdRange = originalLink.range(of: "/file/d/") else {
            return nil
        }
        let startIndex = fileIdRange.upperBound
        guard let endIndex = originalLink[startIndex...].firstIndex(of: "/") else {
            return nil
        }
        let fileId = originalLink[startIndex..<endIndex]
        let newLink = "https://drive.usercontent.google.com/download?id=\(fileId)&export=download&authuser=0"
        return URL(string: newLink)
    }

    private func redirectCatch(from url: URL) {
        let task = session.dataTask(with: url) { _, _, error in
            if error != nil {
                return
            }
        }
        task.resume()
    }

    private func scrapeWebsite(from request: URLRequest) {
        let task = session.dataTask(with: request) { data, _, error in
            if error != nil {
                return
            }
            if let data = data, let html = String(data: data, encoding: .utf8) {
                self.extractDownloadLink(from: html)
            }
        }
        task.resume()
    }

    // Handle redirects manually
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let redirectURL = request.url {
            if let url = self.convertGoogleDriveLink(redirectURL.absoluteString) {
                var newRequest = URLRequest(url: url)
                newRequest.httpMethod = "GET"
                newRequest.setValue("""
                Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)
                Chrome/124.0.0.0 Safari/537.36
                """, forHTTPHeaderField: "User-Agent")
                self.scrapeWebsite(from: newRequest)
                completionHandler(nil)
            } else {
                completionHandler(nil)
            }
        } else {
            completionHandler(nil)
        }
    }
}
