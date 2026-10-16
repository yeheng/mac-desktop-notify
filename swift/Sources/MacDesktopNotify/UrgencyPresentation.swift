import SwiftUI

/// How an urgency level presents: tint, glyph, spoken label. The model file
/// keeps `UrgencyLevel` pure (it is decoded from wire data and persisted);
/// these display semantics belong beside the views that consume them — but
/// not inside any one view file, since the history window reads them too.
extension UrgencyLevel {
    var color: Color {
        switch self {
        case .low: .secondary
        case .normal: .blue
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .low: "circle.fill"
        case .normal: "sparkles"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .low: "低紧急度"
        case .normal: "普通紧急度"
        case .critical: "紧急"
        }
    }
}
