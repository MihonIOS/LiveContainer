//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

enum LCDownloadStatus: String, Codable {
    case downloading
    case paused
    case downloaded
    case installing
    case installed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .downloaded: return "Ready to install"
        case .installing: return "Installing"
        case .installed: return "Installed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isFinished: Bool {
        self == .installed || self == .failed || self == .cancelled
    }
}

struct LCDownloadItem: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    var displayName: String
    var status: LCDownloadStatus
    var downloadedSize: Int64
    var totalSize: Int64
    var resumeData: Data?
    var localFileName: String?
    var taskIdentifier: Int?
    var continuedTaskIdentifier: String?
    var errorDescription: String?
    var shouldAutoInstall: Bool
    let createdAt: Date
    var updatedAt: Date

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return min(max(Double(downloadedSize) / Double(totalSize), 0), 1)
    }
}

/// Owns all IPA downloads so their lifetime is independent of any SwiftUI view.
/// A stable background URLSession lets iOS continue transfers after suspension or
/// process termination. On iOS 26, each user-started transfer is also represented
/// by a BGContinuedProcessingTask, which provides the system Live Activity.
public final class DownloadHelper: NSObject, ObservableObject {
    static let shared = DownloadHelper()

    static let installReadyNotification = Notification.Name("LCDownloadedIPAReady")
    static let installRequestedNotification = Notification.Name("LCInstallDownloadedIPA")

    @Published private(set) var downloads: [LCDownloadItem] = []
    @Published private(set) var continuedProcessingError: String?

    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    private var pauseRequests = Set<UUID>()
    private var claimedInstallations = Set<UUID>()
    private var continuedTasks: [UUID: AnyObject] = [:]
    private var registeredContinuedTaskIdentifiers = Set<String>()
    private var lastPersistDates: [UUID: Date] = [:]
    private var lastContinuedTaskUpdateDates: [UUID: Date] = [:]
    private var lastProgressPublishDates: [UUID: Date] = [:]

    private let progressPublishInterval: TimeInterval = 0.1

