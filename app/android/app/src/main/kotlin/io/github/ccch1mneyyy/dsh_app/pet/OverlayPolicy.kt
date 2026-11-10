package io.github.ccch1mneyyy.dsh_app.pet

/** A short line over the pet; tapping it opens [sessionId] on [host]. */
data class PetBubble(
    val id: String,
    val kind: String,
    /** The whole line as Dart wrote it: 「做完了」「标题 · 等你确认」「3 个对话做完了」. */
    val text: String,
    /** The conversation's title (masked), for the open-notice fallback only. */
    val title: String?,
    val sessionId: String?,
    val host: String?,
    /** Device clock; the bubble goes at this time without waiting for another push. */
    val untilMs: Long,
) {
    /** What the bubble shows: Dart composes the line, the overlay only draws it. */
    val line: String get() = text
}

/**
 * What Dart pushes on `dsh/pet_overlay` `push`: the state PetMood reduced, the tier, the bubble, the most relevant conversation, whether anything
 * is going on, the pack and size. Nothing is reduced again here.
 */
data class PetPush(
    /** Pack id; null when the person picked 「不显示」 (`none`). */
    val packId: String?,
    val state: String,
    val tier: Int,
    val bubble: PetBubble?,
    /** The most relevant conversation: where a tap on the pet goes. */
    val sessionId: String?,
    val host: String?,
    /** A turn runs, something waits for the person, or a bubble is up. */
    val active: Boolean,
    /** small / medium / large. */
    val size: String,
    /** 安静模式 or pet alerts off: no bubbles, so results still need their notification to ring. */
    val quiet: Boolean = false,
    val reduceMotion: Boolean = false,
) {
    /** Idle and asleep play a still frame with an occasional action; the rest plays at full speed. */
    val calm: Boolean get() = state == PetPack.IDLE || state == SLEEPING || state == ROAM

    /** A result or a request: worth sliding a tucked-away pet back out for. */
    val calling: Boolean get() = state in CALLING

    companion object {
        const val SLEEPING = "sleeping"
        const val ROAM = "roam"
        val CALLING = setOf("attention", "error", "notification")
        private const val MAX_TEXT = 48
        private const val MAX_TITLE = 40
        private const val MAX_ID = 300
        private val ID = Regex("[a-z0-9][a-z0-9._-]*")

        /** From the channel's argument map; anything malformed falls back to safe values. */
        fun fromMap(m: Map<*, *>, now: Long): PetPush {
            val state = (m["state"] as? String)?.takeIf { it in PetPack.STATES } ?: PetPack.IDLE
            val bubble = (m["bubble"] as? Map<*, *>)?.let { raw ->
                val text = clean(raw["text"] as? String, MAX_TEXT) ?: return@let null
                val session = clean(raw["sessionId"] as? String, MAX_ID)
                PetBubble(
                    id = clean(raw["id"] as? String, MAX_ID) ?: "${raw["kind"]}|$session|$text",
                    kind = (raw["kind"] as? String) ?: "done",
                    text = text,
                    title = clean(raw["title"] as? String, MAX_TITLE),
                    sessionId = session,
                    host = (raw["host"] as? String)?.takeIf { it.length <= 2_000 },
                    untilMs = (raw["untilMs"] as? Number)?.toLong()?.coerceIn(now, now + MAX_BUBBLE_MS) ?: (now + DEFAULT_BUBBLE_MS),
                )
            }
            // The target conversation: `target {host, sessionId}` (pet_state.dart), or top-level fields.
            val target = m["target"] as? Map<*, *>
            val pack = (m["packId"] as? String)?.takeIf { it != "none" && it.length <= 64 && ID.matches(it) }
            val activeRaw = m["active"] as? Boolean
            return PetPush(
                packId = pack,
                state = state,
                tier = ((m["tier"] as? Number)?.toInt() ?: 0).coerceIn(0, 9),
                bubble = bubble,
                sessionId = clean((target?.get("sessionId") ?: m["sessionId"]) as? String, MAX_ID),
                host = ((target?.get("host") ?: m["host"]) as? String)?.takeIf { it.length <= 2_000 },
                // Older senders without `active`: busy states and a bubble count.
                active = activeRaw ?: (state in BUSY || bubble != null),
                size = (m["size"] as? String)?.takeIf { it == "small" || it == "medium" || it == "large" } ?: "medium",
                quiet = m["quiet"] == true,
                reduceMotion = m["reduceMotion"] == true,
            )
        }

        private val BUSY = setOf("thinking", "working", "juggling", "sweeping", "notification", "carrying")
        const val DEFAULT_BUBBLE_MS = 6_000L
        private const val MAX_BUBBLE_MS = 60_000L

        /** Trimmed, whitespace folded, cut to [max] code points with an ellipsis; blank → null. */
        fun clean(s: String?, max: Int): String? {
            val t = s?.trim()?.replace(Regex("\\s+"), " ")?.takeIf { it.isNotEmpty() } ?: return null
            if (t.codePointCount(0, t.length) <= max) return t
            return t.substring(0, t.offsetByCodePoints(0, max - 1)) + "…"
        }
    }
}

/**
 * The bubble Dart says is up, minus the ones already dealt with: tapped away here, or pushed
 * while the app was on screen (the chat page's pet said it there).
 */
