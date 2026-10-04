# Music-reactive theme signals

Themes can consume the selected app's output spectrum without owning an audio device. The
public seam is a cached set of scalar host signals, plus a native sidebar analyzer selected
by `sidebar.brand.analyzer: "audio"`. Both work across materials and window chromes. Choosing
the analyzer or publishing a Metal binding never turns on audio capture.

## Authority and permission

Motion settings owns **Music-reactive themes** (off by default), **Audio source**, the live
preview, and Retry. These controls are deliberately host-only. The source is either all
system output or a bundle identifier chosen from a bounded list of local audio processes.
All-system output includes calls and alerts; the row says so. An app source groups processes
with that exact bundle identifier. Helpers with a different identifier may need their own
selection. A selected source that disappears stays selected; capture never broadens to all
system audio as a recovery strategy.

macOS 14.2+ supplies the Core Audio process-tap API. A private, unmuted mono process tap feeds
a private, tap-only aggregate device with tap auto-start: no physical input device is added, no microphone is
opened, and normal playback is unchanged. `NSAudioCaptureUsageDescription` explains the local
analysis. The system asks for permission when recording starts, after the user has enabled
the feed and a visible consumer requests it. Merely opening Motion/Privacy settings or
listing audio sources does not request a grant. Privacy lists System Audio Recording as
asked when needed, because there is no public nonprompting status API for this grant.

There is no disk recording, transcription, network delivery, track metadata, device object,
source identity, or raw audio in the extension contract. Threading's own process is excluded
from the all-system mix. The opt-in HAL integration test deliberately taps only a controlled fixture app's
synthesized tone; it never taps personal playback or modifies the user's saved settings.

## Capture lifetime

`AudioSpectrumService` is the single authority. Capture requires both saved user consent
and at least one active `AudioSpectrumDemand` lease. Native analyzers and Metal surfaces with
audio inputs hold a lease only while visible, inside their viewport, and permitted by
`ThemeParticleHold`: Reduce Motion, Theme animations off, Low Power Mode, hidden/minimized/
occluded windows and hidden ancestors release demand. Enclosing clip views post bounds
changes, and demand checks intersect the view’s own bounds with its enclosing clips.
`NSView.visibleRect` alone can extend outside those bounds, so testing only whether it is
empty kept a scrolled-out preview active. Scrolling now releases it without a polling timer.

Disabling, changing sources, or releasing the last consumer immediately clears the public
reading, cancels the lifetime and drains its tap/device before a replacement starts. A
generation check rejects an old start or reading that finishes after cancellation. The
service retains the draining task through a quick disable/re-enable so two taps cannot
overlap. Lease destruction also releases demand.

Process identities, default output device and sample rate are rechecked every two seconds
on the capture actor. A vanished/replaced source clears readings, closes the old device,
and retries that same source every two seconds. Other errors enter the visible failed
state; Retry is explicit, so denial does not trigger a permission-request loop. Older macOS
versions disable the switch and show the OS requirement. An open device without delivered
samples enters `awaitingSamples`, with a visible source/permission hint; device creation alone
does not establish availability. Readings older than 250 ms are unavailable. Capturing
delivered silence is an available reading with all zero levels; unsupported, off, waiting,
awaiting samples, failed and stale capture are unavailable.

## Analysis and public vocabulary

One worker owns an Accelerate DFT over a 2,048-sample Hann window. It derives RMS loudness
and eight fixed frequency ranges: 20–80, 80–200, 200–500, 500–1,200, 1,200–3,000,
3,000–6,000, 6,000–12,000 and 12,000–20,000 Hz. Bands above Nyquist are zero. Levels map
the absolute −60…0 dBFS display range to `0…1`, with 40 ms attack and 180 ms release.
Silence is never peak-normalized into full-scale movement. These are visual spectrum
readings, not equalizer gain controls or a beat/BPM detector.

`ExtensionHostSignal` publishes `audio.available` (0/1), `audio.level`, `audio.bass`,
`audio.mids`, `audio.treble` and `audio.band.0` through `.7`. Bass averages bands 0–1,
mids 2–4, and treble 5–7. All level signals are optional normalized scalars; their binding
fallback applies when unavailable. An available silent reading resolves to zero. The
existing Metal ABI has eight inputs, so a surface can bind all bands or a subset with
aggregate levels. `ExtensionHostSignals` reads memory only; no draw-time HAL call or IPC.

`AudioSpectrumView` lives in the Design kit and draws eight columns of six cells using theme
surface/accent tokens. The native analyzer replaces the brand's logo/title when explicitly
selected; it never pretends missing audio is agent work. Absent `analyzer` preserves the
material's existing behavior, including Classic Player's workload analyzer. MCP create/
update tools use `sidebar.analyzer: "audio"`, `"workload"`, or `"default"` (clear the override).
The Wasm `MusicSpectrumExtension` example binds all eight bands beneath the sidebar, with
zero fallback and no autonomous clock animation.

