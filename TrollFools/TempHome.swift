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

    /// Import one file into the stash. Returns the stored file name.
    /// Tries direct copy first, then byte-level read/write; collects all
    /// failure reasons so the caller can show exactly what went wrong.
    @discardableResult
    func importPlugin(from src: URL) throws -> String {
        ensureStash()
        let fm = FileManager.default
        let name = src.lastPathComponent
        let dst = Self.stashRootURL.appendingPathComponent(name)

        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
        }

        var reasons: [String] = []

        // Strategy 1: direct copy
        if !fm.fileExists(atPath: dst.path) {
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                reasons.append("copy:\(error.localizedDescription)")
            }
        }

        // Strategy 2: byte-level read then write
        if !fm.fileExists(atPath: dst.path) {
            do {
                let data = try Data(contentsOf: src)
                if data.isEmpty {
                    reasons.append("read:文件内容为空")
                } else {
                    try data.write(to: dst, options: .atomic)
                }
            } catch {
                reasons.append("read:\(error.localizedDescription)")
            }
        }

        // Verify
        guard fm.fileExists(atPath: dst.path) else {
            throw NSError(
                domain: "StashImport", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "所有方式均失败（\(reasons.joined(separator: "；"))）。源路径：\(src.path)"]
            )
        }
        return name
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

// MARK: - Import Engine (multi-channel, always visible on screen)

final class ImportEngine: ObservableObject {

    static let shared = ImportEngine()

    /// On-screen log lines, newest last. Rendered in the UI so results are
    /// always visible even if system alerts fail to present.
    @Published var logs: [String] = []
    @Published var notice: TempAlertItem?

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    func log(_ line: String) {
        DispatchQueue.main.async {
            self.logs.append("[\(self.stamp())] \(line)")
            if self.logs.count > 40 {
                self.logs.removeFirst(self.logs.count - 40)
            }
        }
    }

