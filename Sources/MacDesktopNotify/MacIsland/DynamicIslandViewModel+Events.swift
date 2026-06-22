import Cocoa
import Combine
import Foundation
import SwiftUI

extension DynamicIslandViewModel {
    func setupCancellables() {
        let events = EventMonitors.shared

        // 点击外部 → 关闭面板（点铃铛区域交给按钮 action，这里跳过）
        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard status == .panel else { return }
                let p = NSEvent.mouseLocation
                if !visibleContentRect.contains(p), !bellRect.contains(p) {
                    hide()
                }
            }
            .store(in: &cancellables)

        // Esc → 关闭面板
        events.keyDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyCode in
                guard let self, keyCode == 53 else { return }   // 53 = Esc
                if status == .panel { hide() }
            }
            .store(in: &cancellables)
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
