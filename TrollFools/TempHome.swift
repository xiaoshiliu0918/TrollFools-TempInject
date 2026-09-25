//
//  TempHome.swift
//  TrollFools
//
//  Minimal temp-injection launcher:
//  permanent plugin stash + one-tap game launch with auto inject & auto restore.
//

import SwiftUI
import CoreServices
import UniformTypeIdentifiers

// MARK: - Alert item (iOS 14 compatible)

struct TempAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Game Targets

struct GameTarget {
    let buttonTitle: String
    let emoji: String
    /// keywords matched against plugin file names in the stash
    let pluginKeywords: [String]
    /// keywords matched against installed app display names
    let appNameKeywords: [String]
    /// optional hard-coded bundle identifier (checked first)
    let fixedBundleID: String?

    static let wzry = GameTarget(
        buttonTitle: "启动王者荣耀",
        emoji: "👑",
        pluginKeywords: ["王者", "王者荣耀", "wzry", "smoba"],
        appNameKeywords: ["王者", "smoba"],
        fixedBundleID: "com.tencent.smoba"
    )

    static let dnf = GameTarget(
        buttonTitle: "启动地下城与勇士",
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
            includingPropertiesForKeys: [.isDirectoryKey]
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
    guard let info = CFBundleCopyInfoDictionaryForURL(bundleURL as CFURL) as? [String: Any],
          let execName = info["CFBundleExecutable"] as? String
    else { return }
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
    @Published var alertItem: TempAlertItem?

    /// Resolve target app: fixed bid first, then display-name match.
    private func resolveApp(_ target: GameTarget) -> (bid: String, url: URL)? {
        if let bid = target.fixedBundleID,
           let proxy = LSApplicationProxy(forIdentifier: bid),
           let url = proxy.bundleURL() {
            return (bid, url)
        }
        let installed = LSApplicationWorkspace.default().allApplications() ?? []
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
                self.finish(alertOnly: "未找到「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」对应的已安装 App，请确认游戏已安装。")
                return
            }
            let bid = targetApp.bid
            let bundleURL = targetApp.url

            // 2. resolve plugins
            let plugins = stash.plugins(matching: target.pluginKeywords)
            guard !plugins.isEmpty else {
                self.finish(alertOnly: "暂存箱中没有匹配「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」的插件。\n请先把对应的 dylib 放入暂存箱（文件名需包含“\(target.appNameKeywords.first ?? "")”）再试。")
                return
            }

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

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
                self.finish(success: "插件已加载，正在打开游戏。退出游戏后插件自动移除。")
            } catch {
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(alertOnly message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            self.alertItem = TempAlertItem(title: "提示", message: message)
        }
    }

    private func finish(success message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            self.alertItem = TempAlertItem(title: "完成", message: message)
        }
    }
}

// MARK: - Home View (three buttons only)

struct TempHomeView: View {

    @StateObject private var injector = GameInjector.shared

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("插件暂存箱")) {
                    NavigationLink(destination: StashView()) {
                        HStack {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(.orange)
                            Text("暂存箱")
                            Spacer()
                            Text("\(StashManager.shared.listPlugins().count) 个插件")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("启动游戏（自动加载暂存箱内对应插件）")) {
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
            .navigationTitle("游戏注入")
            .onAppear {
                TempInjectManager.shared.cleanupOrphans()
            }
            .alert(item: $injector.alertItem) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
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
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward.circle")
                    .foregroundColor(.secondary)
            }
        }
        .disabled(injector.isWorking)
    }
}

// MARK: - Stash Page (permanent storage)

struct StashView: View {

    @State private var plugins: [URL] = []
    @State private var isImporterPresented = false

    private let stash = StashManager.shared

    var body: some View {
        List {
            Section(
                header: Text("放置的 dylib 会永久保存在这里，直到你手动删除"),
                footer: Text("文件名包含「王者」→ 王者荣耀 ｜ 包含「地下城」或「DNF」→ 地下城与勇士")
            ) {
                if plugins.isEmpty {
                    Text("暂无插件，点击“添加插件”导入。")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(plugins, id: \.absoluteString) { url in
                        HStack {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(.orange)
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
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
        }
        .listStyle(.insetGrouped)
        .navigationTitle("暂存箱")
        .onAppear { reload() }
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

    private func reload() {
        plugins = stash.listPlugins()
    }
}
