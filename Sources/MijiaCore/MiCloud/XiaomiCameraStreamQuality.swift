import Foundation

/// go2rtc `subtype` for a Xiaomi MISS stream.
///
/// `sd` is video quality 1, about 480p. `hd` is go2rtc's usual quality 2.
/// Several 4K models only put the top stream on numeric subtype 3, which `hd` does not select.
public enum XiaomiCameraStreamQuality: String, Codable, CaseIterable, Sendable, Equatable {
    case auto
    case sd
    case hd
    case max

    public static let storageDefault: XiaomiCameraStreamQuality = .hd

    public var subtypeQueryValue: String {
        switch self {
        case .auto: return "auto"
        case .sd: return "sd"
        case .hd: return "hd"
        case .max: return "3"
        }
    }
}
