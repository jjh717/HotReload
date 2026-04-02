#!/usr/bin/env swift
//
// HotReload swiftc wrapper
// Xcode calls this binary instead of swiftc via SWIFT_EXEC.
// Caches compiler flags, then passes through to the real swiftc.
//

import Foundation

let signalDir = "/tmp/HotReload-\(getuid())"
let cacheDir = "\(signalDir)/swiftc_cache"

do {
    try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
} catch {
    fputs("[HotReload] Warning: Failed to create cache dir: \(error)\n", stderr)
}

let args = Array(CommandLine.arguments.dropFirst())

// Extract module name
var moduleName: String?
for (i, arg) in args.enumerated() {
    if arg == "-module-name" && i + 1 < args.count {
        moduleName = args[i + 1]
        break
    }
}

// Cache flags
if let moduleName = moduleName {
    let content = args.joined(separator: "\n")
    let filePath = "\(cacheDir)/\(moduleName).args"
    do {
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
    } catch {
        fputs("[HotReload] Warning: Failed to cache flags for \(moduleName): \(error)\n", stderr)
    }
}

// Find real swiftc - read from Build Phase-generated config, or derive from DEVELOPER_DIR
let swiftcPath: String = {
    // 1. Check if Build Phase saved the real swiftc path
    let savedPath = "\(signalDir)/real_swiftc_path"
    if let path = try? String(contentsOfFile: savedPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       FileManager.default.fileExists(atPath: path) {
        return path
    }

    // 2. Derive from DEVELOPER_DIR environment variable
    if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
        let path = "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }

    // 3. Fallback: standard Xcode path
    let fallback = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    if FileManager.default.fileExists(atPath: fallback) {
        return fallback
    }

    // 4. Last resort: try xcode-select
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["--print-path"]
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    if let devPath = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) {
        let path = "\(devPath)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }

    fputs("[HotReload] Error: Could not locate real swiftc\n", stderr)
    return fallback
}()

guard FileManager.default.fileExists(atPath: swiftcPath) else {
    fputs("[HotReload] Error: swiftc not found at \(swiftcPath)\n", stderr)
    exit(1)
}

// Execute real swiftc
let process = Process()
process.executableURL = URL(fileURLWithPath: swiftcPath)
process.arguments = args
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
    process.waitUntilExit()
} catch {
    fputs("[HotReload] Error: Failed to run swiftc: \(error)\n", stderr)
    exit(1)
}

exit(process.terminationStatus)