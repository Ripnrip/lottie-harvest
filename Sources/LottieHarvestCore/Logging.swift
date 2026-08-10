import Foundation
import os

/// Centralized `os.Logger` for the package (structured, emoji-scannable).
extension Logger {
    /// Per-subsystem convenience so call sites read cleanly.
    private static let subsystem = "com.earendil.LottieHarvest"

    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let download  = Logger(subsystem: subsystem, category: "download")
    static let validate  = Logger(subsystem: subsystem, category: "validate")
    static let storage   = Logger(subsystem: subsystem, category: "storage")
    static let catalog   = Logger(subsystem: subsystem, category: "catalog")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
