# SkalmanDiffKit

Native diff presentation shared by Skalman's Mac and iOS apps.

- `SkalmanDiffCore` owns immutable diff models, unified-diff parsing, syntax tokenization,
  hunk labels, totals, and large-diff expansion limits. It imports neither AppKit nor UIKit.
- `SkalmanDiffAppKit` renders numbered or compact line stacks for the Mac. The Mac app keeps
  repository access, staging, commit history, menus, and file-card interactions.
- `SkalmanDiffUIKit` renders a read-only diff with reusable `UICollectionView` cells. It owns
  file expansion, pull-to-refresh presentation, the floating summary, and the scroll-to-end
  affordance. The iOS app keeps remote transport and navigation.

SwiftUI may host the UIKit controller, but is intentionally not part of the rendering package.
That keeps large diffs on UIKit's reuse path and prevents the shared layer from absorbing
platform-specific git actions.
