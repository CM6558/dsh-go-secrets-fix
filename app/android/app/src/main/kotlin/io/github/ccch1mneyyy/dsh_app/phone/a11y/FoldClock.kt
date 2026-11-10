package io.github.ccch1mneyyy.dsh_app.phone.a11y

import java.util.EnumSet

/**
 * When the control pill dims and when it folds into the ball. Plain Kotlin: the overlay supplies
 * the clock and runs one timer at [nextAt].
 *
 * The pill stays open so the person can follow what DSH does. [dimMs] after it came up or was
 * last touched it dims to the 闲置时不透明度 the person chose; a touch brings it back to full.
 * Folding is the person's: the collapse key on the pill folds it ([foldByHand]) until they tap
 * the ball, for the rest of the task. With 「闲置时自动收起」 ([autoFold]) an idle open pill folds
 * after [foldMs] instead of dimming. A folded ball dims the same way.
 *
 * What needs the person's eyes or hands holds everything at full and as it is: a confirm card, a
 * handoff card, 插话 being typed, the 已停止 note. An automatic fold opens for the first three
 * ([OPENING]); a fold by hand stays. When the last hold goes, the counts start over. Status lines
 * from the agent are not touches.
 */
class FoldClock(val dimMs: Long = DIM_MS, val foldMs: Long = FOLD_MS) {
    enum class Hold { CONFIRM, HANDOFF, EDITING, STOPPED }

    enum class Tick { NONE, DIM, FOLD }

    /** 「闲置时自动收起」. */
    var autoFold = false
        private set

    /** Between [start] and [reset]: a pill is up (open or folded). */
    var running = false
        private set

    var folded = false
        private set

    /** Folded with the collapse key: only a tap on the ball opens it. */
    var byHand = false
        private set

    /** At the idle opacity rather than full. */
    var dimmed = false
        private set

    var dimAt: Long? = null
        private set

    var foldAt: Long? = null
        private set

    /** The next time [tick] has something to do; null while nothing is due. */
    val nextAt: Long? get() = listOfNotNull(dimAt, foldAt).minOrNull()

    private val holds: EnumSet<Hold> = EnumSet.noneOf(Hold::class.java)

    val held: Boolean get() = holds.isNotEmpty()

    fun isHeld(hold: Hold): Boolean = hold in holds

    /** The pill came up, open and at full. */
    fun start(now: Long) {
        if (running) return
        running = true
        folded = false
        byHand = false
        dimmed = false
        arm(now)
    }

    /** A finger on the pill or the ball: back to full, the counts start over. True when it was dimmed. */
    fun touch(now: Long): Boolean {
        if (!running) return false
        val was = dimmed
        dimmed = false
        arm(now)
        return was
    }

    /** Full and as it is until [release]; true when this opened an automatic fold ([OPENING] holds only). */
    fun hold(hold: Hold, @Suppress("UNUSED_PARAMETER") now: Long): Boolean {
        holds += hold
        dimmed = false
        dimAt = null
        foldAt = null
        if (running && folded && !byHand && hold in OPENING) {
            folded = false
            return true
        }
        return false
    }

    /** [hold] is over; with nothing else holding, the counts start again. */
    fun release(hold: Hold, now: Long) {
        if (!holds.remove(hold)) return
        arm(now)
    }

    /** The collapse key; true when it folded. Stays folded until [unfold]. */
    fun foldByHand(now: Long): Boolean {
        if (!running || folded) return false
        folded = true
        byHand = true
        dimmed = false
        arm(now)
        return true
    }

    /** A tap on the ball; true when it opened. */
    fun unfold(now: Long): Boolean {
        if (!running || !folded) return false
        folded = false
        byHand = false
        dimmed = false
        arm(now)
        return true
    }

    /** 「闲置时自动收起」 switched (applies at once to the pill on screen). */
    fun setAutoFold(on: Boolean, now: Long) {
        if (autoFold == on) return
        autoFold = on
        arm(now)
    }

    /** The timer went off: what changes now. */
    fun tick(now: Long): Tick {
        if (!running || held) return Tick.NONE
        val fold = foldAt
        if (fold != null && now >= fold && !folded) {
            folded = true
            byHand = false
            dimmed = false
            arm(now)
            return Tick.FOLD
        }
        val dim = dimAt
        if (dim != null && now >= dim && !dimmed) {
            dimmed = true
            dimAt = null
            return Tick.DIM
        }
        return Tick.NONE
    }

    /** The pill went away. Holds stay with the cards that set them. */
    fun reset() {
        running = false
        folded = false
        byHand = false
        dimmed = false
        dimAt = null
        foldAt = null
    }

    /** An open pill with 自动收起 folds when idle; anything else dims (unless it already has). */
    private fun arm(now: Long) {
        dimAt = null
        foldAt = null
        if (!running || held) return
        if (!folded && autoFold) foldAt = now + foldMs else if (!dimmed) dimAt = now + dimMs
    }

    companion object {
        /** 3 s: long enough to read the line and reach a key, then out of the way. */
        const val DIM_MS = 3_000L

        /** 3.5 s for 「闲置时自动收起」. */
        const val FOLD_MS = 3_500L

        /** Holds that ask something of the person: an automatic fold opens for them. */
        val OPENING: Set<Hold> = EnumSet.of(Hold.CONFIRM, Hold.HANDOFF, Hold.EDITING)
    }
}
