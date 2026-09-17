import Testing
import AppKit
@testable import PriTypeCore

// MARK: - Separating garbage coordinates from off-primary ones

/// The garbage filter required positive coordinates, but a display arranged left
/// of or below the primary has negative ones: a perfectly good caret rect there
/// was discarded, both resolve strategies "failed", and the Hanja candidate
/// window fell back to the cached rect and opened on the wrong monitor. What the
/// filter is actually for is denormal/NaN values like 1.6e-314.
@Suite("CursorRectGarbage")
struct CursorRectGarbageTests {
    @Test("Denormal floating-point garbage is rejected")
    func denormalRejected() {
        #expect(CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 1.6e-314, y: 19896, width: 1, height: 18)))
        #expect(CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 100, y: 5e-320, width: 1, height: 18)))
    }

    @Test("Non-finite coordinates are rejected")
    func nonFiniteRejected() {
        #expect(CursorRectResolver.rectLooksLikeGarbage(NSRect(x: CGFloat.nan, y: 100, width: 1, height: 18)))
        #expect(CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 100, y: CGFloat.infinity, width: 1, height: 18)))
    }

    @Test("An uninitialized zero origin is rejected")
    func zeroOriginRejected() {
        #expect(CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 0, y: 0, width: 1, height: 18)))
    }

    @Test("A zero-height rect is rejected")
    func zeroHeightRejected() {
        #expect(CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 100, y: 200, width: 1, height: 0)))
    }

    @Test("Negative coordinates are a real position, not garbage")
    func negativeCoordinatesAccepted() {
        // Secondary display arranged to the left of, or below, the primary.
        #expect(!CursorRectResolver.rectLooksLikeGarbage(NSRect(x: -1400, y: 500, width: 1, height: 18)))
        #expect(!CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 300, y: -800, width: 1, height: 18)))
    }

    @Test("An ordinary caret rect passes")
    func ordinaryRectAccepted() {
        #expect(!CursorRectResolver.rectLooksLikeGarbage(NSRect(x: 640, y: 480, width: 1, height: 18)))
    }
}
