#!/usr/bin/env swift
//
//  hot_reload.swift
//  HotReload Server
//
//  Usage:
//    swift Scripts/hot_reload.swift
//    (or auto-started via Build Phase)
//
//  How it works:
//    1. Reads per-module compiler flags cached by swiftc wrapper
//    2. Watches source directories for .swift file changes via FSEvents
//    3. UIKit: Recompiles entire module + ObjC method replacement
//    4. SwiftUI: Auto-generates @_dynamicReplacement wrapper + links debug.dylib
//

import Foundation
import CoreServices

setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - Configuration

let signalDir = "/tmp/HotReload-\(getuid())"
let signalFile = "\(signalDir)/latest.dylib"
let dylibDir = "\(signalDir)/dylibs"
let cacheDir = "\(signalDir)/swiftc_cache"
let buildSettingsFile = "\(signalDir)/build_settings.json"
let configFile = "\(signalDir)/hotreload.json"

let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let projectRoot: String = {
    if let data = FileManager.default.contents(atPath: buildSettingsFile),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
       let root = json["project_root"] {
        return root
    }
    return scriptPath.deletingLastPathComponent().path
}()

// MARK: - Logging

enum Log {
    static func info(_ msg: String)  { print("\u{001B}[0;34m[HotReload]\u{001B}[0m \(msg)") }
    static func ok(_ msg: String)    { print("\u{001B}[0;32m[HotReload]\u{001B}[0m \(msg)") }
    static func warn(_ msg: String)  { print("\u{001B}[1;33m[HotReload]\u{001B}[0m \(msg)") }
    static func error(_ msg: String) { print("\u{001B}[0;31m[HotReload]\u{001B}[0m \(msg)") }
}

// MARK: - Shell

struct ShellResult {
    let output: String
    let exitCode: Int32
    var success: Bool { exitCode == 0 }
}

// Cached swiftc path (resolved once on first access).
// Note: This global var uses lazy initialization (Swift default for globals).
// It calls shell() internally, which does NOT reference resolvedSwiftcPath,
// so there is no circular dependency. Be cautious if refactoring.
var resolvedSwiftcPath: String = {
    // 1. Build Phase-saved path
    let savedPath = "\(signalDir)/real_swiftc_path"
    if let path = try? String(contentsOfFile: savedPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       FileManager.default.fileExists(atPath: path) {
        Log.ok("swiftc: \(path) (from build settings)")
        return path
    }
    // 2. xcrun fallback
    let result = shell("xcrun --find swiftc").trimmingCharacters(in: .whitespacesAndNewlines)
    if !result.isEmpty && FileManager.default.fileExists(atPath: result) {
        Log.ok("swiftc: \(result) (from xcrun)")
        return result
    }
    // 3. Default
    Log.warn("swiftc: using default path")
    return "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
}()

// Error tracking
var consecutiveFailures = 0
let errorLogFile = "\(signalDir)/errors.log"

// Note: Currently safe as FSEvents callbacks run on main queue.
// If switching to concurrent queues in the future, synchronize file access.
func logError(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: errorLogFile) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: errorLogFile, contents: line.data(using: .utf8))
    }
}

@discardableResult
func shell(_ command: String) -> String {
    let result = shellWithStatus(command)
    return result.output
}

func shellWithStatus(_ command: String) -> ShellResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Log.error("Shell execution failed: \(error)")
        return ShellResult(output: "", exitCode: -1)
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return ShellResult(output: output, exitCode: process.terminationStatus)
}

// MARK: - Config

struct HotReloadConfig {
    var excludedModules: Set<String>
    var watchPaths: [String]

    static func load() -> HotReloadConfig {
        var config = HotReloadConfig(excludedModules: [], watchPaths: [])

        if let data = FileManager.default.contents(atPath: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let excluded = json["excludedModules"] as? [String] {
                config.excludedModules = Set(excluded)
            }
            if let paths = json["watchPaths"] as? [String] {
                config.watchPaths = paths
            }
        }

        if config.watchPaths.isEmpty {
            config.watchPaths = [projectRoot]
        }

        return config
    }
}

// MARK: - Module Name Resolution

