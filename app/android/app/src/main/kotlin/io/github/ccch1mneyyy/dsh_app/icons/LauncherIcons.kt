package io.github.ccch1mneyyy.dsh_app.icons

/**
 * 桌面图标: which `<activity-alias>` (AndroidManifest.xml) is the launcher entry, and how to move
 * between them. Pure, unit-tested on the JVM; [LauncherIconPlugin] reads and writes the states.
 *
 * Every alias points at MainActivity and carries only MAIN / LAUNCHER (plus the static shortcuts);
 * exactly one is enabled. Two rules keep the app on screen while it switches:
 *
 * - A component the system sees as explicitly DISABLED takes every task opened through it down
 *   with it (ActivityManagerService.cleanupDisabledPackageComponentsLocked → RecentTasks); one put
 *   back to DEFAULT does not. So every alias but [ORIGINAL] is `enabled="false"` in the manifest,
 *   and switching off one of those means DEFAULT, never DISABLED.
 * - [ORIGINAL] (enabled in the manifest: fresh installs need an entry) can only be switched off
 *   with DISABLED. That waits until no task of ours was opened through it ([Plan.deferred]), and
 *   it happens once: going back to 雾蓝 later uses its twin, [MIST_ALT].
 *
 * New entry first, old ones after, so the app never has none.
 */
internal object LauncherIcons {
    /** PackageManager.COMPONENT_ENABLED_STATE_*. */
    const val STATE_DEFAULT = 0
    const val STATE_ENABLED = 1
    const val STATE_DISABLED = 2

    const val MIST = "mist"
    const val NIGHT = "night"
    const val FROST = "frost"
    const val INK = "ink"

    /** In the picker's order; [MIST] is the default. */
    val variants = listOf(MIST, NIGHT, FROST, INK)

    /** The mipmap a variant's launcher entry uses (its alias's android:icon; LaunchThemesTest checks). */
    fun mipmapOf(variant: String): String = if (variant == MIST) "ic_launcher" else "ic_launcher_$variant"

    private const val PKG = "io.github.ccch1mneyyy.dsh_app"

    class Alias(val variant: String, val className: String, val enabledByManifest: Boolean) {
        override fun toString() = className.substringAfterLast('.')
    }

    /** The entry every install starts with. */
    val ORIGINAL = Alias(MIST, "$PKG.LauncherMist", enabledByManifest = true)

    /** 雾蓝 again, once [ORIGINAL] has been switched off. */
    val MIST_ALT = Alias(MIST, "$PKG.LauncherMistAlt", enabledByManifest = false)

    val aliases = listOf(
        ORIGINAL,
        MIST_ALT,
        Alias(NIGHT, "$PKG.LauncherNight", enabledByManifest = false),
        Alias(FROST, "$PKG.LauncherFrost", enabledByManifest = false),
        Alias(INK, "$PKG.LauncherInk", enabledByManifest = false),
    )

    /** Whether [alias] is a launcher entry when its stored setting is [state]. */
    fun isOn(alias: Alias, state: Int): Boolean = when (state) {
        STATE_ENABLED -> true
        STATE_DEFAULT -> alias.enabledByManifest
        else -> false
    }

    /**
     * The icon on the launcher. [chosen] is the last pick (it settles the in-between states a
     * switch passes through); otherwise an alias other than [ORIGINAL] wins, since [ORIGINAL] is
     * only still on next to one while its switch-off waits.
     */
    fun current(stateOf: (String) -> Int, chosen: String?): String {
        val on = aliases.filter { isOn(it, stateOf(it.className)) }
        if (chosen != null && on.any { it.variant == chosen }) return chosen
        return on.firstOrNull { it !== ORIGINAL }?.variant ?: MIST
    }

    /** The alias that shows [variant]: [ORIGINAL] for 雾蓝 while it is still on, else its own. */
    fun aliasFor(variant: String, stateOf: (String) -> Int): Alias =
        if (variant == MIST && isOn(ORIGINAL, stateOf(ORIGINAL.className))) ORIGINAL
        else aliases.first { it.variant == variant && it !== ORIGINAL }

    class Step(val className: String, val state: Int) {
        override fun toString() = "${className.substringAfterLast('.')}=$state"
    }

    /**
     * Apply [enable], then [disable] (each step a setComponentEnabledSetting). [deferred]: [ORIGINAL]
     * stays on for now and has to be switched off later (see [plan]).
     */
    class Plan(val target: Alias, val enable: List<Step>, val disable: List<Step>, val deferred: Boolean) {
        val isEmpty get() = enable.isEmpty() && disable.isEmpty()
    }

    /**
     * Makes [variant] the only launcher entry. [originalInUse]: a task of ours was opened through
     * [ORIGINAL], so switching it off now would close the app (it is then left on, [Plan.deferred]).
     */
    fun plan(variant: String, stateOf: (String) -> Int, originalInUse: Boolean): Plan {
        require(variant in variants) { "unknown icon $variant" }
        val target = aliasFor(variant, stateOf)
        val enable = if (isOn(target, stateOf(target.className))) emptyList()
        else listOf(Step(target.className, if (target.enabledByManifest) STATE_DEFAULT else STATE_ENABLED))
        val disable = ArrayList<Step>()
        var deferred = false
        for (alias in aliases) {
            if (alias === target || !isOn(alias, stateOf(alias.className))) continue
            when {
                !alias.enabledByManifest -> disable += Step(alias.className, STATE_DEFAULT)
                originalInUse -> deferred = true
                else -> disable += Step(alias.className, STATE_DISABLED)
            }
        }
        return Plan(target, enable, disable, deferred)
    }
}
