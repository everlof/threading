import Foundation
import ThreadingRemoteKit

/// Presence describes other people, not sockets or the viewer's own devices. Socket identity
/// still owns removal, so closing one of Anna's tabs does not make Anna disappear.
///
/// Scaling contract: normally 1–8 sockets, stress-tested with 1,000. A wire delta updates only
/// its old/new person in O(1). Rendering reads counts and at most three person values (the two
/// displayed names plus self); neither terminal output nor layout scans the socket roster.
struct MobileCollaborationPresence {
    private var sockets: [String: RemotePresenceDTO] = [:]
    private var viewing = People()
    private var typing = People()

    init(_ updates: [RemotePresenceDTO] = []) {
        for update in updates { apply(update) }
    }

    mutating func apply(_ update: RemotePresenceDTO) {
        if let previous = sockets.removeValue(forKey: update.id) {
            viewing.remove(previous)
            if previous.state == .typing { typing.remove(previous) }
        }
        guard update.state != .left else { return }
        sockets[update.id] = update
        viewing.add(update)
        if update.state == .typing { typing.add(update) }
    }

    mutating func removeAll() {
        self = Self()
    }

    func label(
        currentParticipantID: String?,
        showsTyping: Bool,
        showsViewing: Bool
    ) -> String? {
        // Until the host identifies this viewer, another owner socket is not evidence that
        // another person joined. Older hosts without participant identity stay quiet too.
        guard let currentParticipantID else { return nil }
        let viewer = Self.participantID(currentParticipantID)
        if showsTyping, let label = typing.label(excluding: viewer, isTyping: true) {
            return label
        }
        return showsViewing ? viewing.label(excluding: viewer, isTyping: false) : nil
    }

    private static func participantID(_ wireID: String) -> String {
        // Existing hosts encode owner presence as owner:<device ID>, while input control
        // correctly identifies every paired owner device as the same "owner" participant.
        wireID.hasPrefix("owner:") ? RemoteCollaborationParticipantDTO.ownerID : wireID
    }

    private struct People {
        private struct Person {
            var sockets: Int
            var name: String
        }
        private var people: [String: Person] = [:]

        mutating func add(_ update: RemotePresenceDTO) {
            let id = participantID(update.memberID)
            let name = id == RemoteCollaborationParticipantDTO.ownerID
                ? MobileL10n.string("Owner")
                : update.displayName
            people[id] = Person(sockets: (people[id]?.sockets ?? 0) + 1, name: name)
        }

        mutating func remove(_ update: RemotePresenceDTO) {
            let id = participantID(update.memberID)
            guard var person = people[id] else { return }
            person.sockets -= 1
            people[id] = person.sockets == 0 ? nil : person
        }

        func label(excluding viewer: String, isTyping: Bool) -> String? {
            let count = people.count - (people[viewer] == nil ? 0 : 1)
            guard count > 0 else { return nil }
            if count > 2 {
                return isTyping
                    ? MobileL10n.string("%lld people are typing…", Int64(count))
                    : MobileL10n.string("%lld people are here", Int64(count))
            }
            // This collection has at most three entries. Count people by ID, never by name:
            // two collaborators called Anna are still two people.
            let names = people.filter { $0.key != viewer }.map(\.value.name).sorted()
            if count == 1 {
                return isTyping
                    ? MobileL10n.string("%@ is typing…", names[0])
                    : MobileL10n.string("%@ is here", names[0])
            }
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return isTyping
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
    }
}