    private let megabyteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = false
        return formatter
    }()

    private lazy var session: URLSession = {
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.kdt.LiveContainer").downloads"
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private var downloadsDirectory: URL {
        LCPath.docPath.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveContainer", isDirectory: true)
    }

    private var stateURL: URL {
        stateDirectory.appendingPathComponent("downloads.json")
    }

    private override init() {
        super.init()
        loadState()

        // An interrupted install can be offered again safely after launch.
        for index in downloads.indices where downloads[index].status == .installing {
            downloads[index].status = .downloaded
            downloads[index].shouldAutoInstall = true
        }
        for index in downloads.indices where downloads[index].status == .downloaded {
            if localURL(for: downloads[index]) == nil {
                downloads[index].status = .failed
                downloads[index].localFileName = nil
                downloads[index].errorDescription = "The downloaded file is missing. Tap Retry to download it again."
            }
        }
        for index in downloads.indices
        where downloads[index].status == .downloading || downloads[index].status == .paused {
            if !continuedTaskIdentifierMatchesCurrentBundle(downloads[index].continuedTaskIdentifier) {
                downloads[index].continuedTaskIdentifier = continuedTaskIdentifier()
            }
        }
        persistState()

        if #available(iOS 26.0, *) {
            for item in downloads where item.status == .downloading {
                registerContinuedProcessingHandler(for: item)
            }
        }
        restoreBackgroundTasks()
    }

    @discardableResult
    func enqueue(url: URL) throws -> UUID {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw NSError(
                domain: "LiveContainer.Downloads",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Only HTTP and HTTPS download URLs are supported."]
            )
        }

        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let id = UUID()
        let name = url.lastPathComponent.isEmpty ? "\(id.uuidString).ipa" : url.lastPathComponent
        let item = LCDownloadItem(
            id: id,
            sourceURL: url,
            displayName: name,
            status: .downloading,
            downloadedSize: 0,
            totalSize: 0,
            resumeData: nil,
            localFileName: nil,
            taskIdentifier: nil,
            continuedTaskIdentifier: continuedTaskIdentifier(),
            errorDescription: nil,
            shouldAutoInstall: true,
            createdAt: Date(),
            updatedAt: Date()
        )
        downloads.insert(item, at: 0)
        persistState()
        requestNotificationAuthorization()
        startDownload(id: id, resumeData: nil, submitContinuedTask: true)
        return id
    }

    func pause(id: UUID) {
        guard let index = index(of: id), downloads[index].status == .downloading else { return }
        guard let task = activeTasks[id] else {
            downloads[index].status = .paused
            downloads[index].updatedAt = Date()
            lastProgressPublishDates.removeValue(forKey: id)
            persistState()
            finishContinuedTask(id: id)
            return
        }

        pauseRequests.insert(id)
        downloads[index].status = .paused
        downloads[index].updatedAt = Date()
        lastProgressPublishDates.removeValue(forKey: id)
        persistState()
        finishContinuedTask(id: id)

        task.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                guard let self, let currentIndex = self.index(of: id) else { return }
                guard self.downloads[currentIndex].status == .paused else {
                    self.pauseRequests.remove(id)
                    return
                }
                self.downloads[currentIndex].resumeData = data
                self.downloads[currentIndex].taskIdentifier = nil
                self.activeTasks.removeValue(forKey: id)
                self.downloads[currentIndex].updatedAt = Date()
                self.pauseRequests.remove(id)
                self.persistState()
            }
        })
    }

    func resume(id: UUID) {
        guard let index = index(of: id), downloads[index].status == .paused,
              !pauseRequests.contains(id) else { return }
        let data = downloads[index].resumeData
        if data == nil {
            downloads[index].downloadedSize = 0
            downloads[index].totalSize = 0
        }
        downloads[index].status = .downloading
        downloads[index].errorDescription = nil
        downloads[index].continuedTaskIdentifier = continuedTaskIdentifier()
        downloads[index].updatedAt = Date()
        lastProgressPublishDates.removeValue(forKey: id)
        persistState()
        startDownload(id: id, resumeData: data, submitContinuedTask: true)
    }

    func cancel(id: UUID) {
        guard let index = index(of: id) else { return }
        downloads[index].status = .cancelled
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        removeLocalFile(for: downloads[index])
        downloads[index].resumeData = nil
        downloads[index].localFileName = nil
        downloads[index].taskIdentifier = nil
        downloads[index].errorDescription = nil
        downloads[index].updatedAt = Date()
        lastProgressPublishDates.removeValue(forKey: id)
        persistState()
        finishContinuedTask(id: id)
    }

    func retry(id: UUID) {
        guard let index = index(of: id) else { return }
        if localURL(for: downloads[index]) != nil {
            downloads[index].status = .downloaded
            downloads[index].shouldAutoInstall = true
            downloads[index].errorDescription = nil
            downloads[index].updatedAt = Date()
            persistState()
            requestNextInstallationIfPossible()
            return
        }

        downloads[index].status = .downloading
        downloads[index].downloadedSize = 0
        downloads[index].totalSize = 0
        downloads[index].resumeData = nil
        downloads[index].errorDescription = nil
        downloads[index].shouldAutoInstall = true
        downloads[index].continuedTaskIdentifier = continuedTaskIdentifier()
        downloads[index].updatedAt = Date()
        persistState()
        startDownload(id: id, resumeData: nil, submitContinuedTask: true)
    }

    func requestInstallation(id: UUID) {
        guard let index = index(of: id), localURL(for: downloads[index]) != nil else { return }
        downloads[index].status = .downloaded
        downloads[index].shouldAutoInstall = true
        downloads[index].errorDescription = nil
        downloads[index].updatedAt = Date()
        persistState()
        requestNextInstallationIfPossible()
    }

    func requestNextInstallationIfPossible() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard !downloads.contains(where: { $0.status == .installing }) else { return }
        guard let index = downloads.firstIndex(where: {
            $0.status == .downloaded && $0.shouldAutoInstall && localURL(for: $0) != nil
        }), let url = localURL(for: downloads[index]) else { return }

        let id = downloads[index].id
        downloads[index].status = .installing
        downloads[index].updatedAt = Date()
        persistState()
        NotificationCenter.default.post(
            name: Self.installReadyNotification,
            object: ["id": id, "url": url]
        )
    }

    func claimInstallation(id: UUID) -> Bool {
        guard let index = index(of: id), downloads[index].status == .installing,
              !claimedInstallations.contains(id) else { return false }
        claimedInstallations.insert(id)
        return true
    }

    func markInstallationSucceeded(id: UUID) {
        guard let index = index(of: id) else { return }
        claimedInstallations.remove(id)
        removeLocalFile(for: downloads[index])
        downloads[index].status = .installed
        downloads[index].localFileName = nil
        downloads[index].errorDescription = nil
        downloads[index].updatedAt = Date()
        persistState()
        DispatchQueue.main.async { [weak self] in self?.requestNextInstallationIfPossible() }
    }

    func markInstallationFailed(id: UUID, error: Error) {
        guard let index = index(of: id) else { return }
        claimedInstallations.remove(id)
        downloads[index].status = .failed
        downloads[index].errorDescription = error.localizedDescription
        downloads[index].updatedAt = Date()
        persistState()
        sendNotification(title: "Installation failed", body: downloads[index].displayName)
        DispatchQueue.main.async { [weak self] in self?.requestNextInstallationIfPossible() }
    }

    func deferInstallation(id: UUID) {
        guard let index = index(of: id) else { return }
        claimedInstallations.remove(id)
        downloads[index].status = .downloaded
        downloads[index].shouldAutoInstall = false
        downloads[index].updatedAt = Date()
        persistState()
        DispatchQueue.main.async { [weak self] in self?.requestNextInstallationIfPossible() }
    }

    func remove(id: UUID) {
        guard let index = index(of: id), downloads[index].status != .downloading && downloads[index].status != .installing else { return }
        removeLocalFile(for: downloads[index])
        downloads.remove(at: index)
        lastProgressPublishDates.removeValue(forKey: id)
        persistState()
    }

    func clearFinished() {
        let removable = downloads.filter { $0.status == .installed || $0.status == .cancelled }
        removable.forEach(removeLocalFile)
        removable.forEach { lastProgressPublishDates.removeValue(forKey: $0.id) }
        downloads.removeAll { $0.status == .installed || $0.status == .cancelled }
        persistState()
    }

    func setBackgroundEventsCompletionHandler(_ completionHandler: @escaping () -> Void) {
        backgroundEventsCompletionHandler = completionHandler
        _ = session
    }

    private func startDownload(id: UUID, resumeData: Data?, submitContinuedTask: Bool) {
        guard let index = index(of: id) else { return }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: downloads[index].sourceURL)
        }
        task.taskDescription = id.uuidString
        activeTasks[id] = task
        downloads[index].resumeData = nil
        downloads[index].taskIdentifier = task.taskIdentifier
        downloads[index].updatedAt = Date()
        persistState()
        task.resume()

        if submitContinuedTask, #available(iOS 26.0, *) {
            if registerContinuedProcessingHandler(for: downloads[index]) {
                submitContinuedProcessingTask(for: downloads[index])
            }
        }
    }

    private func restoreBackgroundTasks() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                let attachedIDs = Set(tasks.compactMap { task -> UUID? in
                    guard let description = task.taskDescription, let id = UUID(uuidString: description),
                          let index = self.index(of: id) else { return nil }
                    self.downloads[index].taskIdentifier = task.taskIdentifier
                    if let downloadTask = task as? URLSessionDownloadTask {
                        self.activeTasks[id] = downloadTask
                    }
                    return id
                })

                for index in self.downloads.indices where self.downloads[index].status == .downloading {
                    if !attachedIDs.contains(self.downloads[index].id) {
                        self.downloads[index].status = .paused
                        self.downloads[index].errorDescription = "Download was interrupted. Tap Resume to continue."
                        self.downloads[index].taskIdentifier = nil
                    }
                }
                self.persistState()
            }
        }
    }

    private func index(of id: UUID) -> Int? {
        downloads.firstIndex(where: { $0.id == id })
    }

    private func localURL(for item: LCDownloadItem) -> URL? {
        guard let fileName = item.localFileName else { return nil }
        let url = downloadsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func removeLocalFile(for item: LCDownloadItem) {
        guard let url = localURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode([LCDownloadItem].self, from: data) else { return }
        downloads = decoded
    }

    private func persistState() {
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(downloads)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("[LC] Failed to persist downloads: \(error)")
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func continuedTaskIdentifier() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kdt.LiveContainer"
        return "\(bundleID).download.\(UUID().uuidString)"
    }

    private func continuedTaskIdentifierMatchesCurrentBundle(_ identifier: String?) -> Bool {
        guard let identifier, let bundleID = Bundle.main.bundleIdentifier else { return false }
        return identifier.hasPrefix("\(bundleID).download.")
    }

    private func continuedTaskRegistrationError(identifier: String) -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let permittedPatterns = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String] ?? []
        let permitted = permittedPatterns.isEmpty ? "missing" : permittedPatterns.joined(separator: ", ")
        return "iOS rejected the Dynamic Island task registration. App ID: \(bundleID). Attempted: \(identifier). Permitted: \(permitted)"
    }

    @available(iOS 26.0, *)
    @discardableResult
    private func registerContinuedProcessingHandler(for item: LCDownloadItem) -> Bool {
        guard let identifier = item.continuedTaskIdentifier else { return false }
        if registeredContinuedTaskIdentifiers.contains(identifier) {
            return true
        }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleContinuedProcessingTask(continuedTask, downloadID: item.id)
        }
        if registered {
            registeredContinuedTaskIdentifiers.insert(identifier)
        } else {
            continuedProcessingError = continuedTaskRegistrationError(identifier: identifier)
        }
        return registered
    }

    @available(iOS 26.0, *)
    private func submitContinuedProcessingTask(for item: LCDownloadItem) {
        guard let identifier = item.continuedTaskIdentifier else { return }
        continuedProcessingError = nil
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Downloading \(item.displayName)",
            subtitle: continuedTaskSubtitle(for: item)
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            continuedProcessingError = "Dynamic Island task failed: \(error.localizedDescription)"
            NSLog("[LC] Could not start continued processing UI: \(error)")
        }
    }

    @available(iOS 26.0, *)
    private func handleContinuedProcessingTask(_ task: BGContinuedProcessingTask, downloadID: UUID) {
        guard let index = index(of: downloadID) else {
            task.setTaskCompleted(success: false)
            return
        }
        guard downloads[index].status == .downloading else {
            completeContinuedTask(task, for: downloads[index])
            return
        }
        continuedProcessingError = nil
        continuedTasks[downloadID] = task
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = Int64(downloads[index].progress * 1_000)
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.cancel(id: downloadID)
            }
        }
        updateContinuedTaskProgress(id: downloadID, forceUpdate: true)
    }

    private func continuedTaskSubtitle(for item: LCDownloadItem) -> String {
        let downloaded = megabyteFormatter.string(fromByteCount: max(item.downloadedSize, 0))
        guard item.totalSize > 0 else {
            return "\(downloaded) downloaded"
        }

        let total = megabyteFormatter.string(fromByteCount: item.totalSize)
        return "\(downloaded) / \(total)"
    }

    private func updateContinuedTaskProgress(id: UUID, forceUpdate: Bool = false) {
        guard #available(iOS 26.0, *),
              let index = index(of: id),
              let task = continuedTasks[id] as? BGContinuedProcessingTask else { return }

        let now = Date()
        guard forceUpdate ||
                now.timeIntervalSince(lastContinuedTaskUpdateDates[id] ?? .distantPast) >= 1 else {
            return
        }
        lastContinuedTaskUpdateDates[id] = now

        let item = downloads[index]
        task.progress.completedUnitCount = Int64(item.progress * 1_000)
        task.updateTitle(
            "Downloading \(item.displayName)",
            subtitle: continuedTaskSubtitle(for: item)
        )
    }

    private func continuedTaskTerminalPresentation(for item: LCDownloadItem) -> (
        title: String,
        subtitle: String,
        success: Bool
    ) {
        switch item.status {
        case .paused:
            return ("Download paused", continuedTaskSubtitle(for: item), false)
        case .failed:
            return ("Download failed", item.errorDescription ?? item.displayName, false)
        case .cancelled:
            return ("Download cancelled", item.displayName, false)
        case .downloaded, .installing, .installed:
            return ("Download complete", item.displayName, true)
        case .downloading:
            return ("Download stopped", continuedTaskSubtitle(for: item), false)
        }
    }

    @available(iOS 26.0, *)
    private func completeContinuedTask(_ task: BGContinuedProcessingTask, for item: LCDownloadItem) {
        let presentation = continuedTaskTerminalPresentation(for: item)
        task.updateTitle(presentation.title, subtitle: presentation.subtitle)
        task.setTaskCompleted(success: presentation.success)
    }

    private func finishContinuedTask(id: UUID) {
        lastContinuedTaskUpdateDates.removeValue(forKey: id)
        guard #available(iOS 26.0, *),
              let task = continuedTasks.removeValue(forKey: id) as? BGContinuedProcessingTask else { return }
        guard let index = index(of: id) else {
            task.setTaskCompleted(success: false)
            return
        }
        completeContinuedTask(task, for: downloads[index])
    }
}

