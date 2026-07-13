import SwiftUI

/// Placeholder content view shown inside the Dynamic Island window until the
/// integration task wires up the real MacDesktopNotify SwiftUI hierarchy.
public struct DynamicIslandContainerView: View {
    @ObservedObject public var vm: DynamicIslandViewModel

    public init(vm: DynamicIslandViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(
                Text("Atoll screen ready")
                    .foregroundColor(.white)
            )
    }
}
