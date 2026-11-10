package io.github.ccch1mneyyy.dsh_app.icons

import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.FROST
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.INK
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.MIST
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.MIST_ALT
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.NIGHT
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.ORIGINAL
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.STATE_DEFAULT
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.STATE_DISABLED
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.STATE_ENABLED
import org.junit.Assert.*
import org.junit.Test
import kotlin.random.Random

class LauncherIconsTest {

    /** PackageManager's stored settings, as the plugin applies them (enable list, then disable). */
    private class Device {
        val states = HashMap<String, Int>()
        val writes = ArrayList<LauncherIcons.Step>()
        val stateOf: (String) -> Int = { states[it] ?: STATE_DEFAULT }

        fun on() = LauncherIcons.aliases.filter { LauncherIcons.isOn(it, stateOf(it.className)) }

        fun apply(plan: LauncherIcons.Plan, afterEach: () -> Unit = {}) {
            for (step in plan.enable + plan.disable) {
                states[step.className] = step.state
                writes += step
                afterEach()
            }
        }
    }

    private fun alias(variant: String) = LauncherIcons.aliases.first { it.variant == variant && it !== ORIGINAL }

    @Test fun aFreshInstallShowsMist() {
        val device = Device()
        assertEquals(listOf(ORIGINAL), device.on())
        assertEquals(MIST, LauncherIcons.current(device.stateOf, null))
        assertTrue(LauncherIcons.plan(MIST, device.stateOf, originalInUse = false).isEmpty)
    }

    @Test fun theFirstSwitchEnablesTheNewEntryThenDisablesTheOriginal() {
        val device = Device()
        val plan = LauncherIcons.plan(NIGHT, device.stateOf, originalInUse = false)
        assertEquals("[LauncherNight=$STATE_ENABLED]", plan.enable.toString())
        assertEquals("[LauncherMist=$STATE_DISABLED]", plan.disable.toString())
        assertFalse(plan.deferred)
        device.apply(plan)
        assertEquals(listOf(alias(NIGHT)), device.on())
        assertEquals(NIGHT, LauncherIcons.current(device.stateOf, NIGHT))
    }

    @Test fun theOriginalWaitsWhileATaskOpenedThroughItIsAlive() {
        val device = Device()
        val plan = LauncherIcons.plan(FROST, device.stateOf, originalInUse = true)
        assertTrue(plan.deferred)
        assertTrue(plan.disable.isEmpty())
        device.apply(plan)
        assertEquals(listOf(ORIGINAL, alias(FROST)), device.on())
        // The launcher shows the pick (the original only waits), with or without the remembered choice.
        assertEquals(FROST, LauncherIcons.current(device.stateOf, FROST))
        assertEquals(FROST, LauncherIcons.current(device.stateOf, null))
        assertEquals(alias(FROST), LauncherIcons.aliasFor(FROST, device.stateOf))
        // In the background (or at the next start) it goes.
        val later = LauncherIcons.plan(FROST, device.stateOf, originalInUse = false)
        assertTrue(later.enable.isEmpty())
        assertEquals("[LauncherMist=$STATE_DISABLED]", later.disable.toString())
        device.apply(later)
        assertEquals(listOf(alias(FROST)), device.on())
    }

    @Test fun pickingMistWhileTheOriginalWaitsKeepsTheOriginal() {
        val device = Device()
        device.apply(LauncherIcons.plan(INK, device.stateOf, originalInUse = true))
        val back = LauncherIcons.plan(MIST, device.stateOf, originalInUse = true)
        assertSame(ORIGINAL, back.target)
        assertTrue(back.enable.isEmpty())
        assertEquals("[LauncherInk=$STATE_DEFAULT]", back.disable.toString())
        assertFalse(back.deferred)
        device.apply(back)
        assertEquals(listOf(ORIGINAL), device.on())
        assertEquals(MIST, LauncherIcons.current(device.stateOf, MIST))
    }

