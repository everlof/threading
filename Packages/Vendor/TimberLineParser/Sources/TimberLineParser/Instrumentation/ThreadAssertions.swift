//
//  ThreadAssertions.swift
//  TimberLineParser
//
//  Main thread assertions for ensuring heavy work runs off the main thread.
//

import Foundation

/// Thread assertions for debugging - ensures heavy work runs off the main thread
public enum ThreadAssertions {
    
    /// Assert that the current code is NOT running on the main thread.
    /// Only active in DEBUG builds.
    @inlinable
    public static func assertNotMainThread(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }
    
    /// Assert that the current code IS running on the main thread.
    /// Only active in DEBUG builds.
    @inlinable
    public static func assertMainThread(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }
}
