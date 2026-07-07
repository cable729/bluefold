/// ReaderPersistence owns the overlay library database (GRDB/SQLite):
/// books, hierarchical tags, collections, user bookmarks, and reading state.
/// It never touches Calibre's metadata.db.
public enum ReaderPersistenceInfo {
    public static let moduleName = "ReaderPersistence"
}