    /// Import a batch of files. Safe to call from anywhere.
    func importURLs(_ urls: [URL], source: String, showAlert: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var ok: [String] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let name = try StashManager.shared.importPlugin(from: url)
                    ok.append(name)
                } catch {
                    failures.append("\(url.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for name in ok {
                    self.log("✅ \(source)：已导入 \(name)")
                }
                for failure in failures {
                    self.log("❌ \(source)：\(failure)")
                }
                if showAlert {
                    if !failures.isEmpty {
                        self.notice = TempAlertItem(title: "导入失败", message: failures.joined(separator: "\n\n"))
                    } else if !ok.isEmpty {
                        self.notice = TempAlertItem(title: "已添加插件", message: ok.joined(separator: ", "))
                    }
                }
            }
        }
    }

    /// Files delivered via the share sheet land in our tmp/Inbox whether or
    /// not onOpenURL fires. Scan it and import everything found, then remove
    /// the sources so they are not imported twice.
    func scanInboxAndImport() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let inbox = fm.temporaryDirectory.appendingPathComponent("Inbox")
            guard let files = try? fm.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil
            ), !files.isEmpty else {
                return
            }
            var imported: [URL] = []
            for file in files {
                do {
                    _ = try StashManager.shared.importPlugin(from: file)
                    imported.append(file)
                } catch {
                    self.log("❌ Inbox：\(file.lastPathComponent) \(error.localizedDescription)")
                }
            }
            for url in imported {
                try? fm.removeItem(at: url)
            }
            if !imported.isEmpty {
                let names = imported.map { $0.lastPathComponent }.joined(separator: ", ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.log("✅ 共享接收：已导入 \(names)")
                    self.notice = TempAlertItem(title: "已添加插件", message: names)
                }
            }
        }
    }

    /// Root-level deep scan for *.dylib across well-known locations and all
    /// app data containers. Manual fallback that does not depend on the
    /// document picker or the share sheet at all.
    func deepScanAndImport() {
        log("🔍 全盘扫描开始…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let stashPath = StashManager.stashRootURL.path

            var roots: [String] = [
                fm.temporaryDirectory.path,
                "/var/mobile/Documents",
                "/var/mobile/Downloads",
                "/var/mobile/Inbox",
                "/var/mobile/Media",
            ]
            if let containers = try? fm.contentsOfDirectory(atPath: "/var/mobile/Containers/Data/Application") {
                for cid in containers {
                    roots.append("/var/mobile/Containers/Data/Application/\(cid)/Documents")
                    roots.append("/var/mobile/Containers/Data/Application/\(cid)/Downloads")
                    roots.append("/var/mobile/Containers/Data/Application/\(cid)/tmp")
                    roots.append("/var/mobile/Containers/Data/Application/\(cid)/Inbox")
                }
            }

            var found: [URL] = []
            for root in roots {
                guard fm.fileExists(atPath: root) else { continue }
                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isRegularFileKey]
                ) else { continue }
                for case let url as URL in enumerator {
                    let path = url.path
                    // skip our own stash
                    if path.hasPrefix(stashPath) { continue }
                    // limit depth to keep it fast
                    let rel = String(path.dropFirst(root.count + 1))
                    if rel.components(separatedBy: "/").count > 4 { enumerator.skipDescendants(); continue }
                    if url.pathExtension.lowercased() == "dylib" {
                        found.append(url)
                    }
                }
            }

            // deduplicate by file name
            var seen = Set<String>()
            let unique = found.filter { seen.insert($0.lastPathComponent).inserted }

            DispatchQueue.main.async {
                self.log("🔍 扫描完成，发现 \(unique.count) 个 dylib")
            }

            guard !unique.isEmpty else { return }
            var ok: [String] = []
            var failures: [String] = []
            for url in unique {
                do {
                    _ = try StashManager.shared.importPlugin(from: url)
                    ok.append(url.lastPathComponent)
                } catch {
                    failures.append("\(url.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for name in ok { self.log("✅ 扫描导入：\(name)") }
                for failure in failures { self.log("❌ 扫描导入：\(failure)") }
                if !ok.isEmpty {
                    self.notice = TempAlertItem(title: "扫描导入完成", message: "已导入：\n" + ok.joined(separator: "\n"))
                }
                if !failures.isEmpty {
                    self.notice = TempAlertItem(title: "部分失败", message: failures.joined(separator: "\n\n"))
                }
            }
        }
    }

    /// The user-visible import folder inside our own Documents, exposed via
    /// UIFileSharingEnabled so it shows up in the Files app
    /// (文件 App → 我的 iPhone → 石榴注入器 → 插件导入).
    static var importFolderURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("插件导入", isDirectory: true)
    }

    static func ensureImportFolder() {
        try? FileManager.default.createDirectory(
            at: importFolderURL, withIntermediateDirectories: true
        )
    }

    /// Move every file the user dropped into the Documents import folder into
    /// the permanent stash. Called automatically on every app foreground and
    /// stash page visit.
    func syncImportFolder() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            Self.ensureImportFolder()
            guard let files = try? fm.contentsOfDirectory(
                at: Self.importFolderURL, includingPropertiesForKeys: nil
            ), !files.isEmpty else {
                return
            }
            var imported: [String] = []
            for file in files {
                if file.lastPathComponent.hasPrefix(".") { continue }
                do {
                    _ = try StashManager.shared.importPlugin(from: file)
                    try? fm.removeItem(at: file)
                    imported.append(file.lastPathComponent)
                } catch {
                    self.log("❌ 导入文件夹：\(file.lastPathComponent) \(error.localizedDescription)")
                }
            }
            if !imported.isEmpty {
                let names = imported.joined(separator: ", ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.log("✅ 导入文件夹：已导入 \(names)")
                    self.notice = TempAlertItem(title: "已添加插件", message: names)
                }
            }
        }
    }

    /// Environment diagnostics, results written to the on-screen log.
    func runDiagnostics() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let stash = StashManager.stashRootURL

            self.log("🩺 诊断：uid=\(getuid())（0=root）")
            self.log("🩺 暂存目录：\(stash.path)")
            self.log("🩺 目录存在：\(fm.fileExists(atPath: stash.path))")

            let test = stash.appendingPathComponent(".diag-\(Int(Date().timeIntervalSince1970))")
            do {
                try Data("ok".utf8).write(to: test)
                try? fm.removeItem(at: test)
                self.log("🩺 暂存目录写入测试：✅")
            } catch {
                self.log("🩺 暂存目录写入测试：❌ \(error.localizedDescription)")
            }

            let inbox = fm.temporaryDirectory.appendingPathComponent("Inbox")
            let inboxFiles = (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
            self.log("🩺 Inbox(\(inbox.path))：\(inboxFiles.isEmpty ? "空" : inboxFiles.joined(separator: ", "))")

            let stashFiles = (try? fm.contentsOfDirectory(atPath: stash.path)) ?? []
            self.log("🩺 暂存箱内容：\(stashFiles.isEmpty ? "空" : stashFiles.joined(separator: ", "))")

            let folderFiles = (try? fm.contentsOfDirectory(atPath: ImportEngine.importFolderURL.path)) ?? []
            self.log("🩺 导入文件夹(\(ImportEngine.importFolderURL.path))：\(folderFiles.isEmpty ? "空" : folderFiles.joined(separator: ", "))")
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
        let engine = ImportEngine.shared
        engine.log("🚀 \(target.buttonTitle)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. resolve app
            guard let targetApp = self.resolveApp(target) else {
                engine.log("❌ 未找到已安装的目标 App")
                self.finish(alertOnly: "未找到「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」对应的已安装 App，请确认游戏已安装。")
                return
            }
            let bid = targetApp.bid
            let bundleURL = targetApp.url
            engine.log("🩺 目标 App：\(bid)")

            // 2. resolve plugins
            let plugins = stash.plugins(matching: target.pluginKeywords)
            guard !plugins.isEmpty else {
                engine.log("❌ 暂存箱无匹配插件（关键词：\(target.pluginKeywords.joined(separator: "/"))）")
                self.finish(alertOnly: "暂存箱中没有匹配「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」的插件。\n请先把对应的 dylib 放入暂存箱（文件名需包含“\(target.appNameKeywords.first ?? "")”）再试。")
                return
            }
            let names = plugins.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("💉 匹配到 \(plugins.count) 个插件：\(names)，开始注入…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

            // 3. kill the game if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 4. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 5. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                try manager.spawnWatchdog(bid: bid)
                engine.log("🐕 看门狗已启动（退出游戏后自动还原）")

                // 6. jump to the game
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开游戏")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开游戏")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开游戏。退出游戏后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(alertOnly message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "提示", message: message)
        }
    }

    private func finish(success message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "完成", message: message)
        }
    }
}

