//
//  InjectView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import CocoaLumberjackSwift
import SwiftUI

struct InjectView: View {
    struct SuccessPayload {
        let logFileURL: URL?
        let didUseFallback: Bool
    }

    @EnvironmentObject var appList: AppListModel

    let app: App
    let urlList: [URL]
    let tempMode: Bool

    @State var injectResult: Result<SuccessPayload, Error>?
    @StateObject fileprivate var viewControllerHost = ViewControllerHost()

    @AppStorage var useWeakReference: Bool
    @AppStorage var preferMainExecutable: Bool
    @AppStorage var useFrameworkEnumerationFallback: Bool
    @AppStorage var injectStrategy: InjectorV3.Strategy

    init(_ app: App, urlList: [URL], tempMode: Bool = false) {
        self.app = app
        self.urlList = urlList
        self.tempMode = tempMode
        _useWeakReference = AppStorage(wrappedValue: true, "UseWeakReference-\(app.bid)")
        _preferMainExecutable = AppStorage(wrappedValue: false, "PreferMainExecutable-\(app.bid)")
        _useFrameworkEnumerationFallback = AppStorage(wrappedValue: true, "UseFrameworkEnumerationFallback-\(app.bid)")
        _injectStrategy = AppStorage(wrappedValue: .lexicographic, "InjectStrategy-\(app.bid)")
    }

    var body: some View {
        if appList.isSelectorMode {
            bodyContent
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(NSLocalizedString("Done", comment: "")) {
                            viewControllerHost.viewController?.navigationController?
                                .dismiss(animated: true)
                        }
                    }
                }
        } else {
            bodyContent
        }
    }

    var bodyContent: some View {
        VStack {
            if let injectResult {
                switch injectResult {
                case let .success(payload):
                    SuccessView(
                        title: NSLocalizedString("Completed", comment: ""),
                        subtitle: tempMode
                            ? NSLocalizedString("TempInjectSuccessHint", comment: "")
                            : payload.didUseFallback
                                ? NSLocalizedString("Completed with compatibility mode. The plug-in may start working after opening some app features.", comment: "")
                                : nil,
                        logFileURL: payload.logFileURL
                    )
                    .onAppear {
                        app.reload()
                    }
                case let .failure(error):
                    FailureView(
                        title: NSLocalizedString("Failed", comment: ""),
                        error: error
                    )
                    .onAppear {
                        app.reload()
                    }
                }
            } else {
                if #available(iOS 16, *) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .controlSize(.large)
                } else {
                    // Fallback on earlier versions
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .scaleEffect(2.0)
                }

                Text(NSLocalizedString("Injecting", comment: ""))
                    .font(.headline)
            }
        }
        .padding()
        .animation(.easeOut, value: injectResult == nil)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onViewWillAppear { viewController in
            viewController.navigationController?
                .view.isUserInteractionEnabled = false
            viewControllerHost.viewController = viewController
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = inject()

                DispatchQueue.main.async {
                    injectResult = result
                    app.reload()
                    viewControllerHost.viewController?.navigationController?
                        .view.isUserInteractionEnabled = true
                }
            }
        }
    }

    private func inject() -> Result<SuccessPayload, Error> {
        var logFileURL: URL?

        do {
            let injector = try InjectorV3(app.url)
            logFileURL = injector.latestLogFileURL

            if injector.appID.isEmpty {
                injector.appID = app.bid
            }

            if injector.teamID.isEmpty {
                injector.teamID = app.teamID
            }

            injector.useWeakReference = useWeakReference
            injector.preferMainExecutable = preferMainExecutable
            injector.useFrameworkEnumerationFallback = useFrameworkEnumerationFallback
            injector.injectStrategy = injectStrategy

            try injector.inject(urlList, shouldPersist: !tempMode)

            if tempMode {
                let manager = TempInjectManager.shared
                try manager.writeState(bid: app.bid, assetURLs: urlList)
                try manager.spawnWatchdog(bid: app.bid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [bid = app.bid] in
                    TempInjectManager.shared.launchApp(bid: bid)
                }
            }

            return .success(SuccessPayload(
                logFileURL: injector.latestLogFileURL,
                didUseFallback: injector.didUseMachOEnumerationFallback
            ))

        } catch {
            DDLogError("\(error)", ddlog: InjectorV3.main.logger)

            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: error.localizedDescription,
            ]

            if let logFileURL {
                userInfo[NSURLErrorKey] = logFileURL
            }

            let nsErr = NSError(domain: Constants.gErrorDomain, code: 0, userInfo: userInfo)

            return .failure(nsErr)
        }
    }
}

