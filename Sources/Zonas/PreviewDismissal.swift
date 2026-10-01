import Foundation

/// Remove selection styling while the image is still opaque, then reveal the
/// activated window. A short neutral hold lets its live frame catch up to focus.
struct PreviewDismissal {
    static let effectsDuration: TimeInterval = 0.16
    static let neutralDuration: TimeInterval = 0.06
    static let pictureDuration: TimeInterval = 0.12
    static let activationDeadline: TimeInterval = 0.7

    struct Appearance {
        let effects: Double
        let picture: Double
        var isComplete: Bool { picture == 0 }
    }

    private var pictureBegan: TimeInterval?

    mutating func advance(elapsed: TimeInterval, windowIsReady: Bool) -> Appearance {
        let time = max(0, elapsed)
        let effects = max(0, 1 - time / Self.effectsDuration)
        if pictureBegan == nil, time >= Self.effectsDuration + Self.neutralDuration,
           windowIsReady || time >= Self.activationDeadline {
            pictureBegan = time
        }
        let picture = pictureBegan.map { max(0, 1 - (time - $0) / Self.pictureDuration) } ?? 1
        return Appearance(effects: effects, picture: picture)
    }
}