// MARK: - Home View (three buttons only)

struct TempHomeView: View {

    @StateObject private var injector = GameInjector.shared
    @ObservedObject private var engine = ImportEngine.shared
    @State private var stashCount = 0

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
                            Text("\(stashCount) 个插件")
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

                if !engine.logs.isEmpty {
                    Section(header: Text("运行日志")) {
                        ForEach(engine.logs.suffix(6), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("游戏注入")
            .onAppear {
                TempInjectManager.shared.cleanupOrphans()
                ImportEngine.shared.scanInboxAndImport()
                ImportEngine.shared.syncImportFolder()
                stashCount = StashManager.shared.listPlugins().count
            }
            .onChange(of: engine.logs.count) { _ in
                stashCount = StashManager.shared.listPlugins().count
            }
            .onOpenURL { url in
                // Receive files shared in from Files app / WeChat "open in" etc.
                ImportEngine.shared.log("📩 收到共享文件：\(url.lastPathComponent)")
                ImportEngine.shared.importURLs([url], source: "共享")
            }
            .alert(item: $engine.notice) { item in
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

    @ObservedObject private var engine = ImportEngine.shared
    @State private var plugins: [URL] = []
    @State private var isImporterPresented = false

    private let stash = StashManager.shared

    var body: some View {
        List {
            Section(
                header: Text("放置的 dylib 会永久保存在这里，直到你手动删除"),
                footer: Text("推荐导入方式：「文件」App → 我的 iPhone → 石榴注入器 → 插件导入，把 dylib 复制进去，回到本页自动收进暂存箱。\n文件名包含「王者」→ 王者荣耀 ｜ 包含「地下城」或「DNF」→ 地下城与勇士")
            ) {
                if plugins.isEmpty {
                    Text("暂无插件，试试下面的导入方式。")
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
            }

            Section(header: Text("导入")) {
                Button {
                    ImportEngine.shared.syncImportFolder()
                } label: {
                    Label("导入文件夹（推荐：文件 App 复制进来）", systemImage: "folder.badge.plus")
                }

                Button {
                    ImportEngine.shared.scanInboxAndImport()
                } label: {
                    Label("扫描共享收件箱", systemImage: "tray.and.arrow.down.fill")
                }

                Button {
                    isImporterPresented = true
                } label: {
                    Label("添加插件（文件选择）", systemImage: "plus.circle.fill")
                }

                Button {
                    ImportEngine.shared.deepScanAndImport()
                } label: {
                    Label("全盘扫描 dylib", systemImage: "magnifyingglass")
                }

                Button {
                    ImportEngine.shared.runDiagnostics()
                } label: {
                    Label("运行导入诊断", systemImage: "stethoscope")
                }
            }

            if !engine.logs.isEmpty {
                Section(header: Text("导入日志")) {
                    ForEach(engine.logs.suffix(10), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("暂存箱")
        .onAppear {
            reload()
            ImportEngine.shared.scanInboxAndImport()
            ImportEngine.shared.syncImportFolder()
        }
        .onChange(of: engine.logs.count) { _ in
            reload()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            isImporterPresented = false
            switch result {
            case let .success(urls):
                if urls.isEmpty {
                    ImportEngine.shared.log("⚠️ 文件选择：未选择任何文件")
                } else {
                    ImportEngine.shared.importURLs(urls, source: "文件选择")
                }
            case let .failure(error):
                ImportEngine.shared.log("❌ 文件选择：\(error.localizedDescription)")
                ImportEngine.shared.notice = TempAlertItem(title: "文件选择失败", message: error.localizedDescription)
            }
        }
        .alert(item: $engine.notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    private func reload() {
        plugins = stash.listPlugins()
    }
}
