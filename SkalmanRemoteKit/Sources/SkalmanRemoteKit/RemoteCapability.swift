import Foundation

/// What a share lets a remote client do to a session. A wire type — it appears as a string in
/// `hello` and in `/api/me` — so it lives here, shared by the server that enforces it and the
/// client that renders it.
///
/// Enforced **server-side, per message**: a `view` client that sends input is refused at the
/// server, never merely hidden by the client.
public enum RemoteCapability: String, Codable, Equatable {
    /// Watch only: output flows out, nothing flows back.
    case view
    /// Watch and drive: keystrokes, prompt submissions and permission answers are accepted.
    case interact
}
