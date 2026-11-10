package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class NetworkAccessTest {
    @Test fun logsOnlyChanges() {
        val access = NetworkAccess()
        // The first report after registering is usually "not blocked": nothing to say.
        assertNull(access.onBlocked(nowBlocked = false, inForeground = true))
        assertFalse(access.isBlocked)

        val cut = access.onBlocked(nowBlocked = true, inForeground = false)
        assertNotNull(cut)
        assertTrue(cut!!.contains("blocked this app's network"))
        assertTrue(cut.contains("app in background"))
        assertTrue(access.isBlocked)
        // Repeated reports (another network, a capability change) stay quiet.
        assertNull(access.onBlocked(nowBlocked = true, inForeground = false))

        val back = access.onBlocked(nowBlocked = false, inForeground = true)
        assertNotNull(back)
        assertTrue(back!!.contains("lifted"))
        assertTrue(back.contains("app in foreground"))
        assertFalse(access.isBlocked)
    }

    @Test fun keepsWhenTheLatestBlockStartedAfterItLifts() {
        val access = NetworkAccess()
        assertNull(access.blockedAt)
        access.onBlocked(nowBlocked = true, inForeground = false, now = 1_000)
        access.onBlocked(nowBlocked = true, inForeground = false, now = 2_000)
        assertEquals(1_000L, access.blockedAt)
        access.onBlocked(nowBlocked = false, inForeground = true, now = 3_000)
        assertEquals(1_000L, access.blockedAt)
        access.onBlocked(nowBlocked = true, inForeground = false, now = 4_000)
        assertEquals(4_000L, access.blockedAt)
        access.reset()
        assertEquals(4_000L, access.blockedAt)
    }

    @Test fun resetForgetsSilently() {
        val access = NetworkAccess()
        access.onBlocked(nowBlocked = true, inForeground = false)
        access.reset()
        assertFalse(access.isBlocked)
        // A new run starts clean: the next block is news again.
        assertNotNull(access.onBlocked(nowBlocked = true, inForeground = false))
    }

    @Test fun policyLineNamesEachSetting() {
        assertEquals(
            "[dsh-app] background policy: battery optimization on, data saver off, notifications on",
            NetworkAccess.policyLine(batteryExempt = false, dataSaverStatus = 1, notifications = true),
        )
        assertEquals(
            "[dsh-app] background policy: battery optimization off, data saver on, notifications off",
            NetworkAccess.policyLine(batteryExempt = true, dataSaverStatus = 3, notifications = false),
        )
        assertTrue(NetworkAccess.policyLine(true, 2, true).contains("data saver on, app exempt"))
        assertTrue(NetworkAccess.policyLine(true, 0, true).contains("data saver unknown"))
    }
}
