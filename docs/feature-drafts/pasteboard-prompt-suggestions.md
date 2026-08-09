# Pasteboard-aware prompt suggestions

> Status: feature draft — platform research and a candidate product contract are recorded here.
> Nothing is implemented or scheduled. The passive `changeCount` access assumption must be
> verified in a signed app on every supported pasteboard-privacy regime before implementation.

## Summary

When a person copies text, a link, a file, or a screenshot and returns to an agent-message
composer, offer one quiet, short-lived **Paste** action. The suggestion may say **Paste link**,
**Paste text**, or **Paste image file** only when macOS can establish that label without exposing
the pasteboard contents or showing a pasteboard-access alert. Otherwise it says **Paste
clipboard**.

The feature never previews, reads, stores, logs, or sends pasteboard content until the person
activates Paste. Activation must go through the ordinary AppKit paste action, synchronously from
the click or key event, so macOS recognizes it as user-originated paste access and the existing
`PromptView` path remains the only attachment/text insertion path.

The useful freshness signal is not a clipboard timestamp — macOS exposes none. It is an interval
derived by observing `NSPasteboard.general.changeCount` before and after an ownership change while
Threading is already running. If sampling was continuous, the change occurred inside that small
interval. If Threading launched later, woke from sleep, or missed a long interval, age is unknown
and the feature must not describe the contents as recent.

## User problem

Threading already handles the result of an intentional paste well:

- plain text enters the editor normally;
- file URLs become paths the agent can open;
- raw PNG/TIFF data is written to a temporary PNG first;
- agent-message composers show image paths as removable thumbnails and append their paths only to
  the submitted CLI value.

The missing part is discoverability at the moment the person returns from copying context. A raw
screenshot has no filesystem path, and the composer gives no indication that pasting it will
produce a real image attachment. A copied log, error, or paragraph is equally easy to forget while
switching back to the session.

This proposal is deliberately an affordance for a recent user action, not a clipboard manager.
Threading must not grow history, retain clipboard payloads, or watch what the user copies for later
analysis.

## Product contract

### Where it appears

The first version applies only to the two agent-message composers that already opt into image
attachments:

- the new-session brief in `SessionComposerViewController`;
- the native-conversation reply in `ConversationViewController`.

Do not add it to commit messages, inspector notes, report forms, terminal input, or secure fields.
`PromptView` is shared by those surfaces, and a paste suggestion there would falsely imply that
every use has agent attachment semantics.

### When it appears

Offer at most one suggestion when all of these are true:

1. An eligible agent-message composer is visible and receives focus.
2. The pasteboard ownership count differs from the last count already offered or dismissed.
3. Threading observed that change across a short, continuous sampling interval.
4. The observation is still inside a named freshness window.
5. The person has not typed, pasted, attached, sent, or dismissed the suggestion since focus.

An existing draft does not by itself suppress the offer. A common sequence is to write “Compare
this with the current layout,” copy a screenshot, and return to that draft. The first subsequent
edit does suppress it, keeping the prompt from carrying a persistent recommendation while the
person has chosen to continue writing.

Suggested initial values, to validate rather than silently hard-code:

| Value | Candidate | Reason |
| --- | ---: | --- |
| Sample interval | 1 second | Bounds an uninterrupted observation closely without frame-rate work |
| Maximum trustworthy sampling gap | 3 seconds | Tolerates ordinary timer coalescing but rejects sleep and long stalls |
| Suggestion freshness | 60 seconds | Covers copy-switch-compose without turning into clipboard history |
| Suggestions per ownership count | 1 | A dismissed clipboard item stays dismissed |

Do not show “Copied 4 seconds ago.” The system did not provide that fact. Freshness decides whether
to offer the action; it is not presented as an exact timestamp.

### What it says

Resolve the narrowest truthful label:

| Prompt-free result | Suggested action |
| --- | --- |
| File-reference content type conforms to image | **Paste image file** |
| File-reference content type, other | **Paste file** |
| Probable web URL or link pattern | **Paste link** |
| Probable web-search/text pattern | **Paste text** |
| Fresh ownership change, but no safe classification | **Paste clipboard** |

