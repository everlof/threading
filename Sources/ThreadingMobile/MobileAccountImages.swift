import SwiftUI
import ThreadingRemoteKit
import UIKit

/// Catalogue images arrive once per account, never repeated in each session row.
@MainActor
final class MobileAccountImages: ObservableObject {
    static let shared = MobileAccountImages()
    @Published private(set) var revision = 0
    private let images = NSCache<NSString, UIImage>()
    private var pending: Set<String> = []
    private let worker = DispatchQueue(label: "codes.threading.mobile-account-images", qos: .utility)

    func image(_ id: String?) -> UIImage? {
        id.flatMap { images.object(forKey: $0 as NSString) }
    }

    func receive(_ catalog: RemoteNewSessionCatalogDTO?) {
        images.countLimit = 64
        var remaining = 64
        for agent in catalog?.agents ?? [] {
            for account in agent.accounts ?? [] {
                guard remaining > 0 else { return }
                var assets = account.images ?? [:]
                if let id = account.presentation?.imageID, let data = account.imagePNG { assets[id] = data }
                for (id, data) in assets {
                    guard remaining > 0 else { return }
                    guard data.count <= 32 * 1024, image(id) == nil,
                          pending.count < 64, pending.insert(id).inserted else { continue }
                    remaining -= 1
                    worker.async {
                    let image = UIImage(data: data)?.preparingForDisplay()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        pending.remove(id)
                        if let image {
                            images.setObject(image, forKey: id as NSString)
                            revision &+= 1
                        }
                    }
                    }
                }
            }
        }
    }
}

/// Shared glyph drawing for the picker and session chip. The Mac resolves every styling choice.
struct MobileResolvedAccountGlyph: View {
    let presentation: RemoteSessionAccountDTO
    var glyphSize: CGFloat = MobileDesign.Size.accountChipGlyph
    var emojiSize: CGFloat = MobileDesign.Size.accountChipEmoji
    @ObservedObject private var images = MobileAccountImages.shared

    var body: some View {
        if presentation.badgeHidden != true {
            ZStack {
                if let background = presentation.backgroundHex.flatMap(UIColor.init(remoteHex:)) {
                    Circle().fill(Color(uiColor: background))
                }
                if let image = images.image(presentation.imageID) {
                    Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
                } else {
                    Text(presentation.glyph)
                        .font(.system(size: presentation.isEmoji ? emojiSize : glyphSize, weight: .heavy))
                        .foregroundStyle(presentation.foregroundHex.flatMap(UIColor.init(remoteHex:))
                            .map { Color(uiColor: $0) } ?? Color.white)
                        .minimumScaleFactor(MobileDesign.Colour.accountChipMinimumScale)
                        .lineLimit(1)
                }
            }
        }
    }
}
