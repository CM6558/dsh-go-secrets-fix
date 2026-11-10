package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.phone.a11y.FoldClock.Hold
import io.github.ccch1mneyyy.dsh_app.phone.a11y.FoldClock.Tick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FoldClockTest {
    private val dim = FoldClock.DIM_MS
    private val fold = FoldClock.FOLD_MS

    private fun open(now: Long = 0, auto: Boolean = false) = FoldClock().apply {
        setAutoFold(auto, now)
        start(now)
    }

    // ---- 默认：一直展开，闲置变淡 ----------------------------------------------------------------

    @Test fun byDefaultItStaysOpenAndOnlyDims() {
        val c = open(1_000)
        assertFalse(c.autoFold)
        assertEquals(1_000 + dim, c.nextAt)
        assertEquals(Tick.NONE, c.tick(1_000 + dim - 1))
        assertEquals(Tick.DIM, c.tick(1_000 + dim))
        assertTrue(c.dimmed)
        assertFalse(c.folded)
        // Nothing more after that, however long the agent works.
        assertNull(c.nextAt)
        assertEquals(Tick.NONE, c.tick(1_000 + 100 * dim))
        assertFalse(c.folded)
    }

    @Test fun idleIsAboutThreeSeconds() {
        assertTrue(dim in 2_500..3_500)
    }

    @Test fun aTouchBringsItBackToFullAndCountsAgain() {
        val c = open()
        c.tick(dim)
        assertTrue(c.touch(10_000))
        assertFalse(c.dimmed)
        assertEquals(10_000 + dim, c.nextAt)
        // A touch on a pill at full is no change, but restarts the count.
        assertFalse(c.touch(11_000))
        assertEquals(11_000 + dim, c.nextAt)
        assertEquals(Tick.DIM, c.tick(11_000 + dim))
    }

    @Test fun statusLinesAreNotTouches() {
        // Only touch() restarts the count: the agent working (new status lines) lets it dim.
        val c = open()
        assertEquals(Tick.DIM, c.tick(dim))
    }

    // ---- 卡片与插话：永远不透明 --------------------------------------------------------------------

    @Test fun cardsTypingAndTheStopNoteKeepItAtFull() {
        for (h in Hold.values()) {
            val c = open()
            c.tick(dim)
            assertTrue(c.dimmed)
            c.hold(h, dim + 1)
            assertFalse("$h brings it to full", c.dimmed)
            assertNull(c.nextAt)
            assertEquals(Tick.NONE, c.tick(100_000))
            assertFalse("$h keeps it at full", c.dimmed)
            c.release(h, 200_000)
            // A whole idle span from when the card went.
            assertEquals(200_000 + dim, c.nextAt)
        }
    }

    @Test fun overlappingHoldsWaitForTheLast() {
        val c = open()
        c.hold(Hold.EDITING, 100)
        c.hold(Hold.CONFIRM, 200)
        c.release(Hold.EDITING, 300)
        assertNull(c.nextAt)
        assertTrue(c.held)
        c.release(Hold.CONFIRM, 400)
        assertEquals(400 + dim, c.nextAt)
        // Releasing what isn't held changes nothing.
        c.release(Hold.HANDOFF, 900)
        assertEquals(400 + dim, c.nextAt)
    }

    // ---- 手动收起：本次任务里保持，直到点开 ---------------------------------------------------------

    @Test fun theCollapseKeyFoldsUntilTheBallIsTapped() {
        val c = open()
        assertTrue(c.foldByHand(500))
        assertTrue(c.folded)
        assertTrue(c.byHand)
        // The ball is at full when it appears, then dims like the pill.
        assertFalse(c.dimmed)
        assertEquals(500 + dim, c.nextAt)
        assertEquals(Tick.DIM, c.tick(500 + dim))
        // Nothing opens it on its own, however long.
        assertEquals(Tick.NONE, c.tick(10 * 60_000))
        assertTrue(c.folded)
        // A touch on the ball (a drag) brings it to full, still folded.
        assertTrue(c.touch(700_000))
        assertTrue(c.folded)
        assertTrue(c.unfold(800_000))
        assertFalse(c.folded)
        assertFalse(c.byHand)
        assertEquals(800_000 + dim, c.nextAt)
        // Folding twice is nothing.
        c.foldByHand(900_000)
        assertFalse(c.foldByHand(900_001))
    }

    @Test fun aFoldByHandStaysThroughCardsAndTyping() {
        val c = open()
        c.foldByHand(0)
        for (h in Hold.values()) {
            assertFalse("$h doesn't open a fold by hand", c.hold(h, 1))
            assertTrue(c.folded)
            c.release(h, 2)
        }
        assertTrue(c.byHand)
    }

    @Test fun aFoldByHandEndsWithThePill() {
        val c = open()
        c.foldByHand(0)
        c.reset()
        assertFalse(c.running)
        assertFalse(c.folded)
        assertFalse(c.byHand)
        // The next task's pill starts open.
        c.start(10)
        assertFalse(c.folded)
        assertEquals(10 + dim, c.nextAt)
    }

    // ---- 「闲置时自动收起」：默认关，开了就是 3.5 s 缩球 ------------------------------------------

    @Test fun autoFoldFoldsAnIdleOpenPillInsteadOfDimmingIt() {
        val c = open(auto = true)
        assertEquals(fold, c.nextAt)
        assertEquals(Tick.NONE, c.tick(fold - 1))
        assertFalse(c.dimmed)
        assertEquals(Tick.FOLD, c.tick(fold))
        assertTrue(c.folded)
        assertFalse(c.byHand)
        // The ball then dims.
        assertEquals(fold + dim, c.nextAt)
        assertEquals(Tick.DIM, c.tick(fold + dim))
    }

    @Test fun anAutomaticFoldOpensForWhatAsksSomethingOfThePerson() {
        for (h in FoldClock.OPENING) {
            val c = open(auto = true)
            c.tick(fold)
            assertTrue("$h opens it", c.hold(h, fold + 1))
            assertFalse(c.folded)
            // Held: no fold while the card is up.
            assertEquals(Tick.NONE, c.tick(10 * fold))
            c.release(h, 100_000)
            assertEquals(100_000 + fold, c.nextAt)
        }
        // The 已停止 note keeps the ball as it is.
        val c = open(auto = true)
        c.tick(fold)
        assertFalse(c.hold(Hold.STOPPED, fold + 1))
        assertTrue(c.folded)
    }

    @Test fun switchingAutoFoldAppliesToThePillOnScreen() {
        val c = open()
        c.tick(dim)
        assertTrue(c.dimmed)
        c.setAutoFold(true, 10_000)
        assertEquals(10_000 + fold, c.nextAt)
        assertEquals(Tick.FOLD, c.tick(10_000 + fold))
        c.unfold(20_000)
        // Off again: an open pill only dims.
        c.setAutoFold(false, 20_000)
        assertEquals(20_000 + dim, c.nextAt)
        assertEquals(Tick.DIM, c.tick(20_000 + dim))
        assertFalse(c.folded)
    }

    @Test fun aTapOnTheBallAfterAnAutomaticFoldCountsAgain() {
        val c = open(auto = true)
        c.tick(fold)
        assertTrue(c.unfold(10_000))
        assertEquals(10_000 + fold, c.nextAt)
        assertEquals(Tick.FOLD, c.tick(10_000 + fold))
    }

    // ---- 其他 --------------------------------------------------------------------------------------

    @Test fun aHoldBeforeThePillComesUpKeepsItAtFullFromTheStart() {
        val c = FoldClock()
        c.hold(Hold.CONFIRM, 0)
        c.start(10)
        assertNull(c.nextAt)
        assertEquals(Tick.NONE, c.tick(100_000))
        c.release(Hold.CONFIRM, 20_000)
        assertEquals(20_000 + dim, c.nextAt)
    }

    @Test fun notRunningNothingHappens() {
        val c = FoldClock()
        assertFalse(c.touch(0))
        assertFalse(c.foldByHand(0))
        assertFalse(c.unfold(0))
        assertEquals(Tick.NONE, c.tick(100_000))
        assertNull(c.nextAt)
    }

    @Test fun startTwiceKeepsTheFirstCount() {
        val c = open(0)
        c.start(2_000)
        assertEquals(dim, c.nextAt)
    }
}