    @Test fun mistComesBackThroughItsTwinAndOthersAreOnlyEverResetToDefault() {
        val device = Device()
        device.apply(LauncherIcons.plan(NIGHT, device.stateOf, originalInUse = false))
        val back = LauncherIcons.plan(MIST, device.stateOf, originalInUse = false)
        assertSame(MIST_ALT, back.target)
        assertEquals("[LauncherMistAlt=$STATE_ENABLED]", back.enable.toString())
        assertEquals("[LauncherNight=$STATE_DEFAULT]", back.disable.toString())
        device.apply(back)
        assertEquals(listOf(MIST_ALT), device.on())
        assertEquals(MIST, LauncherIcons.current(device.stateOf, null))
        // Away from 雾蓝 again: its twin goes back to the manifest's "off", nothing is DISABLED.
        val again = LauncherIcons.plan(INK, device.stateOf, originalInUse = true)
        assertEquals("[LauncherMistAlt=$STATE_DEFAULT]", again.disable.toString())
        assertFalse(again.deferred)
    }

    @Test fun anyWalkKeepsOneEntryAndDisablesTheOriginalAtMostOnce() {
        val random = Random(7)
        repeat(200) {
            val device = Device()
            var chosen: String? = null
            repeat(30) {
                val pick = LauncherIcons.variants.random(random)
                val inUse = random.nextBoolean()
                chosen = pick
                // New entry first: never a moment without one.
                device.apply(LauncherIcons.plan(pick, device.stateOf, inUse)) { assertTrue(device.on().isNotEmpty()) }
                assertEquals(pick, LauncherIcons.current(device.stateOf, chosen))
                val on = device.on()
                assertTrue(on.toString(), on.size == 1 || (on.size == 2 && ORIGINAL in on))
                if (random.nextInt(3) == 0) {
                    // The app went to the background: the waiting switch-off happens.
                    device.apply(LauncherIcons.plan(LauncherIcons.current(device.stateOf, chosen), device.stateOf, false))
                    assertEquals(1, device.on().size)
                    assertEquals(pick, LauncherIcons.current(device.stateOf, null))
                }
            }
            val disabled = device.writes.filter { it.state == STATE_DISABLED }
            assertTrue(disabled.all { it.className == ORIGINAL.className })
            assertTrue(disabled.size <= 1)
            assertTrue(device.writes.none { it.className == ORIGINAL.className && it.state != STATE_DISABLED })
        }
    }

    @Test fun anInterruptedSwitchIsSettledTowardsTheLastPick() {
        // Killed between "enable frost" and "disable night": two entries, the pick remembered.
        val device = Device()
        device.states[ORIGINAL.className] = STATE_DISABLED
        device.states[alias(NIGHT).className] = STATE_ENABLED
        device.states[alias(FROST).className] = STATE_ENABLED
        assertEquals(FROST, LauncherIcons.current(device.stateOf, FROST))
        device.apply(LauncherIcons.plan(FROST, device.stateOf, originalInUse = false))
        assertEquals(listOf(alias(FROST)), device.on())
    }

    @Test fun noEntryAtAllIsRepairedWithMist() {
        val device = Device()
        device.states[ORIGINAL.className] = STATE_DISABLED
        assertTrue(device.on().isEmpty())
        assertEquals(MIST, LauncherIcons.current(device.stateOf, NIGHT))
        device.apply(LauncherIcons.plan(MIST, device.stateOf, originalInUse = false))
        assertEquals(listOf(MIST_ALT), device.on())
    }

    @Test fun userDisabledCountsAsOff() {
        val device = Device()
        device.states[alias(INK).className] = 3 // COMPONENT_ENABLED_STATE_DISABLED_USER
        assertFalse(LauncherIcons.isOn(alias(INK), 3))
        assertEquals(MIST, LauncherIcons.current(device.stateOf, INK))
    }

    @Test(expected = IllegalArgumentException::class)
    fun unknownIconsAreRefused() {
        LauncherIcons.plan("rainbow", Device().stateOf, originalInUse = false)
    }

    @Test fun everyVariantHasExactlyOneAliasBesidesTheOriginal() {
        assertEquals(listOf(MIST, NIGHT, FROST, INK), LauncherIcons.variants)
        for (variant in LauncherIcons.variants) {
            assertEquals(1, LauncherIcons.aliases.count { it.variant == variant && it !== ORIGINAL })
        }
        assertEquals(listOf(ORIGINAL), LauncherIcons.aliases.filter { it.enabledByManifest })
    }
}
