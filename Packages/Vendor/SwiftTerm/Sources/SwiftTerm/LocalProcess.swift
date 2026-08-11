//
//  LocalProcess.swift
//  
// This file contains the supporting infrastructure to run local processes that can be connected
// to a Termianl
//
//  Created by Miguel de Icaza on 4/5/20.
//
#if !os(iOS) && !os(Windows)
import Foundation
import Dispatch

/// Delegate that is invoked by the ``LocalProcess`` class in response to various
/// process-related events.
public protocol LocalProcessDelegate: AnyObject {
    /// This method is invoked on the delegate when the process has exited
    /// - Parameter source: the local process that terminated
    /// - Parameter exitCode: the exit code returned by the process, or nil if this was an error caused during the IO reading/writing
    func processTerminated (_ source: LocalProcess, exitCode: Int32?)
    
    /// This method is invoked when data has been received from the local process that should be send to the terminal for processing.
    func dataReceived (slice: ArraySlice<UInt8>)

    /// This method should return the window size to report to the local process.
    func getWindowSize () -> winsize
}

/**
 * This class provides the capabilities to launch a local Unix process, and connect it to a `Terminal`
 * class or subclass.
 *
 * The `MacLocalTerminalView` is an example of this, it is a subclass of the
 * `MacTerminalView` NSView, and it connects that view to the local system, providing a complete
 * terminal emulator connected to running local commands.
 *
 * When you create an instance of `LocalProcess`, you provide a delegate that is used to notify
 * your application when data is received from the lcoal process, to request the desired window size
 * that you would like to give to the child process, and when the process terminates.
 *
 * Once you create this instance, you can start a child process by calling the `startProcess` method
 * which will start the process.   You can then send data to this underlying process using the
 * `send(data:)` method, and you will receive the output on the provided delegate with the
 * `dataReceived(slice:)` method.
 *
 * Received data is dispatched via the queue that you provide in the LocalProcess constructor, if none
 * is provided, this will default to `DispatchQueue.main`.  Generally, this is a good default, but if you
 * have your own main loop or a different dispatching system, you will need to pass your own (for example,
 * the `HeadlessTerminal` implementation in the test suite does this.
 *
 * The `terminate` call will send the `SIGTERM` signal to the child process.
 *
 * The `shellPid` property has the PID for the child process, and this can be used to send signals
 * to it using the `kill` API.
 *
 * The `childfd` property has the Unix file descriptor for the primary side of the created pseudo-terminal.
 *
 * This implementation uses `forkpty`, so the child owns a controlling terminal and its PID is
 * available synchronously to callers.
 */
public class LocalProcess {
    let readSize = 128*1024
    
    /* The file descriptor used to communicate with the child process */
    public private(set) var childfd: Int32 = -1
    
    /* The PID of our subprocess */
    public private(set) var shellPid: pid_t = 0
    var debugIO = false
    
    /* number of sent requests */
    var sendCount = 0
    var total = 0

    weak var delegate: LocalProcessDelegate?
    
    // Queue used to send the data received from the local process
    var dispatchQueue: DispatchQueue
    
    // The queue we use to read, it feels more interactive if we
    // read here and then post to the main thread.   Otherwise it feels
    // chunky.
    var readQueue: DispatchQueue
    
    var io: DispatchIO?

    private let usesMainQueue: Bool
    private let pendingChunkFlushThreshold = 32
    private let pendingTimeSliceNanoseconds: UInt64 = 4_000_000
    private let pendingHighWaterBytes = 4 * 1024 * 1024
    private let pendingLowWaterBytes = 1 * 1024 * 1024
    private var pendingChunks: [[UInt8]] = []
    private var pendingChunkIndex = 0
    private var pendingBytes = 0
    private var pendingScheduled = false
    private var readSuspendedForBackpressure = false
    private var pendingGeneration: UInt64 = 0
    private let pendingLock = NSLock()

    /// Identifies the child that owns the current PTY callbacks.
    ///
    /// DispatchIO callbacks can arrive after a descriptor has been closed. Tagging every read
    /// and queued delivery prevents one process's tail output from entering a subsequently
    /// launched terminal generation.
    private var processGeneration: UInt64 = 0
    private var terminationRequested = false
    
