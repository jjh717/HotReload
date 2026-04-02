import SwiftUI

// MARK: - SwiftUI Hot Reload Example
//
// How to test:
//   1. Run this app on the iOS Simulator (Debug build)
//   2. Change the text, colors, or layout below
//   3. Press Cmd+S
//   4. The View body is replaced at runtime via @_dynamicReplacement
//
// No additional code is needed for SwiftUI. It works automatically.

struct ExampleSwiftUIView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("SwiftUI Hot Reload")
                .font(.title)
                .fontWeight(.bold)

            Text("Edit this view and press Cmd+S.\nChanges appear instantly.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ExampleSwiftUIView_Previews: PreviewProvider {
    static var previews: some View {
        ExampleSwiftUIView()
    }
}
#endif
