package io.github.ccch1mneyyy.dsh_app.nativemedia

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MicArbiterTest {
    @After fun tearDown() = MicArbiter.reset()

    @Test fun dictationStopsAListeningPluginFirst() {
        var yielded = 0
        val plugin = MicArbiter.Holder { yielded++ }
        assertTrue(MicArbiter.acquire(plugin))
        val token = MicArbiter.beginDictation()
        assertEquals(1, yielded)
        assertFalse("no plugin while dictating", MicArbiter.acquire(plugin))
        MicArbiter.endDictation(token)
        assertTrue(MicArbiter.acquire(plugin))
        MicArbiter.release(plugin)
        MicArbiter.beginDictation()
        assertEquals("a released plugin is not asked again", 1, yielded)
    }

    @Test fun anOldDictationsLateEndDoesNotFreeANewOne() {
        val first = MicArbiter.beginDictation()
        MicArbiter.beginDictation()
        MicArbiter.endDictation(first) // the old recorder finished closing on its thread
        assertTrue(MicArbiter.dictating)
        assertFalse(MicArbiter.acquire { })
    }
}
