//
//  CmdEject.swift
//  TrollFools
//
//  Created by Rachel on 10/3/2025.
//

import ArgumentParser
import Foundation

struct CmdEject: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "eject",
        abstract: "Eject plugins from the specified application."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: [.customLong("path"), .customShort("p")], help: "The path of the plugin.")
    var pluginPath: String?

    @Flag(name: [.customLong("all")], help: "Eject all plugins.")
    var ejectAll: Bool = false

    func validate() throws {
        if ejectAll && pluginPath != nil {
            throw ArgumentParser.ValidationError(
                "The --all flag and --path option cannot be used at the same time."
            )
        }
        if !ejectAll && pluginPath == nil {
            throw ArgumentParser.ValidationError(
                "Either --all flag or --path option must be specified."
            )
        }
    }

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }
        if let pluginPath {
            if let pluginURL = URL(string: pluginPath),
               FileManager.default.fileExists(atPath: pluginPath) {
                try InjectorV3(bundleURL, loggerType: .os).eject([pluginURL], shouldDesist: true)
            } else {
                throw ArgumentParser.ValidationError("The specified plugin path is invalid.")
            }
        } else if ejectAll {
            try InjectorV3(bundleURL, loggerType: .os).ejectAll(shouldDesist: true)
        } else {
            throw ArgumentParser.ValidationError("No plugin to eject.")
        }
    }
}

struct CmdWatch: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch the target app and restore it (eject temporary plugins) after it exits."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: .customLong("timeout"), help: "Seconds to wait for the app to be launched.")
    var launchTimeout: Int = 600

    @Flag(name: [.customLong("all")], help: "Eject all plugins instead of the temporary set.")
    var ejectAll: Bool = false

    private struct TempEntry: Codable {
        let name: String
        let kind: String
    }

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }

        let stateDirURL = Constants.tempInjectRootURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let pidFileURL = stateDirURL.appendingPathComponent("watchdog.pid")

        // Kill any previous watchdog of the same target to avoid duplicates.
        if let previousPID = Self.readPID(from: pidFileURL), previousPID > 1,
           previousPID != ProcessInfo.processInfo.processIdentifier {
            kill(previousPID, SIGKILL)
        }

        try FileManager.default.createDirectory(at: stateDirURL, withIntermediateDirectories: true)
        try String(ProcessInfo.processInfo.processIdentifier)
            .write(to: pidFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pidFileURL) }

        let executableName = Self.executableName(of: bundleURL)
        let commName = String(executableName.prefix(15)) // kernel p_comm limit

        // Phase 1: wait for the target app to be launched.
        var hasSeenLaunched = false
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, launchTimeout)))
        while Date() < deadline {
            if !Self.processes(matching: commName).isEmpty {
                hasSeenLaunched = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }

        // Phase 2: wait for the target app to exit.
        if hasSeenLaunched {
            while !Self.processes(matching: commName).isEmpty {
                Thread.sleep(forTimeInterval: 2)
            }
            Thread.sleep(forTimeInterval: 2) // grace period, let the system release the binary
        }

        // Phase 3: restore the app by ejecting what the temporary session injected.
        let injector = try InjectorV3(bundleURL, loggerType: .os)
        if injector.appID.isEmpty {
            injector.appID = bundleIdentifier
        }
        if injector.teamID.isEmpty {
            injector.teamID = app.teamID() ?? "0000000000"
        }

        let entries = Self.readTempEntries(bundleIdentifier)
        if !ejectAll, !entries.isEmpty {
            var assetURLs = [URL]()
            for entry in entries {
                switch entry.kind {
                case "bundle":
                    assetURLs.append(bundleURL.appendingPathComponent(entry.name))
                default:
                    assetURLs.append(injector.frameworksDirectoryURL.appendingPathComponent(entry.name))
                }
            }
            if !assetURLs.isEmpty {
                try injector.eject(assetURLs, shouldDesist: true)
            }
        } else {
            try injector.ejectAll(shouldDesist: true)
        }

        try? FileManager.default.removeItem(at: stateDirURL)
    }

    private static func executableName(of bundleURL: URL) -> String {
        let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOf: infoPlistURL),
           let name = dict["CFBundleExecutable"] as? String,
           !name.isEmpty {
            return name
        }
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    private static func processes(matching comm: String) -> [pid_t] {
        var size: size_t = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
            return []
        }
        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var result = [pid_t]()
        for index in 0..<actualCount {
            let name = withUnsafeBytes(of: procs[index].kp_proc.p_comm) { rawBuffer in
                String(cString: rawBuffer.bindMemory(to: CChar.self).baseAddress ?? UnsafePointer(""))
            }
            if name == comm {
                result.append(procs[index].kp_proc.p_pid)
            }
        }
        return result
    }

    private static func readPID(from url: URL) -> pid_t? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(trimmed)
    }

    private static func readTempEntries(_ bid: String) -> [TempEntry] {
        let stateFileURL = Constants.tempInjectRootURL
            .appendingPathComponent(bid, isDirectory: true)
            .appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateFileURL),
              let entries = try? JSONDecoder().decode([TempEntry].self, from: data)
        else {
            return []
        }
        return entries
    }
}