    /**
     * Initializes the LocalProcess runner and communication with the host happens via the provided
     * `LocalProcessDelegate` instance.
     * - Parameter delegate: the delegate that will receive events or request data from your application
     * - Parameter dispatchQueue: this is the queue that will be used to post data received from the
     * child process when calling the `send(dataReceived:)` delegate method.  If the value provided is `nil`,
     * then this will default to `DispatchQueue.main`
     */
    public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil)
    {
        self.delegate = delegate
        self.dispatchQueue = dispatchQueue ?? DispatchQueue.main
        self.readQueue = DispatchQueue(label: "sender")
        self.usesMainQueue = self.dispatchQueue === DispatchQueue.main
    }

    deinit {
        let pid = shellPid

        io?.close()
        io = nil
        cancelChildMonitor()

        guard pid > 0 else { return }
        kill(pid, SIGTERM)

        // Once the monitor is cancelled, an independent waiter must own reaping the child.
        // Capturing only the PID lets LocalProcess deallocate immediately without leaving a
        // zombie or retaining its delegate and terminal view.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    private func resetPendingOutput(for generation: UInt64) {
        pendingLock.lock()
        pendingGeneration = generation
        pendingChunks.removeAll(keepingCapacity: true)
        pendingChunkIndex = 0
        pendingBytes = 0
        pendingScheduled = false
        readSuspendedForBackpressure = false
        pendingLock.unlock()
    }

    /// Queues output for bounded main-thread delivery.
    ///
    /// The terminal view and Threading's output hooks are main-thread objects, but making the PTY
    /// reader wait synchronously on that thread makes fast output feel chunky. An unbounded
    /// asynchronous hop has the opposite failure: memory grows for as long as the producer
    /// outruns AppKit. Stop reading at the high-water mark and let the kernel's PTY buffer apply
    /// the same backpressure a physical terminal would.
    private func enqueueReceivedData(_ bytes: [UInt8], generation: UInt64) -> Bool {
        pendingLock.lock()
        guard generation == pendingGeneration else {
            pendingLock.unlock()
            return false
        }
        pendingChunks.append(bytes)
        pendingBytes += bytes.count
        let keepReading = pendingBytes < pendingHighWaterBytes
        if !keepReading {
            readSuspendedForBackpressure = true
        }
        let shouldSchedule = !pendingScheduled
        if shouldSchedule {
            pendingScheduled = true
        }
        pendingLock.unlock()

        if shouldSchedule {
            dispatchQueue.async { [weak self] in
                self?.drainReceivedData(generation: generation)
            }
        }
        return keepReading
    }

    private func resumePtyRead(generation: UInt64) {
        guard running,
              !terminationRequested,
              generation == processGeneration,
              let io else { return }
        io.read(offset: 0, length: readSize, queue: readQueue) { [weak self] done, data, error in
            self?.childProcessRead(generation: generation, done: done, data: data, errno: error)
        }
    }

    private func drainReceivedData(generation: UInt64) {
        let startedAt = DispatchTime.now().uptimeNanoseconds

        while true {
            var chunk: [UInt8]?
            var shouldResumeRead = false

            pendingLock.lock()
            guard generation == pendingGeneration else {
                pendingLock.unlock()
                return
            }
            if pendingChunkIndex < pendingChunks.count {
                chunk = pendingChunks[pendingChunkIndex]
                pendingChunkIndex += 1
                if pendingChunkIndex >= pendingChunkFlushThreshold {
                    pendingChunks.removeFirst(pendingChunkIndex)
                    pendingChunkIndex = 0
                }

                if let chunk {
                    pendingBytes -= chunk.count
                    if readSuspendedForBackpressure && pendingBytes <= pendingLowWaterBytes {
                        readSuspendedForBackpressure = false
                        shouldResumeRead = true
                    }
                }
            } else {
                pendingChunks.removeAll(keepingCapacity: true)
                pendingChunkIndex = 0
                pendingBytes = 0
                pendingScheduled = false
                pendingLock.unlock()
                return
            }
            pendingLock.unlock()

            if shouldResumeRead {
                resumePtyRead(generation: generation)
            }
            if let chunk {
                delegate?.dataReceived(slice: chunk[...])
            }

            if DispatchTime.now().uptimeNanoseconds - startedAt >= pendingTimeSliceNanoseconds {
                dispatchQueue.async { [weak self] in
                    self?.drainReceivedData(generation: generation)
                }
                return
            }
        }
    }
    
    /**
     * Sends the array slice to the local process using DispatchIO
     * - Parameter data: The range of bytes to send to the child process
     */
    public func send (data: ArraySlice<UInt8>)
    {
        guard running, !terminationRequested, childfd >= 0 else {
            return
        }
        let copy = sendCount
        sendCount += 1
        data.withUnsafeBytes { ptr in
            let ddata = DispatchData(bytes: ptr)
            let copyCount = ddata.count
            if debugIO {
                SwiftTermDiagnostics.emit(
                    .debug,
                    .ptyWriteQueued,
                    facts: ["sequence": copy, "byteCount": data.count]
                )
            }

            DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.global(qos: .userInitiated), handler:  { dd, errno in
                self.total += copyCount
                if self.debugIO {
                    SwiftTermDiagnostics.emit(
                        .debug,
                        .ptyWriteCompleted,
                        facts: ["sequence": copy, "totalByteCount": self.total]
                    )
                }
                if errno != 0 {
                    SwiftTermDiagnostics.emit(
                        .error,
                        .ptyWriteFailed,
                        facts: ["errno": Int(errno), "byteCount": copyCount]
                    )
                }
            })
        }

    }
    
    /* Used to generate the next file name counter */
    var logFileCounter = 0
    
    /* Total number of bytes read */
    var totalRead = 0
    func childProcessRead (generation: UInt64, done: Bool, data: DispatchData?, errno: Int32) {
        guard generation == processGeneration else { return }

        guard let data else {
            // A transient callback without data must not break the one-read-at-a-time chain.
            if !done {
                resumePtyRead(generation: generation)
            }
            return
        }
        if debugIO {
            totalRead += data.count
            SwiftTermDiagnostics.emit(
                .debug,
                .ptyReadCompleted,
                facts: ["byteCount": data.count, "totalByteCount": totalRead]
            )
        }
        
        if data.count == 0 {
            childfd = -1
            return
        }
        var b: [UInt8] = Array.init(repeating: 0, count: data.count)
        b.withUnsafeMutableBufferPointer({ ptr in
            let _ = data.copyBytes(to: ptr)
            if let dir = loggingDir {
                let path = dir + "/log-\(logFileCounter)"
                do {
                    let dataCopy = Data (ptr)
                    try dataCopy.write(to: URL.init(fileURLWithPath: path))
                    logFileCounter += 1
                } catch {
                    SwiftTermDiagnostics.emit(.warning, .ptyDataDumpFailed)
                }
            }
        })
        // DispatchIO may invoke this handler more than once for one read operation. Only its
        // final callback is allowed to start the successor; re-arming on every partial callback
        // creates concurrent read chains that multiply under a fast producer.
        let keepReading: Bool
        if usesMainQueue {
            keepReading = enqueueReceivedData(b, generation: generation)
        } else {
            dispatchQueue.sync {
                guard generation == self.processGeneration else { return }
                self.delegate?.dataReceived(slice: b[...])
            }
            keepReading = true
        }
        if done && keepReading {
            resumePtyRead(generation: generation)
        }
    }

