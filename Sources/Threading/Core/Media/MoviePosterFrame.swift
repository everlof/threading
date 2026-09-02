import AVFoundation
import CoreGraphics

/// The first frame a movie will give up, as a picture.
///
/// One answer for every surface that stands a still in for a movie: the attachments pane's
/// 26-point well, the composer's thumbnail above the text. The two asked the same question of
/// `AVAssetImageGenerator` with the same three settings, and a poster that came out on its side
/// in one place and upright in the other would be the settings drifting apart.
///
/// **Never on the main actor.** Extracting a frame opens a decoder, which is why a poster is
/// requested rather than read: the caller decides the priority the work runs at — a row scrolling
/// into view is `.utility`, a file the user just dropped is `.userInitiated` — and this only
/// promises to answer off the thread it was asked on.
enum MoviePosterFrame {

    /// How far into a movie a poster frame may be taken from.
    ///
    /// The first frame the decoder can give, not the first frame there is: asking for an exact
    /// time makes the generator decode forward from a keyframe, and a poster is not worth that.
    /// The tolerance runs forwards only, so a clip shorter than the window still answers with
    /// something inside itself.
    static let tolerance = CMTime(seconds: 1, preferredTimescale: 600)

    /// The poster, bounded to `maximumPixels` on its longer side, or nil for a file the platform
    /// cannot decode — which is how a name that ends in `.mov` is finally checked.
    static func extract(from url: URL, maximumPixels: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        // The rotation a recording stores rather than applies. Without this a portrait capture
        // arrives on its side, which at thumbnail size is exactly where nobody can tell that is
        // what happened.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixels, height: maximumPixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = tolerance
        return try? await generator.image(at: .zero).image
    }
}