extension DownloadHelper: URLSessionDownloadDelegate, URLSessionDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let description = downloadTask.taskDescription,
              let id = UUID(uuidString: description),
              let index = index(of: id), downloads[index].status == .downloading else { return }

        let now = Date()
        guard now.timeIntervalSince(lastProgressPublishDates[id] ?? .distantPast) >= progressPublishInterval else {
            return
        }
        lastProgressPublishDates[id] = now

        var item = downloads[index]
        item.downloadedSize = totalBytesWritten
        item.totalSize = max(totalBytesExpectedToWrite, 0)
        item.updatedAt = now
        downloads[index] = item
        updateContinuedTaskProgress(id: id)

        if now.timeIntervalSince(lastPersistDates[id] ?? .distantPast) >= 1 {
            lastPersistDates[id] = now
            persistState()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let id = UUID(uuidString: description),
              let index = index(of: id), downloads[index].status == .downloading else { return }

        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            failDownload(id: id, description: "HTTP Error: \(code)")
            return
        }

        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let suggestedName = response.suggestedFilename ?? downloads[index].displayName
            let storedName = "\(id.uuidString)-\(suggestedName)"
            let destination = downloadsDirectory.appendingPathComponent(storedName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            downloads[index].displayName = suggestedName
            downloads[index].status = .downloaded
            downloads[index].downloadedSize = max(downloads[index].downloadedSize, downloadTask.countOfBytesReceived)
            downloads[index].totalSize = max(downloads[index].totalSize, downloads[index].downloadedSize)
            downloads[index].localFileName = storedName
            downloads[index].taskIdentifier = nil
            activeTasks.removeValue(forKey: id)
            downloads[index].resumeData = nil
            downloads[index].errorDescription = nil
            downloads[index].updatedAt = Date()
            lastProgressPublishDates.removeValue(forKey: id)
            persistState()
            updateContinuedTaskProgress(id: id, forceUpdate: true)
            finishContinuedTask(id: id)
            sendNotification(title: "Download complete", body: suggestedName)
            requestNextInstallationIfPossible()
        } catch {
            failDownload(id: id, description: error.localizedDescription)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let description = task.taskDescription,
              let id = UUID(uuidString: description),
              !pauseRequests.contains(id),
              let index = index(of: id),
              downloads[index].status == .downloading else { return }
        failDownload(id: id, description: error.localizedDescription)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let completionHandler = backgroundEventsCompletionHandler else { return }
        backgroundEventsCompletionHandler = nil
        DispatchQueue.main.async(execute: completionHandler)
    }

    private func failDownload(id: UUID, description: String) {
        guard let index = index(of: id) else { return }
        downloads[index].status = .failed
        downloads[index].taskIdentifier = nil
        activeTasks.removeValue(forKey: id)
        downloads[index].errorDescription = description
        downloads[index].updatedAt = Date()
        lastProgressPublishDates.removeValue(forKey: id)
        persistState()
        finishContinuedTask(id: id)
        sendNotification(title: "Download failed", body: "\(downloads[index].displayName): \(description)")
    }
}

