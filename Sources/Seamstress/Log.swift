import Foundation
import os

enum SeamstressLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.seamstress"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let layout = Logger(subsystem: subsystem, category: "layout")
}
