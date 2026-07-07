import Foundation
import Testing
@testable import ReaderCore

@Suite struct SessionCodecTests {
    private func sampleSnapshot() -> SessionSnapshot {
        var history = NavigationHistory()
        history.push(NavEntry(pageIndex: 12, point: CGPoint(x: 0, y: 700), scaleFactor: 1.25))
        let tab = TabState(
            fileBookmark: Data([0x01, 0x02, 0x03]),
            pathHint: "/Users/example/Books/Hatcher/Algebraic Topology.pdf",
            pageIndex: 42,
            destinationPoint: CGPoint(x: 0, y: 512),
            scaleFactor: 1.25,
            autoScales: false,
            displayModeRaw: 1,
            history: history
        )
        let window = WindowState(
            frame: CGRect(x: 100, y: 200, width: 1200, height: 900),
            tabs: [tab],
            activeTabID: tab.id
        )
        return SessionSnapshot(windows: [window])
    }

    @Test func roundTripPreservesEverything() throws {
        let original = sampleSnapshot()
        let data = try SessionCodec.encode(original)
        let decoded = try SessionCodec.decode(data)
        #expect(decoded == original)
    }

    @Test func encodedFormIsStableJSON() throws {
        let snapshot = sampleSnapshot()
        let first = try SessionCodec.encode(snapshot)
        let second = try SessionCodec.encode(snapshot)
        #expect(first == second)
        let object = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == SessionSnapshot.currentSchemaVersion)
    }

    @Test func decodeRejectsFutureVersion() throws {
        var snapshot = sampleSnapshot()
        snapshot.schemaVersion = SessionSnapshot.currentSchemaVersion
        var object = try JSONSerialization.jsonObject(with: SessionCodec.encode(snapshot)) as! [String: Any]
        object["schemaVersion"] = SessionSnapshot.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: SessionCodecError.unsupportedVersion(
            found: SessionSnapshot.currentSchemaVersion + 1,
            supported: SessionSnapshot.currentSchemaVersion
        )) {
            try SessionCodec.decode(data)
        }
    }

    @Test func decodeRejectsMissingVersion() throws {
        let data = try JSONSerialization.data(withJSONObject: ["windows": []])
        #expect(throws: SessionCodecError.missingVersion) {
            try SessionCodec.decode(data)
        }
    }

    @Test func decodeRunsMigrationsOldestFirst() throws {
        // Fabricate an "old" version-0 file whose windows key was named
        // differently, and migrate it forward with an injected migration.
        let old: [String: Any] = ["schemaVersion": 0, "openWindows": []]
        let data = try JSONSerialization.data(withJSONObject: old)

        let migrations: [Int: SessionCodec.Migration] = [
            0: { object in
                object["windows"] = object.removeValue(forKey: "openWindows") ?? []
            }
        ]
        let decoded = try SessionCodec.decode(data, migrations: migrations)
        #expect(decoded.schemaVersion == SessionSnapshot.currentSchemaVersion)
        #expect(decoded.windows.isEmpty)
    }

    @Test func emptySessionRoundTrips() throws {
        let empty = SessionSnapshot()
        let decoded = try SessionCodec.decode(try SessionCodec.encode(empty))
        #expect(decoded == empty)
    }
}
