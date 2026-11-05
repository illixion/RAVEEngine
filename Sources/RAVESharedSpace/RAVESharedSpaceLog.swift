//
//  RAVESharedSpaceLog.swift
//  RAVESharedSpace
//

import Foundation

enum RAVESharedSpaceLog {
    /// The host app's bundle id, so these lines sit with the app's own in its console and traces.
    static let subsystem = Bundle.main.bundleIdentifier ?? "RAVESharedSpace"
}
