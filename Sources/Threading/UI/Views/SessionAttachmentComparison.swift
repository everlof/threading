import AppKit

// MARK: - What may be compared, and which way round

/// Which two of a session's files can be put against each other, and which of them is the
/// *before*.
///
/// Held apart from the pane because the questions are policy rather than layout, and because the
/// pane asks them from three places that have to agree: the row menu's **Compare with**, a row
/// dragged onto another row, and a picture dragged in from outside. A menu that offers a pair the
/// drop refuses — or a drop that opens a comparison the menu would not have — is the same defect
/// twice, so both read the answer from here.
enum AttachmentComparison {

    /// Whether this file can be one side of a comparison.
    ///
    /// Images only, and that is the comparison surface's own rule read back rather than a second
    /// one invented here: `CompareViewController` decides what a pair *is* from the bytes, and a
    /// PDF, an archive or an office document classifies as binary — so every comparison offered
    /// for such a row would open a tab saying it cannot draw one. An offer that is always a dead
    /// end is worse than no offer, so those rows are neither drop targets nor names in the
    /// submenu.
    static func canCompare(_ attachment: SessionAttachment) -> Bool {
        attachment.kind == .image
    }

    /// Everything in `list` that `attachment` could be held against, in the list's own order —
    /// newest first, which is the order the reader has just been scanning.
    static func candidates(
        for attachment: SessionAttachment,
        in list: [SessionAttachment]
    ) -> [SessionAttachment] {
        guard canCompare(attachment) else { return [] }
        return list.filter { canCompare($0) && $0.id != attachment.id }
    }

    /// Which of the two is the old side.
    ///
    /// **The clock decides, not the gesture.** A comparison has a direction — the wipe travels
    /// from old to new, and the difference mode names the pair `old → new` — so something has to
    /// choose, and the two candidates were "whichever was dragged" and "whichever is older".
    /// Dragging is the wrong one: the same pair would read backwards depending on which row the
    /// pointer happened to start on, and the arrow would say a screenshot from this morning
    /// replaced the one from this afternoon. This list is a chronology; a comparison drawn from it
    /// is a chronology of two, and it points the way the list already does.
    ///
    /// A file dropped from outside is recorded as it lands, so it is the newest thing in the
    /// session by construction and this rule puts it on the right of its own accord.
    ///
    /// **Equal stamps are the common case here, not the degenerate one**, which is why the clock
    /// alone is not enough: both of the store's doors stamp *one* time for a whole batch, so two
    /// pictures found by one terminal scan, or handed over by one `display_compare_files`, carry
    /// the same instant to the microsecond. Left to `<=` the gesture decided after all — the very
    /// flip this rule exists to prevent, and invisible to a test whose fixtures are seconds apart.
    /// So a tie falls back to the list's own order, where a later row is the older picture, and
    /// then to the id: the answer has to be the same one whichever row the drag started from.
    static func ordered(
        _ first: SessionAttachment,
        _ second: SessionAttachment,
        in list: [SessionAttachment] = []
    ) -> (old: SessionAttachment, new: SessionAttachment) {
        if first.referencedAt != second.referencedAt {
            return first.referencedAt < second.referencedAt ? (first, second) : (second, first)
        }

        let firstRow = list.firstIndex { $0.id == first.id }
        let secondRow = list.firstIndex { $0.id == second.id }
        if let firstRow, let secondRow, firstRow != secondRow {
            return firstRow > secondRow ? (first, second) : (second, first)
        }
        return first.id <= second.id ? (first, second) : (second, first)
    }
}

// MARK: - What a drag is carrying

/// Reads a drag's pasteboard the way the attachments list needs it: is there a picture in here,
/// and which file is it?
///
/// Two kinds of drag land on these rows and only one of them has a file. A row of the list carries
/// its own file URL (which is also what lets a row be dragged out to Finder); anything from
/// outside may carry a URL, or may carry nothing but pixels — a screenshot dragged out of Preview,
/// a picture pulled off a web page. `PromptAttachment` already knows how to give the second kind a
/// path, and that is deliberately *not* done here: it writes a file, and a drag is answered on
/// every frame of the pointer's travel.
enum AttachmentComparisonDrop {

    /// Whether a drop here would find a picture, without doing anything that leaves a trace.
    ///
    /// **Files win over pixels, and that has to be said in the same order the drop will read
    /// them.** `PromptAttachment.paths` short-circuits on *any* file URL and never looks at the
    /// bitmap beside it, so a pasteboard carrying a text file *and* a picture preview — which is
    /// what dragging out of Mail or Notes produces — answered "yes, there is a picture here" and
    /// then handed the drop a `.txt` to file. The pane lit up and the release did nothing, which
    /// is the failure this type's own comments call worse than never offering.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if carriesFiles(pasteboard) { return !imageURLs(from: pasteboard).isEmpty }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// Whether the drag is carrying files at all — the question that decides which half of
    /// `canRead` applies, asked without reading them.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    /// The dragged files this list would take, in the drag's own order. Empty for a drag carrying
    /// no file at all — a screenshot dragged straight out of another app.
    ///
    /// Filtered by `AttachmentReferenceDetector.kind`, not by what the pasteboard is willing to
    /// call an image: the store admits exactly the extensions that detector names, so anything
    /// else would be a drop the pane lit up for and then dropped on the floor. It reads the
    /// pasteboard rather than counting on the table to say which row began the drag, which is
    /// also what makes "you cannot compare a file with itself" one rule instead of two.
    static func imageURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        guard let urls = objects as? [URL] else { return [] }
        return urls.filter { AttachmentReferenceDetector.kind(for: $0) == .image }
    }
}

// MARK: - When it arrived

/// How this pane says *when*, in one place because two surfaces say it: a row's caption and the
/// menu that names the same file from somewhere else.
///
/// Terse on purpose — a column of full timestamps is the same date said 32 times. Resolution
/// falls away with age: today is a time, the rest of the recent week keeps its weekday and time,
/// rows up to a year old keep the day, and older rows keep only month and year.
@MainActor
enum AttachmentMoment {

    static func description(
        of date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let dayDistance = abs(
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: referenceDate)
            ).day ?? AttachmentMomentDefaults.distantDay
        )

        let format = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )

        switch dayDistance {
        case 0:
            return date.formatted(format.hour().minute())
        case 1..<AttachmentMomentDefaults.recentDayLimit:
            return date.formatted(format.weekday(.abbreviated).hour().minute())
        default:
            if isWithinOneYear(date, of: referenceDate, calendar: calendar) {
                return date.formatted(format.day().month(.abbreviated))
            }
            return date.formatted(format.month(.abbreviated).year())
        }
    }

    private static func isWithinOneYear(
        _ date: Date,
        of referenceDate: Date,
        calendar: Calendar
    ) -> Bool {
        guard let yearBefore = calendar.date(byAdding: .year, value: -1, to: referenceDate),
              let yearAfter = calendar.date(byAdding: .year, value: 1, to: referenceDate) else {
            return true
        }
        return yearBefore...yearAfter ~= date
    }
}

private enum AttachmentMomentDefaults {
    /// Today plus the preceding six days: one glance still distinguishes morning from afternoon.
    static let recentDayLimit = 7
    static let distantDay = Int.max
}
