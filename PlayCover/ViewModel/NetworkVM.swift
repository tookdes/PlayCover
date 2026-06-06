//
//  NetworkVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 09/10/2022.
//

import SystemConfiguration
import Foundation

class NetworkVM {
    static func isConnectedToNetwork() -> Bool {
        guard let flags = getFlags() else { return false }
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let result = (isReachable && !needsConnection)

        if !result {
            Task { @MainActor in
                if !ToastVM.shared.toasts.contains(where: { $0.toastType == .network }) {
                    ToastVM.shared.showToast(
                        toastType: .network,
                        toastDetails: NSLocalizedString("ipaLibrary.noNetworkConnection.toast", comment: "")
                    )
                }
            }
        }

        return result
    }

    static func getFlags() -> SCNetworkReachabilityFlags? {
        guard let reachability = ipv4Reachability() ?? ipv6Reachability() else { return nil }
        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(reachability, &flags) {
            return nil
        }
        return flags
    }

    static func ipv4Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }

    static func ipv6Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in6()
        zeroAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        zeroAddress.sin6_family = sa_family_t(AF_INET6)

        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }

    static func urlAccessible(url: URL,
                              popup: Bool = false,
                              completion: ((URL?, Bool) -> Void)? = nil) -> (URL?, Bool) {
        guard isConnectedToNetwork() else {
            completion?(nil, false)
            return (nil, false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        if let completion = completion {
            URLSession.shared.dataTask(with: request) { _, response, error in
                let (finalURL, available) = urlAccessibilityResult(response: response, error: error, popup: popup)
                completion(finalURL, available)
            }.resume()
            return (nil, false)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var acceptsResult = true
        var result: (URL?, Bool) = (nil, false)

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            lock.lock()
            let shouldAcceptResult = acceptsResult
            lock.unlock()
            guard shouldAcceptResult else {
                semaphore.signal()
                return
            }

            let nextResult = urlAccessibilityResult(response: response, error: error, popup: popup)
            lock.lock()
            if acceptsResult {
                result = nextResult
            }
            lock.unlock()
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + 30)
        lock.lock()
        if waitResult == .timedOut {
            acceptsResult = false
            lock.unlock()
            task.cancel()
            return (nil, false)
        }
        let finalResult = result
        lock.unlock()
        return finalResult
    }

    private static func urlAccessibilityResult(response: URLResponse?, error: Error?, popup: Bool) -> (URL?, Bool) {
        let validStatusCodes = [200, 301, 302, 303, 307, 308]

        if let error = error {
            if popup {
                Log.shared.error(error)
            } else {
                Log.shared.log(error.localizedDescription, isError: true)
            }
            return (nil, false)
        }

        if let httpResponse = response as? HTTPURLResponse {
            if validStatusCodes.contains(httpResponse.statusCode) {
                return (httpResponse.url, true)
            } else if popup {
                Log.shared.error("Unable to download: \(httpResponse.statusCode) " +
                                 "\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
            }
        }

        return (nil, false)
    }
}