func resolveModuleName(from sourceFile: String) -> String {
    // 1. Find module by checking SwiftFileList in cached args
    if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) {
        for file in files where file.hasSuffix(".args") {
            let moduleName = String(file.dropLast(5))
            let argsPath = "\(cacheDir)/\(file)"
            if let content = try? String(contentsOfFile: argsPath, encoding: .utf8) {
                for line in content.components(separatedBy: "\n") {
                    if line.hasPrefix("@") && line.contains("SwiftFileList") {
                        let listPath = String(line.dropFirst())
                        if let listContent = try? String(contentsOfFile: listPath, encoding: .utf8) {
                            if listContent.contains(sourceFile) {
                                return moduleName
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. Fallback: infer from directory structure
    let relative = sourceFile.replacingOccurrences(of: projectRoot + "/", with: "")
    let parts = relative.split(separator: "/").map(String.init)

    for (i, part) in parts.enumerated() {
        if part == "Sources" && i > 0 {
            return parts[i - 1]
        }
    }

    guard parts.count >= 3 else { return parts.first ?? "Unknown" }
    return parts[2]
}

// MARK: - Cached Args

func loadCachedArgs(for moduleName: String) -> [String]? {
    let argsFile = "\(cacheDir)/\(moduleName).args"
    guard let content = try? String(contentsOfFile: argsFile, encoding: .utf8) else {
        return nil
    }
    return content.components(separatedBy: "\n").filter { !$0.isEmpty }
}

// MARK: - Find debug.dylib

func findDebugDylib() -> String? {
    guard let data = FileManager.default.contents(atPath: buildSettingsFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let buildDir = json["build_dir"] else {
        return nil
    }

    let debugDir = "\(buildDir)/Debug-iphonesimulator"

    if let apps = try? FileManager.default.contentsOfDirectory(atPath: debugDir) {
        for app in apps where app.hasSuffix(".app") {
            let appPath = "\(debugDir)/\(app)"
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: appPath) {
                for file in contents where file.hasSuffix(".debug.dylib") {
                    return "\(appPath)/\(file)"
                }
            }
        }
    }

    return nil
}

// MARK: - SwiftUI View Detection (improved)

struct SwiftUIViewInfo {
    let structName: String
    let bodyCode: String
    let imports: [String]
}

/// Detects struct/extension declaration start
private let declStartPattern = try! NSRegularExpression(
    pattern: #"^(struct|extension)\s+(\w+)"#
)

/// Checks "View" as an independent token (excludes "ReviewList", "PreView", etc.)
private let viewTokenPattern = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z])View(?![A-Za-z])"#
)

func extractSwiftUIViews(from sourceFile: String) -> [SwiftUIViewInfo] {
    guard let content = try? String(contentsOfFile: sourceFile, encoding: .utf8) else {
        Log.error("Failed to read file: \(sourceFile)")
        return []
    }

    let lines = content.components(separatedBy: "\n")
    var results = [SwiftUIViewInfo]()
    let imports = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import ") }

    var i = 0
    while i < lines.count {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)

        if let match = declStartPattern.firstMatch(in: trimmed, range: nsRange),
           let kindRange = Range(match.range(at: 1), in: trimmed),
           let nameRange = Range(match.range(at: 2), in: trimmed) {

            let kind = String(trimmed[kindRange])
            let name = String(trimmed[nameRange])

            // Step 1: Collect full declaration up to opening brace (handles multi-line)
            let (declaration, braceLineIndex) = collectDeclaration(lines: lines, from: i)

            // Step 2: Check View conformance
            if conformsToView(declaration: declaration) {
                let searchStart = (kind == "extension") ? i : braceLineIndex
                if let bodyCode = findBodyProperty(lines: lines, from: searchStart) {
                    results.append(SwiftUIViewInfo(
                        structName: name,
                        bodyCode: bodyCode,
                        imports: imports
                    ))
                }
            }
        }
        i += 1
    }

    return results
}

/// Collects declaration text from start line to opening brace (up to 10 lines)
private func collectDeclaration(lines: [String], from startLine: Int) -> (String, Int) {
    var collected = ""
    var lineIndex = startLine

    for j in startLine..<min(startLine + 10, lines.count) {
        let line = lines[j]
        collected += " " + line.trimmingCharacters(in: .whitespaces)

        for char in line {
            if char == "{" {
                return (collected, j)
            }
        }
        lineIndex = j
    }

    return (collected, lineIndex)
}

/// Checks if declaration conforms to View protocol
private func conformsToView(declaration: String) -> Bool {
    guard let colonIndex = declaration.firstIndex(of: ":") else { return false }
    let afterColon = String(declaration[colonIndex...])
    let range = NSRange(afterColon.startIndex..., in: afterColon)
    return viewTokenPattern.firstMatch(in: afterColon, range: range) != nil
}

/// Searches for `var body: some View` from the given line
/// Searches for `var body: some View` within the current type scope.
/// Tracks brace depth to avoid matching body in nested structs.
private func findBodyProperty(lines: [String], from startLine: Int) -> String? {
    var braceDepth = 0
    var enteredScope = false

    for j in startLine..<lines.count {
        let line = lines[j]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Match body BEFORE brace counting (depth 1 = direct member of this type)
        if enteredScope && braceDepth == 1
            && trimmed.hasPrefix("var body:") && trimmed.contains("some View") {
            return extractBodyBlock(lines: lines, startLine: j)
        }

        for char in line {
            if char == "{" { braceDepth += 1; enteredScope = true }
            else if char == "}" { braceDepth -= 1 }
        }

        if enteredScope && braceDepth <= 0 { break }
    }
    return nil
}

/// Determines if a line is a top-level type declaration (search boundary)
private func isTopLevelDeclaration(_ line: String) -> Bool {
    ["struct ", "class ", "enum ", "extension ", "protocol "].contains(where: { line.hasPrefix($0) })
}

func extractBodyBlock(lines: [String], startLine: Int) -> String? {
    let firstLine = lines[startLine]
    guard firstLine.contains("{") else { return nil }

    var braceCount = 0
    var bodyLines = [String]()
    var started = false

    for i in startLine..<lines.count {
        let line = lines[i]
        for char in line {
            if char == "{" { braceCount += 1; if !started { started = true } }
            else if char == "}" { braceCount -= 1 }
        }
        if started { bodyLines.append(line) }
        if started && braceCount == 0 { break }
    }

    return bodyLines.isEmpty ? nil : bodyLines.joined(separator: "\n")
}

func generateReplacementSource(view: SwiftUIViewInfo, moduleName: String, sourceFileName: String) -> String {
    var source = ""
    source += "@_private(sourceFile: \"\(sourceFileName)\") import \(moduleName)\n"

    for imp in view.imports {
        let trimmed = imp.trimmingCharacters(in: .whitespaces)
        if !trimmed.contains(moduleName) {
            source += "\(trimmed)\n"
        }
    }

    source += "\n"
    source += "extension \(view.structName) {\n"
    source += "    @_dynamicReplacement(for: body)\n"
    let renamedBody = view.bodyCode.replacingOccurrences(of: "var body:", with: "var body_hotreload:")
    source += "    \(renamedBody)\n"
    source += "}\n"

    return source
}

// MARK: - Import Flags Extraction

func extractImportFlags(from args: [String]) -> [String] {
    var flags = [String]()
    var i = 0
    while i < args.count {
        let arg = args[i]
        if ["-I", "-F", "-Xcc", "-sdk", "-target", "-swift-version"].contains(arg) {
            flags.append(arg)
            if i + 1 < args.count { i += 1; flags.append(args[i]) }
        } else if arg.hasPrefix("-I") || arg.hasPrefix("-F") {
            flags.append(arg)
        }
        i += 1
    }
    return flags
}

// MARK: - Recompile

var config = HotReloadConfig.load()

func recompile(_ sourceFile: String) {
    let moduleName = resolveModuleName(from: sourceFile)
    let filename = URL(fileURLWithPath: sourceFile).lastPathComponent

    if config.excludedModules.contains(moduleName) {
        Log.warn("Skipped: \(filename) (\(moduleName) is excluded)")
        return
    }

    Log.info("Recompiling: \(filename) (module: \(moduleName))")

    let swiftUIViews = extractSwiftUIViews(from: sourceFile)

    if !swiftUIViews.isEmpty {
        recompileSwiftUI(sourceFile: sourceFile, views: swiftUIViews, moduleName: moduleName)
    } else {
        recompileUIKit(sourceFile: sourceFile, moduleName: moduleName)
    }
}

// MARK: - UIKit Recompile

func recompileUIKit(sourceFile: String, moduleName: String) {
    guard let originalArgs = loadCachedArgs(for: moduleName) else {
        Log.error("No cached flags for module '\(moduleName)'.")
        return
    }

    let swiftc = resolvedSwiftcPath
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let dylibPath = "\(dylibDir)/injection_\(timestamp).dylib"

    var args = [String]()
    var skipNext = false

    for arg in originalArgs {
        if skipNext { skipNext = false; continue }

        if ["-output-file-map", "-emit-module-path", "-emit-objc-header-path",
            "-emit-module-doc-path", "-emit-module-source-info-path",
            "-emit-abi-descriptor-path", "-index-store-path", "-index-unit-output-path",
            "-num-threads", "-emit-const-values-path",
            "-supplementary-output-file-map"].contains(arg) {
            skipNext = true; continue
        }

        if ["-whole-module-optimization", "-incremental", "-enable-batch-mode",
            "-serialize-diagnostics", "-emit-dependencies", "-parseable-output",
            "-use-frontend-parseable-output", "-save-temps", "-explicit-module-build",
            "-no-color-diagnostics", "-color-diagnostics",
            "-emit-module", "-emit-objc-header", "-c"].contains(arg) {
            continue
        }

        if arg.hasSuffix(".swift") && !arg.hasPrefix("-") && !arg.hasPrefix("@") { continue }
        if arg == "-o" { skipNext = true; continue }

        args.append(arg)
    }

    args.append("-emit-library")
    args.append("-o")
    args.append(dylibPath)

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: swiftc)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe

    do { try process.run(); process.waitUntilExit() }
    catch { Log.error("swiftc failed: \(error)"); return }

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: dylibPath) {
        Log.ok("UIKit compiled -> injection_\(timestamp).dylib")
        try? dylibPath.write(toFile: signalFile, atomically: true, encoding: .utf8)
        Log.ok("Injected!")
        consecutiveFailures = 0
        cleanupOldDylibs()
    } else {
        consecutiveFailures += 1
        let errors = output.components(separatedBy: "\n").filter { $0.contains("error:") }
        Log.error("UIKit compile failed (\(consecutiveFailures) consecutive):")
        errors.prefix(10).forEach { Log.error("  \($0)") }
        logError("UIKit compile failed for \(moduleName): \(errors.first ?? "unknown")")
    }
}

