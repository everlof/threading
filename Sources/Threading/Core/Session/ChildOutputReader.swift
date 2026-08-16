import Foundation

/// Delivers a child's pipe output burst by burst, while the child is still running.
///
/// This is one function rather than three copies of a closure because the obvious way to write it
/// is wrong in a way that looks right. `FileHandle.read(upToCount:)` reads as "give me at most
/// this much", but Foundation treats the count as a length to **fill**: the call stays inside
/// `read(2)` until that many bytes arrive or the writer closes the pipe. A child that prints a few
/// kilobytes and then keeps running therefore delivers *nothing* — the handler blocks inside its
/// very first callback and never returns.
///
/// That is not hypothetical. It is how the HTTPS relay came up, published its address, served
/// real traffic, and left the iPhone pairing card spinning on "Preparing your pairing code" for
/// the life of the app: `cloudflared` prints roughly 3 KB of banner, including the URL, and then
/// goes quiet, so a 16 KB request never came back and the address was never parsed. Nothing
/// timed out, because a blocked read is not a failure.
///
/// `availableData` hands over exactly what the readability source announced, and empty `Data` at
/// end of file — which is also why the handler is retired there rather than left to wake forever
/// on a closed descriptor.
enum ChildOutputReader {

    /// Installs a readability handler on `handle` that calls `receive` with each burst as it
    /// arrives, and removes itself at end of file.
    ///
    /// `receive` runs on Foundation's monitoring queue for this handle, not on the main actor.
    /// It must not block: the descriptor stays unread until it returns.
    static func deliver(
        from handle: FileHandle,
        to receive: @escaping @Sendable (Data) -> Void
    ) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            receive(data)
        }
    }
}
