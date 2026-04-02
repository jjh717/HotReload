# HotReload

Edit code → Cmd+S → Instantly reflected on iOS Simulator. No rebuild needed.

Zero external dependencies. Uses only built-in macOS/iOS APIs.

## Support

| | Supported | Method |
|---|---|---|
| **UIKit** (ViewController, UIView) | ✅ | ObjC runtime method replacement |
| **SwiftUI** (View body) | ✅ | Auto-generated `@_dynamicReplacement` |

## Installation

### 1. Add SPM Package

```swift
.package(url: "https://github.com/jjh717/HotReload", branch: "main")
```

Target dependency:
```swift
.product(name: "HotReloadClient", package: "HotReload")
```

### 2. Run Install Script

```bash
./install.sh /path/to/your/project
```

The script automatically:
- Detects project type (Tuist / Xcode / SPM)
- Compiles & installs swiftc wrapper (`/private/tmp/HotReload/swiftc`)
- Adds Debug-only xcconfig settings
- Installs Build Phase script

### 3. Add AppDelegate Code

```swift
#if DEBUG && targetEnvironment(simulator)
import HotReloadClient
#endif

func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
    // ...

    #if DEBUG && targetEnvironment(simulator)
    HotReloadClient.start()
    #endif

    return true
}
```

### 4. Build & Run

Debug build → Edit any `.swift` file → **Cmd+S** → Instantly reflected on Simulator!

## Usage

### UIKit

Add a Hot Reload observer to your base view controller for automatic support across all VCs:

```swift
#if DEBUG && targetEnvironment(simulator)
NotificationCenter.default.addObserver(
    self,
    selector: #selector(injected),
    name: Notification.Name("HotReloadInjected"),
    object: nil
)

@objc open func injected() {
    viewDidLoad()
}
#endif
```

Override `injected()` in individual VCs for custom UI refresh:

```swift
#if DEBUG && targetEnvironment(simulator)
override func injected() {
    view.subviews.forEach { $0.removeFromSuperview() }
    makeUI()
}
#endif
```

> **Note**: Methods changed by hot reload must be visible to the ObjC runtime. `private` methods without `@objc` use Swift static dispatch and won't be replaced. Add `@objc` to private methods you want to hot reload, or make them non-private.

### SwiftUI

Add one line to your SwiftUI View to enable hot reload:

```swift
#if DEBUG && targetEnvironment(simulator)
import HotReloadClient
#endif

struct MyView: View {
    #if DEBUG && targetEnvironment(simulator)
    @ObservedObject var _hotReload = HotReloadObserver.shared
    #endif

    var body: some View {
        // Edit and press Cmd+S
    }
}
```

`@_dynamicReplacement` replaces the body at runtime, and `HotReloadObserver` triggers SwiftUI to re-evaluate it.

## How It Works

### UIKit
1. FSEvents detects `.swift` file changes
2. Recompiles module using cached swiftc flags → `.dylib`
3. `dlopen()` loads the dylib into the running app
4. Extracts classes from Mach-O `__objc_classlist` section
5. `method_setImplementation()` replaces existing class methods
6. `HotReloadInjected` notification → `injected()` called

### SwiftUI
1. Detects `struct XXX: View` and extracts `var body: some View { ... }` code
2. Auto-generates `@_dynamicReplacement(for: body)` wrapper source
3. Compiles with `*.debug.dylib` linkage (ensures TX symbol is an external reference)
4. `dlopen()` → Swift runtime reads `__swift5_replace` section and auto-replaces body

### Key Technologies
- **swiftc wrapper**: Replaces Xcode's swiftc via `SWIFT_EXEC`, captures all module compiler flags automatically
- **`-enable-implicit-dynamic`**: Makes all functions `dynamic`, enabling `@_dynamicReplacement`
- **`*.debug.dylib` linkage**: TX symbols become undefined references (U), matching the original app binary

## Limitations

- **Simulator only**: `dlopen()` is not allowed on real devices (iOS security policy)
- **Method body changes only**: Adding/removing properties or changing function signatures requires a rebuild
- **State management classes**: Reducer/Reactor/Coordinator classes are auto-skipped to prevent crashes
- **`@_dynamicReplacement`**: Private Swift API, may change with Swift version updates
- **SwiftUI detection**: Handles `struct Name: View`, `struct Name<T>: View, Equatable`, `extension Name: View`, and multi-line declarations. Does not detect View conformance added via `typealias` or conditional conformance

## Configuration

Create `/tmp/HotReload/hotreload.json` (or `/tmp/HotReload-<your-uid>/hotreload.json`) to customize:

```json
{
    "excludedModules": ["MyInfraModule", "MyNetworkModule"],
    "watchPaths": ["/path/to/project/Sources"]
}
```

## Manual xcconfig Setup

If you prefer manual setup instead of the install script:

```xcconfig
// Debug only
SWIFT_USE_INTEGRATED_DRIVER[config=Debug]=NO
SWIFT_EXEC[config=Debug]=/private/tmp/HotReload/swiftc
OTHER_SWIFT_FLAGS[config=Debug]=$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports
OTHER_LDFLAGS[config=Debug]=$(inherited) -Xlinker -interposable
DEAD_CODE_STRIPPING[config=Debug]=NO
STRIP_SWIFT_SYMBOLS[config=Debug]=NO
```

## License

MIT