Do not infer “image” from private pasteboard types, enumerate representations, or retrieve pixels
to improve the label. In particular, the currently documented metadata API identifies the content
type of a **file reference**; it does not classify raw screenshot bytes. A raw screenshot therefore
normally receives the generic action.

Only request patterns that improve this prompt action. Email addresses, phone numbers, postal
addresses, calendar events, money, flights, and tracking numbers are supported by AppKit but add
privacy-shaped specificity without improving Paste. Do not ask for them.

### What activation does

The action invokes the standard paste command against the existing `PromptTextView` in the same
user event. It does not first retrieve a string, image, URL, or type and then manufacture a second
insertion path.

That preserves the existing behavior in `PromptTextView.readSelection(from:type:)`:

- `PromptAttachment.paths(from:)` gets first refusal for file URLs and PNG/TIFF image data;
- image-capable composers add thumbnail attachments;
- everything else falls through to `NSTextView`'s normal paste implementation.

The suggestion disappears whether the paste succeeds or the pasteboard no longer contains a
representation the composer can use. A stale asynchronous classification must never act on a new
`changeCount`.

## Research record

Research performed 2026-08-09 against Apple's current developer documentation, Xcode 26.5's
macOS 26.5 SDK, and the current Threading source tree.

### What `changeCount` means

Apple documents `NSPasteboard.changeCount` as an integer that increments each time pasteboard
ownership changes. Its documented purpose is comparing a recorded count with a later value to
determine whether an owner still owns the pasteboard.

It is not:

- a timestamp;
- a copy counter with one increment per Command-C;
- a notification stream;
- an identifier for the source app;
- a guarantee that the change was a deliberate user copy.

Clipboard managers, Universal Clipboard arrival, programmatic writes, and Threading's own copy
actions can all change ownership. Multiple ownership changes between samples collapse into one
observation. A count first seen after launch says nothing about how old its contents are.

There is no general-pasteboard change notification in the documented API, so estimating freshness
requires polling. Store the interval, not just its upper bound:

```swift
struct PasteboardChangeObservation: Equatable, Sendable {
    let changeCount: Int
    let after: Date       // previous successful sample
    let atOrBefore: Date  // sample that first saw the new count
}
```

If `atOrBefore.timeIntervalSince(after)` exceeds the trustworthy-gap limit, discard freshness.
Otherwise `atOrBefore` is a useful conservative observation time and `[after, atOrBefore]` is the
honest copy/change interval.

Apple's `changeCount` page does not explicitly use the “without notifying” guarantee that the new
detection APIs use. Reading an ownership counter does not retrieve item contents, but that alone
is not a sufficient release claim. Before implementation, verify in a signed, fresh-bundle-ID app
that sampling only `changeCount`:

- does not show a pasteboard-access notification;
- leaves `accessBehavior` at `.default` on macOS 15.4 and current macOS;
- continues at an acceptable cadence while Threading is inactive;
- exposes timer gaps across App Nap, sleep, wake, and debugger stalls honestly.

The command-line probe used during research was user-launched and is not evidence for an
application's passive behavior.

Primary reference: [Apple — `changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount).

### macOS 15.4 pasteboard access behavior

macOS 15.4 introduced per-app general-pasteboard access behavior:

- `.default`: programmatic access asks; before the first alert the app is absent from the System
  Settings list;
- `.ask`: the system asks before programmatic access;
- `.alwaysAllow`: programmatic access proceeds without an alert;
- `.alwaysDeny`: programmatic access is denied without an alert.

Apple explicitly states that access which is both user-originated and paste-related is allowed
without a notification even under `.ask` and `.alwaysDeny`. This is why the final read belongs in
the ordinary Paste action rather than an asynchronous “inspect, then insert” coordinator.

The proposal intentionally does not become more invasive under `.alwaysAllow`. A feature whose
behavior changes from generic to content-reading because of a global permission is harder to
explain and test. Passive classification uses only the no-notification APIs on every setting.

Primary reference: [Apple — `NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum).

