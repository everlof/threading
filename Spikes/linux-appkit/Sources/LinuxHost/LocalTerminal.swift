#if os(Linux)
import Foundation
import Glibc
import CLinuxTerminal
import ThreadingPTYHostKit

/// Own the caller's terminal mode and Linux signal delivery for the lifetime of one watcher.
/// Signals are read through the same poll loop as input, so cleanup never runs in a signal handler.
final class LocalTerminal {
    let signalFD: Int32
    private var previousMask = sigset_t()
    private var original: termios?

    init() throws {
        var mask = sigset_t()
        sigemptyset(&mask)
        for value in [SIGWINCH, SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&mask, value) }
        try check(pthread_sigmask(SIG_BLOCK, &mask, &previousMask) == 0, "cannot mask terminal signals")
        signalFD = signalfd(-1, &mask, Int32(SFD_NONBLOCK | SFD_CLOEXEC))
        if signalFD < 0 {
            pthread_sigmask(SIG_SETMASK, &previousMask, nil)
            throw HostFailure.refused("cannot open terminal signal descriptor")
        }
        if isatty(STDIN_FILENO) == 1 {
            var saved = termios()
            if tcgetattr(STDIN_FILENO, &saved) == 0 {
                original = saved
                var raw = saved
                cfmakeraw(&raw)
                if tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0 {
                    Glibc.close(signalFD)
                    pthread_sigmask(SIG_SETMASK, &previousMask, nil)
                    throw HostFailure.refused("cannot enter raw keyboard mode")
                }
            }
        }
    }
    deinit {
        if var saved = original { _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        Glibc.close(signalFD)
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)
    }
    var grid: PTYHostGrid? {
        var size = winsize()
        guard ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return PTYHostGrid(cols: Int(size.ws_col), rows: Int(size.ws_row),
                           xpixel: Int(size.ws_xpixel), ypixel: Int(size.ws_ypixel))
    }
    func nextSignal() -> Int32? {
        var event = signalfd_siginfo()
        guard Glibc.read(signalFD, &event, MemoryLayout.size(ofValue: event)) == MemoryLayout.size(ofValue: event) else { return nil }
        return Int32(event.ssi_signo)
    }
}
#endif
