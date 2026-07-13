import Foundation

public enum Style {
    case notch
    case floating
}

// MARK: - Enums ported from Atoll's enums/generic.swift
//
// Only the enums actually referenced by the ported island code are included.
// Atoll enums that back unported features (DownloadIndicatorStyle, MirrorShapeEnum,
// SliderColorEnum, lock-screen styles, etc.) are intentionally omitted.

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchViews {
    case home
    case shelf
    case timer
    case stats
    case llmUsage
    case colorPicker
    case notes
    case clipboard
    case terminal
    case extensionExperience
}

enum NotesLayoutState: Equatable {
    case list
    case split
    case editor

    var preferredHeight: CGFloat {
        switch self {
        case .list:  return 240
        case .split: return 260
        case .editor: return 320
        }
    }
}