### Detection without retrieving contents

Also in macOS 15.4, AppKit added two asynchronous APIs that Apple explicitly documents as not
notifying the person because they do not give the app the pasteboard item's contents:

- `detectedPatterns(for:)` returns which requested patterns match the first pasteboard item;
- `detectedMetadata(for:)` returns limited requested metadata for the first item.

The documented patterns are probable web URL, probable web search, number, links, phone numbers,
email addresses, postal addresses, calendar events, shipment tracking numbers, flight numbers,
and money amounts. The proposal needs only probable URL/link and probable search.

The only currently documented metadata payload is `contentType`, and only when the pasteboard
contains a file URL. It returns a `UTType`; it does not expose the file URL itself.

Both APIs inspect only the **first** pasteboard item. A multi-item copy can therefore be offered a
generic Paste action but cannot be completely classified without access.

Primary references:

- [Apple — `detectedPatterns(for:)`](https://developer.apple.com/documentation/appkit/nspasteboard/detectedpatterns(for:))
- [Apple — pasteboard detection patterns](https://developer.apple.com/documentation/appkit/nspasteboard-detection-patterns)
- [Apple — `detectedMetadata(for:)`](https://developer.apple.com/documentation/appkit/nspasteboard/detectedmetadata(for:))
- [Apple — pasteboard detection metadata](https://developer.apple.com/documentation/appkit/nspasteboard-detection-metadata-types)

### Calls that do retrieve or validate contents

`detectedValues(for:)` returns matched values rather than booleans. Apple explicitly says that if
it finds a match, the system informs the person that the app is trying to read pasteboard contents
and throws if access is denied. It is out of bounds for passive suggestions.

The older `types`, `pasteboardItems`, `availableType(from:)`, `canReadObject`, `string(forType:)`,
`data(forType:)`, and object-reading calls do not carry the new APIs' explicit no-notification
contract. Treat all of them as content access in the passive path. They remain appropriate inside
the user-originated Paste action, which is exactly where `PromptView` uses them today.

Primary reference: [Apple — `detectedValues(for:)`](https://developer.apple.com/documentation/appkit/nspasteboard/detectedvalues(for:)).

### Older supported macOS releases

Threading supports macOS 13+, while no-notification pattern and metadata detection begins at macOS
15.4. On macOS 13 through 15.3:

- freshness may still use `changeCount` if the prerequisite probe validates it for those systems;
- classification stays generic;
- activation still uses ordinary Paste.

Do not use older unprompted access behavior as permission to inspect contents. Keeping one product
contract across releases is easier to understand and protects people who upgrade in place.

### Existing Threading behavior

`Sources/Threading/UI/Design/PromptView.swift` already provides the complete insertion seam:

- `PromptTextView.readablePasteboardTypes` adds file URL, PNG, and TIFF;
- `readSelection(from:type:)` converts attachable content and otherwise calls `super`;
- `PromptAttachment.canRead` detects file URLs or PNG/TIFF for drag affordances;
- `PromptAttachment.paths` reads file URLs or writes raw image bytes to a temporary PNG;
- `PromptView.insertAttachments` shows valid images as thumbnails when
  `showsImageAttachments == true`, and inserts other paths literally.

Both agent-message owners set `showsImageAttachments = true`. Existing tests in
`PromptInputTests.swift` cover dropped files, raw image data, removable previews, image-only
submission, ordinary text editing, and both agent-message composers.

This means the proposed feature needs no new prompt transport, temporary-file policy, attachment
model, or CLI encoding. It only needs a freshness observation, privacy-safe optional
classification, a one-shot presentation value, and a route into the existing Paste action.

## Architecture direction

### Observation service

Add one application-owned `PasteboardChangeMonitor`, not one timer per composer. Its state is
transient and never persisted. It publishes a bounded value containing only:

- `changeCount`;
- previous and current sample times;
- whether Threading was active when the change was observed.

The monitor knows nothing about prompt text or pasteboard payloads. It starts only while at least
one eligible main-window composer can become visible and stops when no such window exists. It may
continue while Threading is inactive so the ordinary copy-in-another-app workflow remains
observable. Timer coalescing is measured through the sampling gap rather than hidden.

Changes first observed while Threading is active should be ineligible in version one. That cheaply
suppresses the many copy actions Threading itself performs and avoids offering content the person
just copied from one Threading surface back to another. If in-app copy suggestions later prove
valuable, centralize pasteboard writes so the monitor can mark them precisely instead of guessing
from the frontmost app.

### Classification coordinator

An injected `PasteboardSuggestionClassifier` receives an eligible observation. On macOS 15.4+ it
requests only:

- `detectedPatterns(for: [\.probableWebURL, \.links, \.probableWebSearch])`;
- `detectedMetadata(for: [\.contentType])`.

On older systems it returns `.generic`. Results carry the captured `changeCount`; the coordinator
discards them if the pasteboard changes, the composer loses eligibility, or a newer request wins.
Do not call `detectedValues`, enumerate types, or retrieve content.

### Composer presentation

Feature code resolves eligibility and hands `PromptView` a small value model such as:

```swift
struct PromptPasteSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case generic, text, link, file, imageFile }
    let changeCount: Int
    let kind: Kind
}
```

`PromptView` owns the visible suggestion and the standard Paste action because it owns the private
text view that must receive it. It does not own the monitor, clock, OS availability policy, or
classification task.

The exact placement needs rendered exploration. The likely component is one quiet, single-row
action inside the composer content stack, before the text or attachment rail, which disappears
without rebuilding the rest of the composer. It must use `UI/Design/` components, semantic theme
roles, keyboard focus, and an accessibility name such as “Paste recent clipboard contents.” It
must not automatically announce inferred clipboard type every time focus moves through the
window.

## Scaling gate

This proposal introduces polling, so frequency is the scaling axis even though cardinality is a
fixed one-item value.

Expected workload:

- one `changeCount` read per second while an eligible window exists;
- normally zero to a few ownership changes per minute;
- at most one classification pair per observed eligible count;
- at most one suggestion view per composer, with only one composer eligible for presentation.

Stress workload:

- a clipboard manager changes ownership ten times per second;
- the one-second sampler coalesces those changes into one observation;
- rapid focus/session changes race asynchronous classification;
- the Mac sleeps or the main thread stalls across a long sample gap.

Required complexity:

- sampling is O(1) and reads no representations;
- one change mutates one fixed value and at most one visible suggestion;
- no timer constructs views, decodes images, reads files, or rebuilds the composer;
- classification is once per observed count, cancellable, and stale-result checked;
- the monitor stops when no eligible window exists.

The implementation should include an opt-in timer stress fixture or deterministic fake clock. A
debounce is not a substitute for the one-sample/one-value bound.

## Privacy, honesty, and data boundaries

- Never persist clipboard content, detected values, UTIs, or history.
- Never log pasteboard text, URLs, file paths, bytes, hashes, or detected sensitive categories.
- Aggregate product telemetry, if ever added, may count suggestion shown/activated/dismissed by
  generic kind; it must not include content, source app, path, URL, or pasteboard count.
- Do not claim an exact copy time or source application.
- Do not request pasteboard access merely to improve a suggestion label.
- A denied or unavailable classification becomes generic or absent, never an error banner.
- Secure fields and non-agent prompts stay outside the feature.
- The suggestion is not a promise that Paste will succeed; pasteboard ownership may change between
  detection and activation.

## Rejected alternatives

### Read the item when the composer focuses

Rejected. It can show a macOS pasteboard-access alert before the person has asked to paste, exposes
potentially sensitive content, and duplicates the editor's correct user-originated path.

### Enumerate `types` and label PNG/TIFF as an image

Rejected for the passive path. Apple gives the detection APIs an explicit no-notification contract
that type enumeration does not have. Raw screenshots use the generic label.

### Use image metadata as a copy timestamp

Rejected. EXIF creation time describes the asset, not when it entered the pasteboard; screenshots
often omit it; and retrieving it already reads the content.

### Treat first observation after activation as “just copied”

Rejected. The contents could predate Threading's launch or a long sleep. A long sample gap means
unknown freshness.

### Poll only while Threading is active

Rejected for the intended workflow. The relevant copy normally happens while another app is
frontmost; first noticing it when Threading reactivates gives no useful interval.

### Keep clipboard history

Rejected. It changes the product and privacy boundary, creates persistence and retention work, and
is unnecessary for a one-shot prompt affordance.

### Build a second attachment insertion path

Rejected. `PromptView` already handles text, files, and raw images at the correct AppKit seam.

## Tests and verification

### Prerequisite platform probe

Use a signed probe app with a fresh bundle identifier on macOS 15.4 and the current release:

- read only `changeCount` on a timer and verify no alert/System Settings transition;
- repeat while inactive and under App Nap;
- copy text, a Finder file, and a raw screenshot from another app;
- record count/sample intervals, not payloads;
- sleep/wake and verify the gap becomes unknown;
- verify an ordinary button-triggered Paste remains allowed under `.ask` and `.alwaysDeny`.

If `changeCount` itself triggers access, abandon passive freshness polling. Fall back to a generic
Paste affordance tied only to explicit composer focus/user action; do not search for a private
clipboard-change channel.

### Unit behavior

- Freshness estimator: uninterrupted sample, boundary interval, long gap, launch, sleep, and clock
  injection.
- Coalescing: count jumps still yield one observation and one suggestion.
- Eligibility: active-app changes, stale counts, previously dismissed counts, existing draft,
  edit, attachment, submission, and focus loss.
- Classification: availability fallback, file image/non-image, link/text/generic precedence,
  errors, cancellation, and count changing before completion.
- Privacy spy: passive code may call only `changeCount`, `detectedPatterns`, and
  `detectedMetadata`; any call to content/type/value APIs fails the test.
- Paste routing: activation invokes the existing editor route once and preserves text/image/file
  behavior.

Use a uniquely named test pasteboard or an injected pasteboard interface. Tests must never spend
the developer's general clipboard. A new test file must be registered in `project.pbxproj` through
`scripts/add_test_file.py`.

### Render and accessibility

- Empty and existing-draft composers with each label kind.
- Session-start and conversation-reply layouts at the narrowest supported width.
- System plus two authored themes, live theme switching, Increase Contrast, and Reduce Motion.
- Keyboard traversal and activation; focus remains in the editor after paste.
- Accessible title/help and one-shot disappearance without repeated announcements.

### Performance

- Deterministic one-hour fake-clock run at the expected cadence.
- Ten ownership changes per second coalesced by a one-second sampler.
- Rapid composer/session focus churn with no retained classification tasks.
- Assert one monitor/timer application-wide and at most one suggestion mutation per sample.

## Rollout sequence

1. Run and preserve the signed platform-probe results in this research section.
2. Add the injectable observation model and deterministic freshness tests, without UI.
3. Add prompt-free classification with strict call-spy tests and availability fallback.
4. Render candidate suggestion placements in `PromptView`; choose the quietest layout that still
   makes screenshot attachment discoverable.
5. Add the user-originated Paste action and integration coverage through existing attachment code.
6. Ship behind a local experimental preference first; collect only aggregate
   shown/used/dismissed counts if measurement is needed.
7. Move durable behavior into `docs/architecture/design-system.md` and the relevant privacy or
   permissions architecture note when the feature ships, then remove this draft.

## Open questions

- Does a generic action help raw-screenshot discovery enough without naming it as an image?
- Should an existing draft retain the suggestion until its first subsequent edit, as proposed, or
  should any nonempty draft suppress it?
- Is 60 seconds the right freshness window, or does observed copy-to-focus behavior support a
  shorter value?
- Should changes while Threading is active stay permanently ineligible, or should a future
  centralized writer distinguish Threading-owned copies from other active-app changes?
- Does the suggestion belong above the editor, in the footer row, or as a transient action beside
  the placeholder at narrow widths?
