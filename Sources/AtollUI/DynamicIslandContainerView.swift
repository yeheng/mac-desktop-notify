import SwiftUI

/// Placeholder content view shown inside the Dynamic Island window until the
/// integration task wires up the real MacDesktopNotify SwiftUI hierarchy.
struct DynamicIslandContainerView: View {
    @ObservedObject var vm: DynamicIslandViewModel

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(
                Text("Atoll screen ready")
                    .foregroundColor(.white)
            )
    }
}
