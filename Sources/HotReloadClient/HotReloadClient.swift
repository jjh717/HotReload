//
//  HotReloadClient.swift
//  HotReload
//
//  Hot Reload client for iOS Simulator only.
//  Only active in DEBUG + Simulator builds. Completely stripped in Release.
//
//  UIKit: Replaces class methods via ObjC runtime
//  SwiftUI: Replaces struct body via @_dynamicReplacement
//

#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import ObjectiveC
import MachO

public enum HotReloadClient {

    private static let signalDir = "/tmp/HotReload-\(getuid())"
    private static let signalFile = "\(signalDir)/latest.dylib"
    private static var source: DispatchSourceFileSystemObject?
    private static var fileDescriptor: Int32 = -1
    private static var lastContent = ""
    private static var loadedCount = 0

    /// Call from AppDelegate.didFinishLaunching
    public static func start() {
        do {
            try FileManager.default.createDirectory(atPath: signalDir,
                                                     withIntermediateDirectories: true)
        } catch {
            print("[HotReload] Failed to create directory: \(error)")
            return
        }

        if !FileManager.default.fileExists(atPath: signalFile) {
            FileManager.default.createFile(atPath: signalFile, contents: nil)
        }

        lastContent = (try? String(contentsOfFile: signalFile, encoding: .utf8)) ?? ""

        startWatching()

        print("[HotReload] Client started - watching \(signalFile)")
    }

    // MARK: - DispatchSource File Watching

    private static func startWatching() {
        fileDescriptor = open(signalFile, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[HotReload] Failed to open signal file: \(signalFile)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [source] in
            let event = source.data
            if event.contains(.delete) || event.contains(.rename) {
                // File was replaced (atomic write) - cancel triggers close via cancelHandler
                source.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startWatching()
                    checkForNewDylib()
                }
                return
            }
            checkForNewDylib()
        }

        let fd = fileDescriptor
        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
    }

    private static func checkForNewDylib() {
        guard let content = try? String(contentsOfFile: signalFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty,
              content != lastContent else {
            return
        }

        lastContent = content
        loadDylib(at: content)
    }

    // MARK: - dylib Loading

    private static func loadDylib(at path: String) {
        print("[HotReload] Loading: \(path)")

        guard dlopen(path, RTLD_NOW) != nil else {
            if let error = dlerror() {
                print("[HotReload] dlopen error: \(String(cString: error))")
            }
            return
        }

        loadedCount += 1
        print("[HotReload] dylib loaded (#\(loadedCount))")

        let isSwiftUIReplacement = path.contains("replacement_")

        if !isSwiftUIReplacement {
            replaceObjCMethods()
        }

        NotificationCenter.default.post(
            name: .hotReloadInjected,
            object: nil
        )

        if isSwiftUIReplacement {
            HotReloadObserver.shared.notify()
        }
    }

    // MARK: - ObjC Method Replacement (UIKit)

    private static let skipKeywords = [
        "Reducer", "Reactor", "Observable", "Coordinator", "Store", "HostingController"
    ]

    private static func replaceObjCMethods() {
        let imageCount = _dyld_image_count()
        let lastIndex = imageCount - 1
        guard let header = _dyld_get_image_header(lastIndex) else {
            print("[HotReload] Image header not found")
            return
        }

        if let imageName = _dyld_get_image_name(lastIndex) {
            print("[HotReload] Image: \(String(cString: imageName))")
        }

        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0

        var section: UnsafeMutablePointer<UInt8>?
        section = getsectiondata(header64, "__DATA", "__objc_classlist", &size)
        if section == nil || size == 0 {
            section = getsectiondata(header64, "__DATA_CONST", "__objc_classlist", &size)
        }

        guard let classListSection = section, size > 0 else { return }

        let count = Int(size) / MemoryLayout<UnsafeRawPointer>.size
        let classRefs = UnsafeBufferPointer(
            start: UnsafeRawPointer(classListSection).assumingMemoryBound(to: UInt.self),
            count: count
        )

        print("[HotReload] Found \(count) classes")

        for classRef in classRefs {
            let cls: AnyClass = unsafeBitCast(classRef, to: AnyClass.self)
            let name = String(cString: class_getName(cls))

            if skipKeywords.contains(where: { name.contains($0) }) { continue }

            guard let existingClass = objc_getClass(class_getName(cls)) as? AnyClass,
                  existingClass !== cls else { continue }

            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &methodCount) else { continue }
            defer { free(methods) }

            var replacedCount = 0
            for i in 0..<Int(methodCount) {
                let method = methods[i]
                let selector = method_getName(method)
                let imp = method_getImplementation(method)
                let typeEncoding = method_getTypeEncoding(method)

                if let existing = class_getInstanceMethod(existingClass, selector) {
                    method_setImplementation(existing, imp)
                    replacedCount += 1
                } else if let typeEncoding = typeEncoding {
                    class_addMethod(existingClass, selector, imp, typeEncoding)
                    replacedCount += 1
                }
            }

            if replacedCount > 0 {
                print("[HotReload] \(name): \(replacedCount) methods replaced")
            }
        }
    }

    public static func stop() {
        source?.cancel()
        source = nil
    }
}

// MARK: - Notification

public extension Notification.Name {
    static let hotReloadInjected = Notification.Name("HotReloadInjected")
}

// MARK: - SwiftUI Hot Reload Observer

import SwiftUI
import Combine

/// Add `@ObservedObject var _hotReload = HotReloadObserver.shared` to your SwiftUI View.
/// When hot reload triggers, this forces SwiftUI to re-evaluate body.
public final class HotReloadObserver: ObservableObject {
    public static let shared = HotReloadObserver()
    @Published public var version: Int = 0

    fileprivate func notify() {
        DispatchQueue.main.async {
            self.version += 1
            print("[HotReload] SwiftUI observer version: \(self.version)")
        }
    }
}

#endif