class BubbleSlot {
    private val done = object : LinkedHashMap<String, Unit>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>?) = size > 64
    }
    private var current: PetBubble? = null

    /** The bubble of the latest push; [inApp] marks it said already. Returns true for a new bubble. */
    fun set(b: PetBubble?, inApp: Boolean): Boolean {
        if (b == null || done.containsKey(b.id)) {
            current = null
            return false
        }
        if (inApp) {
            done[b.id] = Unit
            current = null
            return false
        }
        val fresh = current?.id != b.id
        current = b
        return fresh
    }

    fun current(now: Long): PetBubble? {
        if (current != null && now >= current!!.untilMs) current = null
        return current
    }

    /** Tapped: gone for good, even if Dart pushes it again. */
    fun dismiss() {
        current?.let { done[it.id] = Unit }
        current = null
    }
}

enum class Visibility { HIDDEN, SHOWN, PAUSED }

/**
 * One evaluation: whether the window shows, whether it is tucked half off the edge, whether the
 * overlay needs its own foreground service, the bubble, and when to evaluate again without any
 * event ([wakeAt]).
 */
data class Decision(
    val visibility: Visibility,
    val tucked: Boolean,
    val ownService: Boolean,
    val bubble: PetBubble?,
    val wakeAt: Long?,
    val why: String,
)

/**
 * The out-of-app pet's visibility and power rules:
 *
 * - shows only while the app is in the background and something is going on ([PetPush.active]),
 *   or always with 「一直显示」;
 * - hides while the app is on screen, during a phone-control task (its own status pill is up),
 *   and for the rest of the day after 「今天不再显示」;
 * - pauses with the screen off or locked;
 * - collapses [IDLE_COLLAPSE_MS] after the last thing going on (not with 「一直显示」);
 * - tucks half off the edge after [TUCK_AFTER_MS] without a touch or a new call for attention;
 * - keeps the process up with its own foreground service only when it is out and DshService is
 *   not running (remote hosts only).
 */
class OverlayMachine {
    var enabled = false
    var alwaysShow = false
    var snoozedUntil = 0L

    /** A window type is usable (accessibility overlay, or the overlay permission works). */
    var canHost = false

    /** The pack for the pushed id is loaded. */
    var hasPet = false
    var interactive = true
    var phoneTask = false
    var dshService = false

    var appForeground = true
        private set
    var last: PetPush? = null
        private set

    /** Last time something was going on while the app was in the background; 0 = none since it left. */
    var lastActiveAt = 0L
        private set

    /** Last touch or call for attention (a new bubble, a result, a request): untucks. */
    var lastCallAt = 0L
        private set

    val bubbles = BubbleSlot()
    private var wasShown = false

    fun onPush(p: PetPush, now: Long) {
        val prev = last
        last = p
        if (bubbles.set(p.bubble, inApp = appForeground)) {
            lastCallAt = now
            lastActiveAt = now
        }
        if (p.calling && prev?.state != p.state) lastCallAt = now
        if (!appForeground && p.active) lastActiveAt = now
    }

    /** A replacement Flutter engine must provide its own current host/session and activity. */
    fun resetProducer() {
        last = null
        lastActiveAt = 0L
        lastCallAt = 0L
        wasShown = false
        bubbles.dismiss()
    }

    fun onForeground(foreground: Boolean, now: Long) {
        if (foreground == appForeground) return
        appForeground = foreground
        if (foreground) {
            // Back in the app: what happened out there has been seen; leaving again starts clean.
            lastActiveAt = 0L
            bubbles.dismiss()
        } else if (last?.active == true) {
            lastActiveAt = now
        }
    }

    /** The person touched the pet or its bubble. */
    fun onTouch(now: Long) {
        lastCallAt = now
        if (!appForeground) lastActiveAt = now
    }

    fun snoozed(now: Long) = now < snoozedUntil

    fun decide(now: Long): Decision {
        val d = rule(now)
        val shown = d.visibility != Visibility.HIDDEN
        if (shown && !wasShown) lastCallAt = now
        wasShown = shown
        return if (shown && d.visibility == Visibility.SHOWN) withTuck(d, now) else d
    }

    private fun withTuck(d: Decision, now: Long): Decision {
        if (d.bubble != null) return d
        val tuckAt = lastCallAt + TUCK_AFTER_MS
        if (now >= tuckAt) return d.copy(tucked = true)
        return d.copy(wakeAt = listOfNotNull(d.wakeAt, tuckAt).minOrNull())
    }

    private fun rule(now: Long): Decision {
        val push = last
        fun hidden(why: String, keepAlive: Boolean = false, wakeAt: Long? = null) =
            Decision(Visibility.HIDDEN, false, keepAlive && !dshService, null, wakeAt, why)

        if (!enabled) return hidden("off")
        if (push == null || push.packId == null) return hidden("no pet")
        if (!hasPet) return hidden("pack not loaded")
        if (!canHost) return hidden("no window permission")
        if (appForeground) return hidden("app on screen")
        if (snoozed(now)) return hidden("snoozed", wakeAt = snoozedUntil)

        val bubble = bubbles.current(now)
        val recent = lastActiveAt > 0 && now - lastActiveAt < IDLE_COLLAPSE_MS
        if (!(alwaysShow || push.active || bubble != null || recent)) return hidden("nothing going on")

        val wakeAt = listOfNotNull(
            bubble?.untilMs,
            if (!alwaysShow && !push.active && lastActiveAt > 0) lastActiveAt + IDLE_COLLAPSE_MS else null,
        ).minOrNull()
        if (phoneTask) return hidden("phone task", keepAlive = true, wakeAt = wakeAt)
        if (!interactive) return Decision(Visibility.PAUSED, false, !dshService, bubble, wakeAt, "screen off")
        return Decision(Visibility.SHOWN, false, !dshService, bubble, wakeAt, if (push.active) "active" else "recent")
    }

    companion object {
        const val IDLE_COLLAPSE_MS = 5 * 60_000L
        const val TUCK_AFTER_MS = 10_000L
    }
}