// MARK: - SwiftUI Recompile

func recompileSwiftUI(sourceFile: String, views: [SwiftUIViewInfo], moduleName: String) {
    guard let originalArgs = loadCachedArgs(for: moduleName) else {
        Log.error("No cached flags for module '\(moduleName)'.")
        return
    }

    guard let debugDylib = findDebugDylib() else {
        Log.error("*.debug.dylib not found. Run a Debug build first.")
        return
    }

    let filename = URL(fileURLWithPath: sourceFile).lastPathComponent

    for view in views {
        Log.info("Generating SwiftUI wrapper: \(view.structName)")

        let wrapperSource = generateReplacementSource(
            view: view, moduleName: moduleName, sourceFileName: filename
        )

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let wrapperFile = "\(signalDir)/wrapper_\(timestamp).swift"
        let dylibPath = "\(dylibDir)/replacement_\(timestamp).dylib"

        try? wrapperSource.write(toFile: wrapperFile, atomically: true, encoding: .utf8)

        let importFlags = extractImportFlags(from: originalArgs)
        let swiftc = resolvedSwiftcPath

        var args = [String]()
        args.append("-emit-library")
        args.append("-module-name")
        args.append("HotReloadReplacement")
        args += importFlags
        args.append(debugDylib)
        args.append("-Xfrontend")
        args.append("-enable-dynamic-replacement-chaining")
        args.append("-Xfrontend")
        args.append("-enable-private-imports")
        args.append("-Onone")
        args.append("-g")
        args.append("-o")
        args.append(dylibPath)
        args.append(wrapperFile)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: swiftc)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run(); process.waitUntilExit() }
        catch { Log.error("swiftc failed: \(error)"); continue }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: dylibPath) {
            Log.ok("SwiftUI compiled: \(view.structName) -> replacement_\(timestamp).dylib")
            try? dylibPath.write(toFile: signalFile, atomically: true, encoding: .utf8)
            Log.ok("Injected!")
            consecutiveFailures = 0
            cleanupOldDylibs()
        } else {
            consecutiveFailures += 1
            let errors = output.components(separatedBy: "\n").filter { $0.contains("error:") }
            Log.error("SwiftUI compile failed (\(view.structName), \(consecutiveFailures) consecutive):")
            errors.prefix(10).forEach { Log.error("  \($0)") }
            logError("SwiftUI compile failed for \(view.structName): \(errors.first ?? "unknown")")
        }

        try? FileManager.default.removeItem(atPath: wrapperFile)
    }
}