#if os(macOS)
    var childMonitor: DispatchSourceProcess?
#endif

    func processTerminated (pid: pid_t, generation: UInt64)
    {
        var waitStatus: Int32 = 0
        var waitedPID: pid_t
        repeat {
            waitedPID = waitpid(pid, &waitStatus, 0)
        } while waitedPID == -1 && errno == EINTR

        let exitCode = waitedPID == pid
            ? Self.exitCode(fromWaitStatus: waitStatus)
            : nil

        // A stale exit callback must never mutate a newer child. startProcess also refuses
        // relaunch until reaping finishes, but this check keeps the callback safe if callers
        // invoke lifecycle methods from different queues.
        guard generation == processGeneration, pid == shellPid else { return }

        // Reaping the child destroys the kernel event this source is registered for. Left
        // active, the knote is reported as EV_VANISHED the next time the workloop re-arms
        // its sources — which happens when an unrelated session starts a PTY of its own —
        // and libdispatch treats an unexpected EV_VANISHED as a fatal client bug. The source
        // is cancelled here rather than in `terminate()` because it is what reaps the child:
        // cancelling before the exit event arrives would leave a zombie behind instead.
        cancelChildMonitor()

        io?.close()
        io = nil
        childfd = -1
        terminationRequested = false
        running = false
        shellPid = 0
        delegate?.processTerminated(self, exitCode: exitCode)
    }

    /// Darwin exposes the wait-status helpers as C macros, which Swift cannot import.
    ///
    /// The low seven bits are zero for an ordinary exit and the next byte carries the code.
    /// A signal termination has no process-returned exit code, so the delegate receives nil.
    static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    /// Releases the child's exit source. Idempotent, since the exit event fires at most once.
    private func cancelChildMonitor ()
    {
#if os(macOS)
        childMonitor?.cancel()
        childMonitor = nil
#endif
    }

    /// Indicates whether this instance still owns a child lifecycle.
    ///
    /// This remains true between `terminate()` and `waitpid`: that terminating child still owns
    /// the exit monitor and must be reaped before another launch can reuse this instance.
    public private(set) var running: Bool = false
    
    /**
     * Launches a child process inside a pseudo-terminal
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     * - Parameter execName: If provided, this is used as the Unix argv[0] parameter, otherwise, the executable is used as the args [0], this is used when the intent is to set a different process name than the file that backs it.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
     {
        if running || shellPid != 0 {
            return
        }

        processGeneration &+= 1
        let generation = processGeneration
        terminationRequested = false
        resetPendingOutput(for: generation)

        startProcessWithForkpty(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory,
            generation: generation
        )
    }

    private func startProcessWithForkpty(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?,
        generation: UInt64
    ) {
        var size = delegate?.getWindowSize () ?? winsize()
    
        var shellArgs = args
        if let firstArgName = execName {
            shellArgs.insert (firstArgName, at: 0)
        } else {
            shellArgs.insert(executable, at: 0)
        }
        
        var env: [String]
        if environment == nil {
            env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        } else {
            env = environment!
        }

        if let (shellPid, childfd) = PseudoTerminalHelpers.fork(andExec: executable, args: shellArgs, env: env, currentDirectory: currentDirectory, desiredWindowSize: &size) {
            // Publish the exact child identity before activating the exit source. Very short
            // commands can exit immediately, and their handler must never observe the default
            // PID (0) or an unstarted state.
            running = true
            self.childfd = childfd
            self.shellPid = shellPid
#if os(macOS)
            childMonitor = DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
            if let cm = childMonitor {
                cm.setEventHandler(handler: { [weak self] in
                    self?.processTerminated(pid: shellPid, generation: generation)
                })
                if #available(macOS 10.12, *) {
                    cm.activate()
                } else {
                    // Fallback on earlier versions
                }
            }
#endif
            // Capture FD value for cleanup handler to close it safely after DispatchIO is done
            let fdToClose = childfd
            io = DispatchIO(type: .stream, fileDescriptor: childfd, queue: dispatchQueue, cleanupHandler: { _ in
                // Close file descriptor after DispatchIO has finished with it
                // This prevents EV_VANISHED crash by ensuring proper cleanup order
                close(fdToClose)
            })
            guard let io else {
                return
            }
            io.setLimit(lowWater: 1)
            io.setLimit(highWater: readSize)
            resumePtyRead(generation: generation)
        } else {
            running = false
            shellPid = 0
            delegate?.processTerminated(self, exitCode: nil)
        }
    }

    public func terminate()
    {
        guard running, !terminationRequested else { return }
        terminationRequested = true

        // Close DispatchIO - this will trigger the cleanup handler which closes file descriptors
        // The cleanup handler ensures FDs are closed AFTER DispatchIO is done with them,
        // preventing "BUG IN CLIENT OF LIBDISPATCH: Unexpected EV_VANISHED" crash
        io?.close()
        io = nil
        childfd = -1

        if shellPid != 0 {
            kill(shellPid, SIGTERM)
        }
    }
    
    var loggingDir: String? = nil
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     * - Parameter directory: location where the log files will be stored.
     */
    public func setHostLogging (directory: String?)
    {
        loggingDir = directory
    }
}
#endif
