# HotReload Example

A minimal iOS app demonstrating HotReload with both UIKit and SwiftUI.

## Setup

1. Open `HotReloadExample/HotReloadExample.xcodeproj` in Xcode
2. Wait for SPM to resolve `HotReloadClient` package
3. Run the install script from the HotReload package root:
   ```bash
   cd ../../
   ./install.sh Example/HotReloadExample
   ```
4. Build and run on iOS Simulator (Debug configuration)

## Try It

- **UIKit**: Open `ExampleViewController.swift`, change the background color or label text, press Cmd+S
- **SwiftUI**: Open `ExampleSwiftUIView.swift`, change the text or colors, press Cmd+S

Changes are reflected instantly without rebuilding.