// MARK: - FSEvents File Watcher

class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let callback: (String) -> Void
    private var lastEventTime: [String: Date] = [:]

    init(paths: [String], callback: @escaping (String) -> Void) {
        self.paths = paths
        self.callback = callback
    }

    func start() {
        let cfPaths = paths as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            { (_, clientInfo, numEvents, eventPaths, _, _) in
                guard let info = clientInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                for i in 0..<numEvents {
                    let path = unsafeBitCast(CFArrayGetValueAtIndex(paths, i), to: CFString.self) as String
                    watcher.handleEvent(path: path)
                }
            },
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Log.error("Failed to create FSEventStream")
            return
        }

        self.stream = stream
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }

    private func handleEvent(path: String) {
        guard path.hasSuffix(".swift") else { return }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard !filename.hasPrefix("."), !filename.hasSuffix("~") else { return }
        guard !path.contains("DerivedData"), !path.contains(".build/"), !path.contains(".xcodeproj") else { return }

        let now = Date()
        if let last = lastEventTime[path], now.timeIntervalSince(last) < 0.5 { return }
        lastEventTime[path] = now

        callback(path)
    }
}

// MARK: - Main

/// Clean up old dylibs to prevent /tmp from growing indefinitely.
/// Keeps the most recent `maxKeep` dylibs and removes the rest.
func cleanupOldDylibs(maxKeep: Int = 20) {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dylibDir) else { return }

    let dylibs = files
        .filter { $0.hasSuffix(".dylib") }
        .map { "\(dylibDir)/\($0)" }
        .sorted { (a, b) in
            let attrA = try? FileManager.default.attributesOfItem(atPath: a)
            let attrB = try? FileManager.default.attributesOfItem(atPath: b)
            let dateA = attrA?[.modificationDate] as? Date ?? .distantPast
            let dateB = attrB?[.modificationDate] as? Date ?? .distantPast
            return dateA < dateB
        }

    if dylibs.count > maxKeep {
        let toRemove = dylibs.prefix(dylibs.count - maxKeep)
        for path in toRemove {
            try? FileManager.default.removeItem(atPath: path)
            // Also remove .dSYM if exists
            try? FileManager.default.removeItem(atPath: path + ".dSYM")
        }
        Log.info("Cleaned up \(toRemove.count) old dylibs")
    }
}

