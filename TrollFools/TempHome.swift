//
//  TempHome.swift
//  TrollFools
//
//  Minimal temporary-injection home:
//  a plugin stash + per-game inject & launch buttons.
//

import SwiftUI
import CoreServices

// MARK: - Game Targets

private struct GameTarget {
    let buttonTitle: String
    let emoji: String
    /// keywords matched against plugin file names in the stash
    let pluginKeywords: [String]
    /// keywords matched against installed app display names
    let appNameKeywords: [String]
    /// optional hard-coded bundle identifier (checked first)
    let fixedBundleID: String?

    static let wzry = GameTarget(
        buttonTitle: "注入王者荣耀",
        emoji: "👑",
        pluginKeywords: ["王者", "王者荣耀", "wzry", "smoba"],
        appNameKeywords: ["王者", "smoba"],
        fixedBundleID: "com.tencent.smoba"
    )

    static let dnf = GameTarget(
        buttonTitle: "注入地下城",
        emoji: "⚔️",
        pluginKeywords: ["地下城", "dnf", "DNF"],
        appNameKeywords: ["地下城", "dnf", "DNF"],
        fixedBundleID: nil
    )
}

// MARK: - Stash

final class StashManager {
    static let shared = StashManager()

    static var stashRootURL: URL {
        URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Stash")
    }

    func ensureStash() {
        try? FileManager.default.createDirectory(
            at: Self.stashRootURL, withIntermediateDirectories: true
        )
    }

    /// All plugin files currently in the stash (dylib / framework / bundle).
    func listPlugins() -> [URL] {
        ensureStash()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Self.stashRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func importPlugin(from src: URL) throws {
        ensureStash()
        let dst = Self.stashRootURL.appendingPathComponent(src.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    func removePlugin(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Plugins whose file name contains any of the keywords.
    func plugins(matching keywords: [String]) -> [URL] {
        listPlugins().filter { url in
            let name = url.lastPathComponent.lowercased()
            return keywords.contains { name.contains($0.lowercased()) }
        }
    }
}

// MARK: - Process kill helper

private func killRunningApp(bid: String) {
    guard let proxy = LSApplicationProxy(forIdentifier: bid),
          let bundleURL = proxy.bundleURL()
    else { return }
    let execName: String
    if let exec = proxy.executableName {
        execName = exec
    } else {
        guard let info = CFBundleCopyInfoDictionaryForURL(bundleURL as CFURL) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String
        else { return }
        execName = name
    }
    // p_comm is truncated to 15 chars
    let comm = String(execName.prefix(15))
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return }
    let count = size / MemoryLayout<kinfo_proc>.stride
    for index in 0..<count {
        let name = withUnsafeBytes(of: procs[index].kp_proc.p_comm) { rawBuffer -> String in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return ""
            }
            return String(cString: base)
        }
        if name == comm {
            kill(procs[index].kp_proc.p_pid, SIGKILL)
        }
    }
}

// MARK: - Injector orchestration

final class GameInjector: ObservableObject {

    static let shared = GameInjector()

    @Published var isWorking = false
    @Published var statusText: String = ""
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""
    @Published var showAlert = false

    /// Resolve target app: fixed bid first, then display-name match.
    private func resolveApp(_ target: GameTarget) -> (bid: String, url: URL)? {
        if let bid = target.fixedBundleID,
           let proxy = LSApplicationProxy(forIdentifier: bid),
           let url = proxy.bundleURL() {
            return (bid, url)
        }
        let installed = LSApplicationWorkspace.default().allApplications()
        for kw in target.appNameKeywords {
            if let hit = installed.first(where: { proxy in
                (proxy.localizedName() ?? "").contains(kw) && proxy.bundleURL() != nil
            }) {
                guard let bid = hit.applicationIdentifier(), let url = hit.bundleURL() else { continue }
                return (bid, url)
            }
        }
        return nil
    }

    func injectAndLaunch(_ target: GameTarget, stash: StashManager = .shared) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. resolve app
            guard let targetApp = self.resolveApp(target) else {
                self.finish(alertOnly: "未找到「\(target.buttonTitle.replacingOccurrences(of: "注入", with: ""))」对应的已安装 App，请确认游戏已安装。")
                return
            }
            let bid = targetApp.bid
            let bundleURL = targetApp.url

            // 2. resolve plugins
            let plugins = stash.plugins(matching: target.pluginKeywords)
            guard !plugins.isEmpty else {
                self.finish(alertOnly: "暂存箱中没有命名匹配「\(target.buttonTitle.replacingOccurrences(of: "注入", with: ""))」的插件。\n请把 dylib 命名后放入暂存箱（例如文件名含“\(target.appNameKeywords.first ?? "")”）再试。")
                return
            }

            DispatchQueue.main.async { self.statusText = "正在注入 \(plugins.count) 个插件…" }

            // 3. kill the game if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 4. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)

                // 5. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                try manager.spawnWatchdog(bid: bid)

                // 6. jump to the game
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    manager.launchApp(bid: bid)
                }
                self.finish(success: "已注入 \(plugins.map { $0.lastPathComponent }.joined(separator: ", "))，正在打开游戏。退出游戏后插件会自动移除。")
            } catch {
                self.finish(alertOnly: "注入失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(alertOnly message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            self.alertTitle = "提示"
            self.alertMessage = message
            self.showAlert = true
        }
    }

    private func finish(success message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            self.alertTitle = "完成"
            self.alertMessage = message
            self.showAlert = true
        }
    }
}

// MARK: - Home View

struct TempHomeView: View {

    @StateObject private var injector = GameInjector.shared
    @State private var plugins: [URL] = []
    @State private var isImporterPresented = false

    private let stash = StashManager.shared

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("暂存箱（放入 dylib）")) {
                    if plugins.isEmpty {
                        Text("暂无插件，点击下方“添加插件”导入。")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    } else {
                        ForEach(plugins, id: \.absoluteString) { url in
                            HStack {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("王者 → 自动注入 ｜ 地下城 → 自动注入")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                stash.removePlugin(plugins[index])
                            }
                            reload()
                        }
                    }

                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("添加插件", systemImage: "plus.circle.fill")
                    }
                }

                Section(header: Text("动态注入（退出游戏自动还原）")) {
                    gameButton(.wzry)
                    gameButton(.dnf)
                }

                if injector.isWorking {
                    Section {
                        HStack {
                            ProgressView()
                            Text(injector.statusText)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("临时注入")
            .onAppear {
                TempInjectManager.shared.cleanupOrphans()
                reload()
            }
            .alert(injector.alertTitle, isPresented: $injector.showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(injector.alertMessage)
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    for url in urls {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try? stash.importPlugin(from: url)
                    }
                    reload()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func gameButton(_ target: GameTarget) -> some View {
        Button {
            injector.injectAndLaunch(target)
        } label: {
            HStack {
                Text(target.emoji)
                Text(target.buttonTitle)
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundColor(.secondary)
            }
        }
        .disabled(injector.isWorking)
    }

    private func reload() {
        plugins = stash.listPlugins()
    }
}
