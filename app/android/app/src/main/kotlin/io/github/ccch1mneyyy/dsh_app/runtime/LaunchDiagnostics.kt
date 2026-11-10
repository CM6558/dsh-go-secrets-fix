package io.github.ccch1mneyyy.dsh_app.runtime

/** One launch attempt, retained after exit but replaced before the next attempt. No preferences. */
class LaunchDiagnostics {
    @Volatile var selectedMode: String? = null
        private set
    @Volatile var fallbackReason: String? = null
        private set
    @Volatile var spawned = false
        private set
    @Volatile var failureReason: String? = null
        private set

    fun selected(direct: Boolean, fallback: String?) {
        selectedMode = if (direct) "direct" else "proot"
        fallbackReason = fallback
    }

    fun spawned() { spawned = true }
    fun failed(reason: String) { failureReason = reason }
    fun currentMode(alive: Boolean): String? = if (spawned && alive) selectedMode else null
}
