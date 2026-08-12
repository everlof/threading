import UserNotifications
import XCTest
@testable import Threading

/// Which sound a notification carries: the folder search, the stored choice, and what adding
/// a file to the Sounds folder does.
///
/// Nothing here delivers a notification. `UNNotificationSound(named:)` takes a file *name* and
/// a system process resolves it later, so everything worth asserting is on this side of that
/// hand-off: whether the name will resolve, which folder answered, and what a name that
/// resolves nowhere falls back to. Measured on macOS 26.5 with a probe app: an unresolvable
/// name posts the banner in silence, with no fallback of its own, which is the whole reason
/// `resolvedSound` checks first.
@MainActor
final class AttentionAlertSoundTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionAlertSoundTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Stored Choice

    /// The default is the *absence* of a choice, so an install that has never chosen and one
    /// that chose the system sound read the same — and neither writes a key.
    func testAnAbsentPreferenceIsTheSystemDefault() {
        XCTAssertEqual(AttentionAlertSound(storedValue: nil), .systemDefault)
        XCTAssertEqual(AttentionAlertSound(storedValue: ""), .systemDefault)
        XCTAssertNil(AttentionAlertSound.systemDefault.storedValue)
    }

    func testANameRoundTripsThroughTheStoredValue() {
        let choice = AttentionAlertSound(storedValue: "Submarine.aiff")
        XCTAssertEqual(choice, .named("Submarine.aiff"))
        XCTAssertEqual(choice.storedValue, "Submarine.aiff")
    }

    func testTheChoiceDefaultsOnAndPersists() throws {
        let suite = "AttentionAlertSoundChoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.attentionAlertSound, .systemDefault)

        settings.attentionAlertSound = .named("Glass.aiff")
        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .named("Glass.aiff"))

        // Back to the default removes the key rather than storing an empty name, so the
        // preference stays readable as "never chose".
        settings.attentionAlertSound = .systemDefault
        XCTAssertNil(defaults.string(forKey: "attentionAlertSound"))
    }

    // MARK: - Resolution

    func testANameThatResolvesNowhereFallsBackToTheSystemSound() {
        let sound = AttentionAlertSound.named("NoSuchSound.aiff").resolvedSound(in: [root])
        XCTAssertEqual(sound, .default)
    }

    func testAResolvableNameIsHandedOverAsItsOwnSound() throws {
        try write("Chime.aiff", to: root)
        let sound = AttentionAlertSound.named("Chime.aiff").resolvedSound(in: [root])
        XCTAssertNotEqual(sound, .default)
    }

    /// The sound the picker previews has to be the file the notification will play, which is
    /// only true if both search the folders in the same order.
    func testTheFirstSearchPathShadowsTheRest() throws {
        let user = try directory(named: "user")
        let system = try directory(named: "system")
        try write("Glass.aiff", to: user, contents: "user")
        try write("Glass.aiff", to: system, contents: "system")

        let resolved = try XCTUnwrap(
            NotificationSoundLibrary.resolve(fileName: "Glass.aiff", in: [user, system])
        )
        XCTAssertEqual(try Data(contentsOf: resolved.url), Data("user".utf8))
        XCTAssertTrue(resolved.isUserInstalled)

        XCTAssertEqual(NotificationSoundLibrary.available(in: [user, system]).count, 1)
    }

    func testResolveAnswersNilForAMissingFile() throws {
        XCTAssertNil(NotificationSoundLibrary.resolve(fileName: "Glass.aiff", in: [root]))
    }

    // MARK: - Listing

    func testOnlyPlayableFormatsAreListed() throws {
        for name in ["A.aiff", "B.wav", "C.caf", "D.aif", "E.mp3", "F.txt", "G"] {
            try write(name, to: root)
        }
        let listed = NotificationSoundLibrary.available(in: [root]).map(\.fileName)
        XCTAssertEqual(Set(listed), ["A.aiff", "B.wav", "C.caf", "D.aif"])
    }

    /// The picker's own name for a sound is the file's, without the extension: what System
    /// Settings shows, and never localized.
    func testTheDisplayNameDropsTheExtension() throws {
        try write("Knock Brush.aiff", to: root)
        let sound = try XCTUnwrap(NotificationSoundLibrary.available(in: [root]).first)
        XCTAssertEqual(sound.displayName, "Knock Brush")
    }

    func testEachFolderIsListedAlphabeticallyAndInSearchOrder() throws {
        let user = try directory(named: "user")
        let system = try directory(named: "system")
        try write("Zebra.aiff", to: user)
        try write("Alpha.aiff", to: user)
        try write("Beta.aiff", to: system)
        try write("Aardvark.aiff", to: system)

        let listed = NotificationSoundLibrary.available(in: [user, system]).map(\.displayName)
        XCTAssertEqual(listed, ["Alpha", "Zebra", "Aardvark", "Beta"])
    }

    // MARK: - Suggested Group

    func testTheSuggestedFewComeOutInTheirOwnOrderAndOnlyOnce() throws {
        for name in SuggestedNotificationSounds.fileNames { try write(name, to: root) }
        try write("Basso.aiff", to: root)

        let (suggested, rest) = SuggestedNotificationSounds
            .partition(NotificationSoundLibrary.available(in: [root]))

        // Curated order, not the alphabetical order the folder listing came in.
        XCTAssertEqual(suggested.map(\.fileName), SuggestedNotificationSounds.fileNames)
        XCTAssertEqual(rest.map(\.fileName), ["Basso.aiff"])
    }

    /// A macOS release that stops shipping one of these drops it from the group rather than
    /// leaving an item that resolves to nothing.
    func testASuggestedSoundThatIsNotInstalledIsSimplyAbsent() throws {
        try write("Basso.aiff", to: root)
        let (suggested, rest) = SuggestedNotificationSounds
            .partition(NotificationSoundLibrary.available(in: [root]))
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertEqual(rest.map(\.fileName), ["Basso.aiff"])
    }

    // MARK: - Adding a Sound

    func testAddingASoundCopiesItIntoTheFolderMacOSSearches() throws {
        let source = try directory(named: "source")
        let destination = try directory(named: "sounds")
        let file = try aiff(named: "Marimba.aiff", in: source)

        let installed = try CustomNotificationSound.install(file, into: destination)

        XCTAssertEqual(installed.fileName, "Marimba.aiff")
        XCTAssertTrue(installed.isUserInstalled)
        XCTAssertEqual(installed.url.deletingLastPathComponent().lastPathComponent, "sounds")
        // A copy, not a reference: the name is resolved later by a system process, and a file
        // left where the user picked it would stop playing the moment it moved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(
            NotificationSoundLibrary.resolve(fileName: "Marimba.aiff", in: [destination])?.url,
            installed.url
        )
    }

    func testAddingTheSameSoundTwiceReusesTheCopy() throws {
        let source = try directory(named: "source")
        let destination = try directory(named: "sounds")
        let file = try aiff(named: "Marimba.aiff", in: source)

        let first = try CustomNotificationSound.install(file, into: destination)
        let second = try CustomNotificationSound.install(file, into: destination)

        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
    }

    /// `~/Library/Sounds` is macOS's folder, not Threading's: a sound already there under the
    /// same name may belong to something else, so it is never written over.
    func testADifferentSoundOfTheSameNameTakesTheNextFreeName() throws {
        let source = try directory(named: "source")
        let destination = try directory(named: "sounds")
        let existing = try aiff(named: "Marimba.aiff", in: destination, seed: 1)
        let file = try aiff(named: "Marimba.aiff", in: source, seed: 2)

        let installed = try CustomNotificationSound.install(file, into: destination)

        XCTAssertEqual(installed.fileName, "Marimba 2.aiff")
        XCTAssertEqual(try Data(contentsOf: existing), try aiffData(seed: 1))
    }

    /// A sound whose file name would hide it from the person who just added it.
    func testALeadingDotIsTrimmedOffTheInstalledName() throws {
        let source = try directory(named: "source")
        let destination = try directory(named: "sounds")
        let file = try aiff(named: ".Marimba.aiff", in: source)

        let installed = try CustomNotificationSound.install(file, into: destination)

        XCTAssertEqual(installed.fileName, "Marimba.aiff")
    }

    func testAFileMacOSCannotPlayIsRefusedAtTheDoor() throws {
        let source = try directory(named: "source")
        let file = source.appendingPathComponent("Song.mp3")
        try Data("not audio".utf8).write(to: file)

        XCTAssertThrowsError(try CustomNotificationSound.install(file, into: root)) { error in
            XCTAssertEqual(error as? CustomNotificationSound.Failure, .unsupportedFormat("mp3"))
        }
    }

    /// The extension is a claim, not a format. A file that macOS cannot read is refused before
    /// it lands in the folder, rather than becoming a selectable sound that plays nothing.
    func testAFileThatIsNotReallyASoundIsRefused() throws {
        let source = try directory(named: "source")
        let destination = try directory(named: "sounds")
        let file = source.appendingPathComponent("Broken.aiff")
        try Data("not audio".utf8).write(to: file)

        XCTAssertThrowsError(try CustomNotificationSound.install(file, into: destination)) { error in
            XCTAssertEqual(error as? CustomNotificationSound.Failure, .unreadable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    // MARK: - Helpers

    private func directory(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(
        _ name: String,
        to directory: URL,
        contents: String = "x"
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A real, if very short, AIFF. `install` refuses anything `NSSound` cannot open, so the
    /// fixtures it is meant to accept have to be openable.
    private func aiff(named name: String, in directory: URL, seed: UInt8 = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try aiffData(seed: seed).write(to: url)
        return url
    }

    private func aiffData(seed: UInt8) throws -> Data {
        let source = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        var data = try XCTUnwrap(
            try? Data(contentsOf: source),
            "the platform stopped shipping the sound this fixture is built from"
        )
        // Two fixtures that differ, without either stopping being playable audio: the seed
        // lands in the sample data, past the header.
        if seed != 0 { data[data.count - 1] = seed }
        return data
    }
}
