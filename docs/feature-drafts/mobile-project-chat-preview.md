# Three-chat project previews on iPhone

Implemented 2026-09-15. The durable behavior lives in [Remote Access](../REMOTE_ACCESS.md),
with the rendering boundary in [iOS themed dialogs](../IOS_THEMED_DIALOGS.md) and the measured
collection contract in [performance](../architecture/performance.md#mobile-remote-dashboard-scaling-contract).

The project overview shows three chats, preserving pins and recency order, with an inline
Show more (N)/Show fewer control. Hidden activity is summarized from live facts. Expansion is
phone-local navigation state; full project destinations and search keep all chats reachable.
Preview, whole-project fold and new-chat buttons share the existing light haptic.

## Research behind the choice

The supplied iPhone screenshot showed one project's history occupying nearly the entire screen.
[Nielsen Norman Group's progressive disclosure guidance](https://www.nngroup.com/articles/progressive-disclosure/)
supports a short primary view with an explicit route to secondary content. Applying that principle
to chat history is our design inference; the research does not prescribe a chat count. Three
follows the requested starting point and subsequent approval to implement the recommendation.
No comparative three-versus-five usability study was performed.

A single inline expansion preserves context and avoids repeated three-at-a-time taps. The
existing project title remains the route to a dedicated full list. The new control uses one
ordinary reusable row and the existing minimum tap target, consistent with
[Apple's accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

## Verification

The focused mobile run covers the preview, persistent project folding, existing dashboard
behavior and shared haptic delivery: 52 tests pass. The 1,000-chat scenario verifies bounded
mounted cells, stable expansion and return to the project after deep scrolling. Shipping-shell
captures belong to `ios-session-dashboard`; baseline approval remains a separate review.
Physical-device haptic feel and device animation/scroll tails remain unverified.
