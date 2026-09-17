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

// MARK: - Conjoining jamo must not reach a host

/// Conjoining U+1100 jamo was sent as the lone-consonant preedit so a web editor
/// would not treat it as a finished letter and split the block. It also merges
/// with whatever follows it: typing into the middle of existing text ate the next
/// character when the syllable completed, in Slack, Claude and Chrome alike, and
/// only when a real character followed — a space was safe, because a space cannot
/// combine with a jamo.
@Suite("PreeditJamoForm")
struct PreeditJamoFormTests {
    @Test("A lone consonant preedit uses compatibility jamo everywhere")
    func loneConsonantUsesCompatibilityJamo() {
        // libhangul hands back choseong U+1105; what reaches the host must be
        // the standalone letter U+3139, which combines with nothing.
        let preedit = CompositionHelpers.preeditString(for: [0x1105])
        #expect(preedit.unicodeScalars.map(\.value) == [0x3139])
    }

    @Test("A completed syllable is unchanged")
    func completedSyllableUnchanged() {
        // Complete syllables already arrive precomposed and must stay that way.
        #expect(CompositionHelpers.preeditString(for: [0xB77C]) == "라")
    }

    @Test("A lone vowel also uses compatibility jamo")
    func loneVowelUsesCompatibilityJamo() {
        let preedit = CompositionHelpers.preeditString(for: [0x1161])   // jungseong A
        #expect(preedit.unicodeScalars.map(\.value) == [0x314F])
    }
}
