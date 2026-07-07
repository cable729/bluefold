/// SyncKit syncs overlay-library data (tags, collections, bookmarks, reading
/// state) between devices via CloudKit. The engine sits behind a transport
/// protocol so the app runs fully offline/sync-less and tests use a fake.
public enum SyncKitInfo {
    public static let moduleName = "SyncKit"
}