func main() {
    print("")
    print("\u{001B}[0;32m╔════════════════════════════════╗\u{001B}[0m")
    print("\u{001B}[0;32m║       HotReload Server         ║\u{001B}[0m")
    print("\u{001B}[0;32m╚════════════════════════════════╝\u{001B}[0m")
    print("")

    try? FileManager.default.createDirectory(atPath: signalDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: dylibDir, withIntermediateDirectories: true)

    // Clean up dylibs from previous sessions
    cleanupOldDylibs()

    if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) {
        let argsFiles = files.filter { $0.hasSuffix(".args") }
        Log.ok("swiftc flags cached: \(argsFiles.count) modules")
    } else {
        Log.warn("No swiftc flag cache found.")
        Log.warn("Run a Debug build in Xcode first.")
    }

    if findDebugDylib() != nil {
        Log.ok("debug.dylib found -> SwiftUI Hot Reload enabled")
    } else {
        Log.warn("debug.dylib not found -> SwiftUI Hot Reload disabled (UIKit only)")
    }

    if !config.excludedModules.isEmpty {
        Log.info("Excluded modules: \(config.excludedModules.sorted().joined(separator: ", "))")
    }

    print("")
    for path in config.watchPaths {
        Log.info("Watching: \(path)")
    }
    Log.info("Save a .swift file (Cmd+S) to trigger recompilation.")
    Log.info("Press Ctrl+C to stop.")
    print("")

    let watcher = FileWatcher(paths: config.watchPaths) { changedFile in
        recompile(changedFile)
    }

    signal(SIGINT) { _ in
        Log.info("Shutting down...")
        exit(0)
    }

    watcher.start()
    CFRunLoopRun()
}

main()