// MARK: - TempInject Manager

final class TempInjectManager {
    static let shared = TempInjectManager()

    private init() {}

    private var stateRootURL: URL { Constants.tempInjectRootURL }

    private func stateDirURL(for bid: String) -> URL {
        stateRootURL.appendingPathComponent(bid, isDirectory: true)
    }

    private func stateFileURL(for bid: String) -> URL {
        stateDirURL(for: bid).appendingPathComponent("state.json")
    }

    private func plugInListURL(for bid: String) -> URL {
        stateDirURL(for: bid).appendingPathComponent("plugins.list")
    }

    private struct TempEntry: Codable {
        let name: String
        let kind: String
    }

    /// Record the temporary injection session state, and remember the chosen
    /// plugin paths so that the next run can be one-tap.
    func writeState(bid: String, assetURLs: [URL]) throws {
        let fileManager = FileManager.default
        let dirURL = stateDirURL(for: bid)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let entries = assetURLs.map { url -> TempEntry in
            let ext = url.pathExtension.lowercased()
            let kind = (ext == "bundle" || ext == "framework") ? "bundle" : "dylib"
            return TempEntry(name: url.lastPathComponent, kind: kind)
        }
        let data = try JSONEncoder().encode(entries)
        try data.write(to: stateFileURL(for: bid), options: .atomic)

        let listContent = assetURLs.map { $0.path }.joined(separator: "\n")
        try listContent.write(to: plugInListURL(for: bid), atomically: true, encoding: .utf8)
    }

    /// Plugins remembered from the last temporary injection, for one-tap reuse.
    func recordedPluginURLs(bid: String) -> [URL] {
        let fileManager = FileManager.default
        guard let content = try? String(contentsOf: plugInListURL(for: bid), encoding: .utf8) else {
            return []
        }
        return content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Locate the trollfoolscli binary shipped inside our own .app bundle.
    static var cliBinaryURL: URL? {
        let fileManager = FileManager.default
        let ownBundleURL = Bundle.main.bundleURL.appendingPathComponent("trollfoolscli")
        if fileManager.isExecutableFile(atPath: ownBundleURL.path) {
            return ownBundleURL
        }
        if let proxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let bundleURL = proxy.bundleURL() {
            let url = bundleURL.appendingPathComponent("trollfoolscli")
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Spawn the detached watchdog (trollfoolscli watch). The watchdog survives
    /// even if this app is suspended or killed by the user.
    func spawnWatchdog(bid: String) throws {
        guard let cliURL = Self.cliBinaryURL else {
            throw NSError(
                domain: Constants.gErrorDomain, code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("TempInjectCLIMissing", comment: "")]
            )
        }
        killWatchdog(bid: bid)
        AuxiliaryExecute.spawn(
            command: cliURL.path,
            args: ["watch", bid],
            completionBlock: nil
        )
    }

    func killWatchdog(bid: String) {
        let pidFileURL = stateDirURL(for: bid).appendingPathComponent("watchdog.pid")
        guard let content = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 1 else {
            return
        }
        kill(pid, SIGKILL)
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Jump to the target app via SpringBoard.
    @discardableResult
    func launchApp(bid: String) -> Bool {
        LSApplicationWorkspace.default().openApplication(withBundleID: bid)
    }

    /// On app start: restore orphan sessions whose watchdog has died,
    /// so temporary injections never outlive their session.
    func cleanupOrphans() {
        let fileManager = FileManager.default
        guard let dirURLs = try? fileManager.contentsOfDirectory(
            at: stateRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }
        for dirURL in dirURLs {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let bid = dirURL.lastPathComponent

            // watchdog still alive? leave everything to it
            let pidFileURL = dirURL.appendingPathComponent("watchdog.pid")
            if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(trimmed), pid > 1, kill(pid, 0) == 0 {
                    continue
                }
            }

            // no session state? just clean the folder
            guard fileManager.fileExists(atPath: dirURL.appendingPathComponent("state.json").path) else {
                try? fileManager.removeItem(at: dirURL)
                continue
            }

            // watchdog died without restoring: restore synchronously via CLI
            if let cliURL = Self.cliBinaryURL {
                _ = AuxiliaryExecute.spawn(
                    command: cliURL.path,
                    args: ["watch", bid, "--timeout", "0"]
                )
            }
            try? fileManager.removeItem(at: dirURL)
        }
    }
}
