package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class SafePolicyTest {
    private fun failure(kind: FailureKind = FailureKind.STARTUP_FAILED, safe: Boolean = false) = RunFailure(
        kind, 1, 1L, safe, null, emptyList(), emptyList(), diagnostics = null, upSeconds = null,
    )

    @Test fun startRequestModes() {
        assertEquals(SafeState.ON, SafePolicy.onStartRequest(SafeState.OFF, "safe"))
        assertEquals(SafeState.PROBATION, SafePolicy.onStartRequest(SafeState.ON, "normal"))
        assertEquals(SafeState.OFF, SafePolicy.onStartRequest(SafeState.OFF, "normal"))
        for (state in SafeState.entries) assertEquals(state, SafePolicy.onStartRequest(state, null))
    }

    @Test fun safeAndUncountedFailuresKeepPolicy() {
        for (state in SafeState.entries) {
            for (failure in listOf(failure(safe = true), failure(FailureKind.KILLED), failure(FailureKind.NO_SPACE))) {
                val result = SafePolicy.onFailure(state, 1, failure, true)
                assertEquals(state, result.state)
                assertEquals(1, result.strikes)
                assertFalse(result.restartSafe)
            }
        }
    }

    @Test fun failedProbationReturnsToSafeEvenWhenAutomaticModeIsOff() {
        val result = SafePolicy.onFailure(SafeState.PROBATION, 0, failure(), false)
        assertEquals(SafeState.ON, result.state)
        assertTrue(result.restartSafe)
        assertEquals(SafePolicy.REASON_PROBATION, result.reason)
    }

    @Test fun secondStrikeEntersSafeOnlyWhenAutomaticModeIsOn() {
        // Same threshold as Dart safe_mode_logic_test's shouldAutoStart(strikes: 2).
        val first = SafePolicy.onFailure(SafeState.OFF, 0, failure(), true)
        assertEquals(1, first.strikes)
        assertEquals(SafeState.OFF, first.state)
        val second = SafePolicy.onFailure(first.state, first.strikes, failure(), true)
        assertEquals(2, second.strikes)
        assertEquals(SafeState.ON, second.state)
        assertTrue(second.restartSafe)
        assertFalse(SafePolicy.onFailure(SafeState.OFF, 1, failure(), false).restartSafe)
    }
}