## The person's reaction strength

Settings ▸ Motion ▸ **Reaction strength** (0–200 %, `ThemeReactions`) scales every audio level
and band where it enters decoration — the native spectrum's bars and each extension input bound
to a reactive `audio.*` signal — before the extension's own mapping. `audio.available` is a fact
and passes through. The scale never requests capture and never changes the reading the service
publishes; at 0 % decoration simply answers silence. See [`themes.md`](themes.md) (2026-10-04).

## Scaling and verification

Expected size is one or a few visible consumers and tens of audio processes; stress bounds
are 256 process objects, 32 listed app sources, eight channels/buffers, and 4,096 copied
frames per callback. Larger process inventories fail closed instead of allocating an
unbounded list. The callback uses a preallocated 2,048-float ring and a nonblocking lock;
it drops a callback when the worker owns the ring. It performs no FFT, allocation, HAL
query, file access, logging, notification or actor hop. One background analysis/publication
loop is capped at 30 Hz regardless of callback frequency or consumer count. Main-actor
work is bounded snapshot publication and painting visible consumers; there is no timer per
native analyzer and no high-frequency extension-process traffic.

`AudioSpectrumTests` covers tone-to-band accuracy, silence/noise, nonfinite input, smoothing,
Nyquist limits, stereo downmix/ring bounds and a 900-snapshot budget. Service tests exercise
consent/demand independence, shared ownership, stale readings, pending-start source replacement,
immediate disable, unsupported platforms and explicit error retry. Presentation tests drive
scroll/hide/motion lifetime, native JSON/tool round trips, actual GPU shader fallback, and
real main-window renders under System light/dark, Classic Player and Neo Brutalism. The
`theme-audio-spectrum` evidence entry owns those captures. `AudioSpectrumCaptureIntegrationTests`
adds opt-in real HAL coverage through `scripts/test_theme_audio_capture.sh`, which builds
a separate controlled tone source and sets `THREADING_TEST_LIVE_AUDIO=1`; synthetic analyzer tests do
not establish that a system permission was granted or that a protected player supplies samples.

The first hosted debug run measured 900 analyses in 0.557 seconds (about 0.62 ms per
snapshot, 1.9% of one core at 30 Hz). This is an analysis timing only; the Mac was under
heavy unrelated load, and live compositor/energy cost has not been profiled.

### Live capture checkpoint, 2 October 2026

The focused native suite passed 164 tests and the extension SDK passed 179 tests. The
Wasm example compiled, and the real shell's System light/dark, Classic Player, Neo and
unavailable-state renders were inspected. These checks establish the analysis, lifecycle,
public bindings and presentation; they do not establish working hardware capture.

The initial opt-in HAL integration test failed on the development Mac (macOS 26.5): a
controlled tone source opens successfully but delivers zero callbacks/frames. Spotify was
also detected with `kAudioProcessPropertyIsRunningOutput == 1` and delivered no callbacks.
Registration waits inside Core Audio's `_TellServerAboutStreamUsage`; starting without tap
auto-start returns `MACH_RCV_TIMED_OUT` (`0x10004003`). A C callback, an output-only speaker
clock, a separately launched app with its own usage description, and a test host signed with
Threading's normal Developer ID did not resolve it. The test build was restored afterward.
The cause remained unresolved during that run. Missing delivery remains unavailable in
the public API; the recovery checks below establish subsequent live delivery.

The installed app's Motion preview also stalled in `AudioDeviceStart` on this Mac. A
fresh, Developer ID-signed diagnostic confirmed that the aggregate contains the correct
tap UUID, one input stream, and a 48 kHz nominal rate before IOProc registration. A stereo
tap still stalled; setting the tap's unchanged description returned `MACH_RCV_TIMED_OUT`
after 30 seconds. A separate ScreenCaptureKit check did not complete shareable-content
enumeration before its 45-second process deadline, even though TCC reported Threading's
Screen Recording grant as allowed. This narrows the failure to capture startup rather
than FFT or theme rendering, but does not establish its cause. No capture-backend fallback,
system-service restart, or privacy-grant change was made during these checks.

### Live capture recovery, 3 October 2026

After the user restarted the Mac's audio service, standalone apps signed with Threading's
normal Developer ID and using the unmodified production `AudioSpectrumCapture` opened and
closed promptly. The controlled 1 kHz source delivered 310 callbacks and 88 readings;
its peak level was 0.384 and band 3 was strongest, as expected. Playing Spotify delivered
313 callbacks and 88 readings, with a peak level of 0.720 and nonzero values across all
eight bands. The all-system source also delivered 312 callbacks and 88 readings, with a
peak level of 0.777. These checks establish real process-tap delivery and analysis on this Mac,
without changing the capture implementation or the user's saved audio settings. The
earlier failed XCTest HAL run was not rerun by these standalone checks. The underlying
cause of the original service stall remains unknown; restart recovery does not establish
that the stall cannot recur.
