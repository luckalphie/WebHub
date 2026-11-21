import AppKit
import WebKit

/// 下载的生命周期独立于标签，关闭标签后仍能完成已开始的下载。
final class SiteDownloads: NSObject, WKDownloadDelegate {
    static let shared = SiteDownloads()

    private final class Transfer {
        let download: WKDownload
        weak var window: NSWindow?
        var destination: URL?

        init(download: WKDownload, window: NSWindow?) {
            self.download = download
            self.window = window
        }
    }

    private var transfers: [ObjectIdentifier: Transfer] = [:]

    func start(_ download: WKDownload, in window: NSWindow?) {
        transfers[ObjectIdentifier(download)] = Transfer(download: download, window: window)
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard let transfer = transfers[id] else { completionHandler(nil); return }
        do {
            let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let filename = (suggestedFilename as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            let destination = availableDestination(in: directory, filename: filename.isEmpty ? "Download" : filename)
            transfer.destination = destination
            completionHandler(destination)
        } catch {
            transfers.removeValue(forKey: id)
            completionHandler(nil)
            showFailure(in: transfer.window)
        }
    }

    private func availableDestination(in directory: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        let file = filename as NSString
        let ext = file.pathExtension
        let stem = file.deletingPathExtension
        let reserved = Set(transfers.values.compactMap(\.destination))
        var candidate = directory.appendingPathComponent(filename)
        var index = 2
        // WebKit 要求目标文件不存在，同时避免并发下载选中同一个文件名。
        while reserved.contains(candidate) || fileManager.fileExists(atPath: candidate.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            let numbered = "\(stem) \(index)"
            candidate = directory.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
            index += 1
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        transfers.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let transfer = transfers.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        NSLog("[WebHub] Download failed (%@, %ld)", failure.domain, failure.code)
        showFailure(in: transfer.window)
    }

    private func showFailure(in window: NSWindow?) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = WebHubLanguage.text("Download Failed")
        alert.addButton(withTitle: WebHubLanguage.text("OK"))
        alert.beginSheetModal(for: window)
    }
}
