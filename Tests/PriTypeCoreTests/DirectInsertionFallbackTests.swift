import Testing
import Foundation
@testable import PriTypeCore

// MARK: - What happens when direct insertion degrades mid-composition

/// DirectInsertionAdapter can degrade to marked text at runtime (fellBackToMarked)
/// while staying the same object. Two decisions keyed off "is this adapter direct
/// insertion?" are wrong once that happens.
@Suite("DirectInsertionFallback")
struct DirectInsertionFallbackTests {

    // finalize skips re-inserting the syllable because direct insertion already
    // wrote it as real text. After a fallback it did NOT: it lives only in the
    // host's marked range, and skipping the insert loses it on focus change.
    @Test("Finalize re-inserts once the adapter has fallen back to marked text")
    func fallbackMustReinsert() {
        #expect(!CompositionFinalizePlan.skipsReinsertion(
            deliveryMode: .directInsertion, renderingMarkedFallback: true),
            "the syllable is only marked text now; skipping the insert drops it")
    }

    @Test("Finalize still skips re-insertion while direct insertion is live")
    func directInsertionStillSkips() {
        #expect(CompositionFinalizePlan.skipsReinsertion(
            deliveryMode: .directInsertion, renderingMarkedFallback: false))
    }

    @Test("Marked text and immediate modes always re-insert")
    func otherModesReinsert() {
        #expect(!CompositionFinalizePlan.skipsReinsertion(
            deliveryMode: .markedText, renderingMarkedFallback: false))
        #expect(!CompositionFinalizePlan.skipsReinsertion(
            deliveryMode: .immediate, renderingMarkedFallback: false))
    }

    // Bailing left the already-written real text in the document and then drew the
    // same syllable again as marked text, so the host kept both.
    @Test("Bailing removes the real text it already wrote")
    func bailRemovesLivePreedit() {
        let range = DirectInsertionPlanner.removalRangeOnBail(livePreeditLength: 1, expectedCaret: 40)
        #expect(range == NSRange(location: 39, length: 1))
    }

    @Test("Nothing to remove when no live preedit is tracked")
    func bailWithNoLivePreedit() {
        #expect(DirectInsertionPlanner.removalRangeOnBail(livePreeditLength: 0, expectedCaret: 40) == nil)
    }

    @Test("An unknown or impossible caret removes nothing rather than guessing")
    func bailWithUnusableCaret() {
        #expect(DirectInsertionPlanner.removalRangeOnBail(livePreeditLength: 1, expectedCaret: NSNotFound) == nil)
        #expect(DirectInsertionPlanner.removalRangeOnBail(livePreeditLength: 3, expectedCaret: 2) == nil)
    }
}

// MARK: - Raw jamo depends on how the syllable is actually delivered

/// Conjoining U+1100 jamo keeps a MARKED composition open in a web editor. It is
/// meaningless — and gets stranded as real text — under direct insertion. Keying
/// it off the bundle id alone gets both cases wrong: a direct-insertion host that
/// degrades to marked text at runtime, or whose activation probe failed, then
/// marks compatibility jamo in ProseMirror and splits the block.
@Suite("RawJamoByDeliveryMode")
struct RawJamoByDeliveryModeTests {
    @Test("A web host composing with marked text gets raw jamo")
    func webHostMarkedTextGetsRawJamo() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.atlassian.confluence"] {
            #expect(ClientCompatibilityPolicy.usesRawJamoPreedit(bundleId: id, deliveryMode: .markedText),
                    "\(id) is a web editor and its marked composition needs the jamo")
        }
    }

    @Test("The same host composing by direct insertion does not")
    func directInsertionNeverGetsRawJamo() {
        for id in ["com.apple.Safari", "com.google.Chrome"] {
            #expect(!ClientCompatibilityPolicy.usesRawJamoPreedit(bundleId: id, deliveryMode: .directInsertion),
                    "\(id) would leave the conjoining jamo in the document as real text")
        }
    }

    @Test("Native hosts keep compatibility jamo in every mode")
    func nativeHostsUnaffected() {
        for mode in [InputDeliveryMode.markedText, .directInsertion, .immediate] {
            #expect(!ClientCompatibilityPolicy.usesRawJamoPreedit(bundleId: "com.kakao.KakaoTalkMac", deliveryMode: mode))
        }
    }
}
