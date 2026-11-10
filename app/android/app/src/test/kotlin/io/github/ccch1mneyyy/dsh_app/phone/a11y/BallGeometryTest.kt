package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.pet.Dock
import io.github.ccch1mneyyy.dsh_app.pet.EdgeSnap
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import org.junit.Assert.assertEquals
import org.junit.Test

/** The ball against the pill and the screen sides, at 2.625 px/dp (a 1080 px phone, 411 dp wide). */
class BallGeometryTest {
    private fun dp(v: Int) = Math.round(v * 2.625f)

    private val area = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)
    private val ball = dp(OverlayBall.BALL_DP)
    private val pad = dp(OverlayBall.PAD_DP)
    private val size = ball + 2 * pad
    private val edge = dp(OverlayBall.EDGE_DP)
    private val margin = BallGeometry.margin(edge, pad)

    // The pill as ControlOverlay places it on a phone: screen width less 12 dp, centred, root
    // padding 6 / 4 / 6 / 8, y = status bar + 2 dp.
    private val pillW = area.screenW - dp(12)
    private val pillY = area.top + dp(2)

    private fun end(side: Side) = BallGeometry.pillEnd(area.screenW, pillW, pillY, dp(6), dp(6), dp(4), ball, pad, side)

    @Test fun dockedBallsSitTheSameGapFromEitherSide() {
        val left = EdgeSnap.position(Dock(Side.LEFT, 0.3f), size, size, area, margin)
        val right = EdgeSnap.position(Dock(Side.RIGHT, 0.3f), size, size, area, margin)
        val leftGap = left.x + pad
        val rightGap = area.screenW - (right.x + pad + ball)
        assertEquals(edge, leftGap)
        assertEquals(edge, rightGap)
        // Mirror images: same height.
        assertEquals(left.y, right.y)
    }

    @Test fun theFoldStartsOnTheCardsEndCircle() {
        val cardLeft = (area.screenW - pillW) / 2 + dp(6)
        val cardRight = (area.screenW - pillW) / 2 + pillW - dp(6)
        val cardTop = pillY + dp(4)
        val r = end(Side.RIGHT)
        assertEquals(cardRight - ball, r.x + pad)
        assertEquals(cardTop, r.y + pad)
        val l = end(Side.LEFT)
        assertEquals(cardLeft, l.x + pad)
        assertEquals(r.y, l.y)
    }

    @Test fun onAPhoneTheBallDropsStraightDownFromThePillToItsDock() {
        // The pill's card is 12 dp from the sides too, so the glide after a fold is vertical.
        for (side in Side.values()) {
            val docked = EdgeSnap.position(Dock(side, 0.3f), size, size, area, margin)
            assertEquals("$side", docked.x, end(side).x)
        }
    }

    @Test fun onATabletTheCappedPillStillCentresItsEnds() {
        val wide = SafeArea(2560, 1600, left = 0, top = 64, right = 0, bottom = 48)
        val capped = Math.round(492 * 2f)
        val r = BallGeometry.pillEnd(wide.screenW, capped, 70, 12, 12, 8, 88, 12, Side.RIGHT)
        val l = BallGeometry.pillEnd(wide.screenW, capped, 70, 12, 12, 8, 88, 12, Side.LEFT)
        // The two end circles are mirror images about the screen's centre line.
        assertEquals(wide.screenW, (l.x + 12) + (r.x + 12 + 88))
    }
}