struct LCDownloadsView: View {
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let error = downloadHelper.continuedProcessingError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if downloadHelper.downloads.isEmpty {
                    Text("Downloads started from Sources will appear here.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(downloadHelper.downloads) { item in
                        LCDownloadRow(item: item)
                            .environmentObject(downloadHelper)
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.close".loc) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { downloadHelper.clearFinished() }
                        .disabled(!downloadHelper.downloads.contains(where: {
                            $0.status == .installed || $0.status == .cancelled
                        }))
                }
            }
        }
    }
}

private struct LCDownloadRow: View {
    @EnvironmentObject private var downloadHelper: DownloadHelper
    let item: LCDownloadItem

    private var byteDescription: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: item.downloadedSize)
        guard item.totalSize > 0 else { return downloaded }
        return "\(downloaded) / \(formatter.string(fromByteCount: item.totalSize))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayName)
                .font(.headline)
                .lineLimit(2)

            if item.status == .downloading || item.status == .paused {
                ProgressView(value: item.progress)
                Text(byteDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text(item.status.title)
                    .font(.subheadline)
                    .foregroundColor(item.status == .failed ? .red : .secondary)
                Spacer()
                controls
            }

            if let error = item.errorDescription, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var controls: some View {
        switch item.status {
        case .downloading:
            Button { downloadHelper.pause(id: item.id) } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) { downloadHelper.cancel(id: item.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        case .paused:
            Button { downloadHelper.resume(id: item.id) } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) { downloadHelper.cancel(id: item.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        case .downloaded:
            Button("Install") { downloadHelper.requestInstallation(id: item.id) }
                .buttonStyle(.borderless)
        case .failed, .cancelled:
            Button("Retry") { downloadHelper.retry(id: item.id) }
                .buttonStyle(.borderless)
            Button(role: .destructive) { downloadHelper.remove(id: item.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        case .installed:
            Button(role: .destructive) { downloadHelper.remove(id: item.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        case .installing:
            ProgressView()
        }
    }
}
