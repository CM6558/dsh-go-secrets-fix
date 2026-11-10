package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayAccessTest {
    @Test fun accessibilityServiceNeedsNothingElse() {
        assertEquals(OverlayPermission.ACCESSIBILITY, OverlayAccess.permission(true, false, null))
        assertEquals(OverlayPermission.ACCESSIBILITY, OverlayAccess.permission(true, false, AddResult.FAILED))
        assertEquals(OverlayHost.ACCESSIBILITY, OverlayAccess.host(true, AddResult.FAILED))
    }

    @Test fun grantedWhenTheWindowWentIn() {
        assertEquals(OverlayPermission.GRANTED, OverlayAccess.permission(false, true, AddResult.OK))
        assertEquals(OverlayPermission.GRANTED, OverlayAccess.permission(false, true, null))
        // canDrawOverlays says no, but the window went in (a vendor build that lies): it works.
        assertEquals(OverlayPermission.GRANTED, OverlayAccess.permission(false, false, AddResult.OK))
        assertEquals(OverlayHost.APPLICATION, OverlayAccess.host(false, AddResult.OK))
    }

    @Test fun vendorSwitchOffIsBlockedNotGranted() {
        // vivo: canDrawOverlays true, addView refused.
        assertEquals(OverlayPermission.BLOCKED, OverlayAccess.permission(false, true, AddResult.FAILED))
        assertEquals(OverlayHost.NONE, OverlayAccess.host(false, AddResult.FAILED))
    }

    @Test fun deniedWithoutPermission() {
        assertEquals(OverlayPermission.DENIED, OverlayAccess.permission(false, false, null))
        assertEquals(OverlayPermission.DENIED, OverlayAccess.permission(false, false, AddResult.FAILED))
        // Untried: still worth one attempt.
        assertEquals(OverlayHost.APPLICATION, OverlayAccess.host(false, null))
    }

    @Test fun retriesAfterAFailure() {
        val failedAt = 1_000L
        // Nothing failed: nothing to forget.
        assertTrue(OverlayAccess.retry(null, 0, 5, canDraw = false, canDrawChanged = false))
        // The person flipped the system switch.
        assertTrue(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + 1, canDraw = true, canDrawChanged = true))
        // Reported granted but refused: try again after a while (the vendor switch may have changed).
        assertFalse(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + OverlayAccess.RETRY_MS - 1, canDraw = true, canDrawChanged = false))
        assertTrue(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + OverlayAccess.RETRY_MS, canDraw = true, canDrawChanged = false))
        // Plainly denied: wait for the permission to change, however long.
        assertFalse(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + 10 * OverlayAccess.RETRY_MS, canDraw = false, canDrawChanged = false))
    }

    @Test fun wireNamesMatchDart() {
        assertEquals(listOf("accessibility", "granted", "blocked", "denied"), OverlayPermission.values().map { it.wire })
    }
}
