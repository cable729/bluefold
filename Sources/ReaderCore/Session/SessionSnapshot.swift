import CoreGraphics
import Foundation

/// Persistable state of one reader window: geometry plus its tab strip.
public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Window frame in screen coordinates; nil lets the system place it.
    public var frame: CGRect?
    public var tabs: [TabState]
    public var activeTabID: UUID?

    public init(
        id: UUID = UUID(),
        frame: CGRect? = nil,
        tabs: [TabState] = [],
        activeTabID: UUID? = nil
    ) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

/// The whole app session — every window, every tab — as saved to disk and
/// restored at launch, browser-style.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var windows: [WindowState]

    public init(schemaVersion: Int = Self.currentSchemaVersion, windows: [WindowState] = []) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}
