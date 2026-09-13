fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Archive ThreadingMobile in Release and upload it to TestFlight.

Refuses an uncommitted tree unless allow_dirty:true. changelog:"…" sets What to Test;

wait:false returns before App Store Connect finishes processing.

### ios validate

```sh
[bundle exec] fastlane ios validate
```

Build the IPA beta would upload and have App Store Connect validate it, uploading nothing.

### ios internal_testers

```sh
[bundle exec] fastlane ios internal_testers
```

Create the internal TestFlight group if it is missing and add THREADING_INTERNAL_TESTERS.

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

Download the App Store listing into fastlane/metadata, replacing the local files.

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload fastlane/metadata to the editable App Store version. No binary, no screenshots,

and never a submission for review.

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Place the iOS marketing captures in the Marketeer document and render the screenshots.

capture:true runs scripts/capture_marketing_ios.sh first; captures:<dir> uses existing

captures. With neither, it renders the document as it stands.

### ios screenshots_status

```sh
[bundle exec] fastlane ios screenshots_status
```

Compare the Marketeer document with the editable App Store version's screenshots.

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Print the screenshot upload plan for App Store Connect; apply:true performs it.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
