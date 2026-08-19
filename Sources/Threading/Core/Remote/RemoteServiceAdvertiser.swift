import Foundation
import Network
import ThreadingRemoteKit

/// What one Bonjour registration asks for.
///
/// A value rather than a live `NWListener.Service`, because this is the thing worth asserting on:
/// which name is broadcast, on which port, with which TXT entries. The listener that carries it
/// is an implementation detail of applying it.
struct RemoteServiceRegistration: Equatable, Sendable {
    let name: String
    let type: String
    let domain: String
    let port: UInt16
    let advertisement: RemoteHostAdvertisement

    init(
        advertisement: RemoteHostAdvertisement,
        port: UInt16,
        type: String = RemoteDiscoveryDefaults.serviceType,
        domain: String = RemoteDiscoveryDefaults.serviceDomain
    ) {
        self.name = RemoteDiscoveryDefaults.instanceName(hostID: advertisement.hostID)
        self.type = type
        self.domain = domain
        self.port = port
        self.advertisement = advertisement
    }

    /// The TXT record as Network.framework wants it.
    var txtRecord: NWTXTRecord {
        var record = NWTXTRecord()
        for entry in advertisement.txtEntries { record[entry.key] = entry.value }
        return record
    }

    /// The Network.framework value that performs the registration.
    var service: NWListener.Service {
        NWListener.Service(name: name, type: type, domain: domain, txtRecord: txtRecord.data)
    }
}

/// Where a registration is actually performed.
///
/// A seam for two reasons. A hosted test runs inside the shipping app, so an unredirected
/// registration would broadcast the developer's Mac on their own network and could outlive the
/// test; and the interesting assertion is *what* was registered, which a value can carry and a
/// live `mDNSResponder` cannot be asked.
protocol RemoteServiceAdvertising: AnyObject, Sendable {

    /// Publishes `registration` on `listener`, or withdraws whatever is published when it is nil.
    ///
    /// Called on the listener set's own queue. Idempotent: applying the same registration twice
    /// is not an error, and the caller only calls when the value changed.
    func apply(_ registration: RemoteServiceRegistration?, to listener: NWListener?)
}

/// The shipping advertiser: it hands the registration to the listener that carries it.
///
/// **One registration, not one per address.** Several LAN interfaces mean several listeners under
/// the one `lan` door, but Bonjour advertises a *host*: the SRV record names this Mac's `.local`
/// name, and the address records behind that name already cover every interface the Mac holds. A
/// second registration of the same name and port would be a conflict mDNSResponder resolves by
/// renaming one of them to `name (2)`, which is a broadcast of nothing useful.
/// `@unchecked Sendable` for the same reason the listener set is: `carrier` is written only from
/// the listener set's own queue, which is the one executor that calls this.
final class RemoteBonjourServiceAdvertiser: RemoteServiceAdvertising, @unchecked Sendable {

    /// The listener currently carrying the registration, so a withdrawal reaches the same one
    /// even when the caller no longer has it. Only ever touched on the caller's queue.
    private weak var carrier: NWListener?

    func apply(_ registration: RemoteServiceRegistration?, to listener: NWListener?) {
        if let carrier, carrier !== listener { carrier.service = nil }
        guard let registration, let listener else {
            carrier?.service = nil
            carrier = nil
            return
        }
        listener.service = registration.service
        carrier = listener
    }
}

/// An advertiser that registers nothing, for a process that must not broadcast.
///
/// The default in a hosted test process, exactly like `RefusedRemoteTransport`: the test bundle
/// lives inside this app, so a test that reached the shipping advertiser would publish the
/// developer's Mac on whatever network it is on. A test that wants to observe advertising injects
/// a recorder instead of relying on this.
final class InertRemoteServiceAdvertiser: RemoteServiceAdvertising {
    func apply(_ registration: RemoteServiceRegistration?, to listener: NWListener?) {}
}

enum RemoteServiceAdvertisers {
    static func standard() -> any RemoteServiceAdvertising {
        NSClassFromString("XCTestCase") != nil
            ? InertRemoteServiceAdvertiser()
            : RemoteBonjourServiceAdvertiser()
    }
}
