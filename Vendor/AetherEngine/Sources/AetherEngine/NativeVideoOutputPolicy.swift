/// Whether native decoded-video outputs are safe for the source's Dolby Vision representation.
/// Profile 5 has no compatible base layer, and Profile 10 needs a known compatible base layer;
/// unknown profile metadata is treated conservatively. Other sources and DV profiles may use output.
enum NativeVideoOutputPolicy {
    static func allowsNativeVideoOutput(
        sourceVideoFormat: VideoFormat,
        dolbyVisionProfile: Int?,
        baseLayerCompatibilityID: Int?
    ) -> Bool {
        guard sourceVideoFormat == .dolbyVision else { return true }
        guard let dolbyVisionProfile else { return false }
        if dolbyVisionProfile == 5 { return false }
        if dolbyVisionProfile == 10 {
            return baseLayerCompatibilityID.map { $0 > 0 } == true
        }
        return true
    }
}
