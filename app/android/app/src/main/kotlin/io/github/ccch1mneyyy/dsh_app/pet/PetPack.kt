package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.phone.Json

/** One frame: which cell of the sheet, and for how long. */
data class PetFrame(val cell: Int, val ms: Int)

/** A rectangle in logical pixels (the pack's canvas). */
data class PetBox(val x: Float, val y: Float, val w: Float, val h: Float) {
    val right: Float get() = x + w
    val bottom: Float get() = y + h

    fun union(o: PetBox): PetBox {
        val l = minOf(x, o.x)
        val t = minOf(y, o.y)
        return PetBox(l, t, maxOf(right, o.right) - l, maxOf(bottom, o.bottom) - t)
    }
}

/**
 * One animation: a grid of equal cells (`cols` per row, row-major), each cell
 * the animation's [box] on the canvas at `scale` sheet pixels per logical pixel.
 */
data class PetAnimation(
    val name: String,
    val sheet: String,
    /** Cell size in sheet pixels (= box × scale). */
    val frameW: Int,
    val frameH: Int,
    val cols: Int,
    val box: PetBox,
    val frames: List<PetFrame>,
    val loop: Boolean,
) {
    val totalMs: Long = frames.sumOf { it.ms.toLong() }
    val cells: Int get() = (frames.maxOfOrNull { it.cell } ?: 0) + 1
    val rows: Int get() = (cells + cols - 1) / cols
}

data class PetTier(val min: Int, val anim: String)

/** One idle action and how often it comes up (`idlePool`). */
data class PetIdleItem(val anim: PetAnimation, val ms: Long, val weight: Int)

/** A state's occasional replacement animation (`bonus`, e.g. whale-girl's attention extras). */
data class PetBonus(val anims: List<PetAnimation>, val chance: Float)

/**
 * A runtime pet pack (`assets/pets/<id>/pack.json`):
 * Clawd on Desk state names mapped to animations, busy tiers, reactions, timings. Parsing only;
 * no Android types, so the JVM tests cover it. A pack that fails the format's checks is rejected.
 */
class PetPack(
    val id: String,
    val name: String,
    val pixelArt: Boolean,
    /** Sheet pixels per logical pixel: 1 for whale-girl, 5 for Deepy. */
    val scale: Int,
    val canvasW: Int,
    val canvasH: Int,
    val anchorX: Float,
    val baseline: Float,
    /** The idle body: where the bubble points and what the dock lines up with the edge. */
    val contentBox: PetBox,
    val animations: Map<String, PetAnimation>,
    val states: Map<String, List<String>>,
    val tiers: Map<String, List<PetTier>>,
    val reactions: Map<String, String>,
    /** One-off play time of a variant or reaction (`timings.playMs`). */
    val playMs: Map<String, Long>,
    /** `hitBoxes.wide`: the out-of-app window's size. Null when the pack has none. */
    val wideBox: PetBox?,
    /** Idle actions played now and then over `states.idle[0]` (`idlePool.anims`). */
    val idlePool: List<PetIdleItem>,
    /** `bonus`; null when the pack has no such key (format v1: a state's extra animations). */
    val bonus: Map<String, PetBonus>?,
) {
    /** The animation [state] plays: the first tier reached, else the state's primary. Unknown → idle's. */
    fun primary(state: String, tier: Int): PetAnimation {
        tiers[state]?.let { list ->
            list.firstOrNull { tier >= it.min }?.let { t -> animations[t.anim]?.let { return it } }
        }
        states[state]?.firstOrNull()?.let { animations[it] }?.let { return it }
        if (state != IDLE) return primary(IDLE, 0)
        return idlePool.firstOrNull()?.anim ?: animations.values.first()
    }

    /**
     * The state's occasional replacement: `bonus[state]`, else (format v1) the state's own list
     * past its primary at up to a third of the time. Idle's list is the idle pool, not a bonus.
     */
    fun bonusOf(state: String, tier: Int): PetBonus? {
        bonus?.let { return it[state] }
        if (state == IDLE || tiers[state]?.any { tier >= it.min } == true) return null
        val p = primary(state, tier)
        val rest = states[state].orEmpty().mapNotNull { animations[it] }.filter { it !== p }
        return if (rest.isEmpty()) null else PetBonus(rest, 1f / 3)
    }

    fun reaction(kind: String): PetAnimation? = reactions[kind]?.let { animations[it] }

    /** How long a one-off of [anim] plays: `timings.playMs`, else two cycles (one for a one-shot). */
    fun playMsOf(anim: PetAnimation): Long = playMs[anim.name] ?: (if (anim.loop) 2 * anim.totalMs else anim.totalMs)

    /** Union of the boxes of [names] (logical px): the room the pet may need. */
    fun unionBox(names: Collection<String>): PetBox =
        names.mapNotNull { animations[it]?.box }.reduceOrNull(PetBox::union) ?: contentBox

    /** Every animation a state, tier or reaction can play, except [skipStates]' own. */
    fun usedAnimations(skipStates: Set<String> = emptySet()): Set<String> {
        val names = LinkedHashSet<String>()
        states.filterKeys { it !in skipStates }.values.forEach(names::addAll)
        tiers.filterKeys { it !in skipStates }.values.forEach { list -> list.forEach { names += it.anim } }
        names += reactions.values
        if (IDLE !in skipStates) idlePool.forEach { names += it.anim.name }
        bonus.orEmpty().filterKeys { it !in skipStates }.values.forEach { b -> b.anims.forEach { names += it.name } }
        return names
    }

    /**
     * The out-of-app window at rest, on the canvas: `hitBoxes.wide` with the idle picture's cell (the
     * hit box, measured on the body, leaves out the idle art's bottom row: 鲸娘's outline, Deepy's
     * shadow), else every state animation's box (roam aside). Held, the window adds the drag pose
     * ([PetFrames]).
     */
    fun windowBox(): PetBox = wideBox?.union(primary(IDLE, 0).box) ?: unionBox(usedAnimations(skipStates = setOf("roam")))

    /** Pixel art kept at 1×: drawn at a whole number of physical pixels per art pixel, unfiltered. */
    val crisp: Boolean get() = pixelArt && scale == 1

    /**
     * Physical pixels per logical (art) pixel for a body [bodyDp] tall:
     * a whole number for crisp packs, exact for hi-res ones.
     */
    fun screenScale(bodyDp: Float, density: Float): Float {
        val raw = bodyDp * density / contentBox.h
        return if (crisp) maxOf(1, Math.round(raw)).toFloat() else raw
    }

    companion object {
        const val IDLE = "idle"

        /** Body heights of the three sizes (dp): small, medium, large. */
        fun bodyDp(size: String?): Float = when (size) {
            "small" -> 22f
            "large" -> 40f
            else -> 30f
        }

        /** Clawd on Desk state names the overlay understands (anything else plays as idle). */
        val STATES = setOf(
            "idle", "thinking", "working", "juggling", "sweeping", "notification",
            "attention", "error", "carrying", "sleeping", "waking", "roam",
        )

        fun parse(text: String): PetPack {
            val root = Json.parse(text) as? Map<*, *> ?: bad("not an object")
            if (num(root["schema"])?.toInt() != 1) bad("schema must be 1")
            val id = (root["id"] as? String)?.takeIf { it.isNotBlank() } ?: bad("missing id")
            val scale = num(root["scale"])?.toInt()?.takeIf { it >= 1 } ?: bad("missing scale")
            val canvas = root["canvas"] as? Map<*, *> ?: bad("missing canvas")
            val canvasW = num(canvas["w"])?.toInt()?.takeIf { it > 0 } ?: bad("bad canvas")
            val canvasH = num(canvas["h"])?.toInt()?.takeIf { it > 0 } ?: bad("bad canvas")
            val animsRaw = root["animations"] as? Map<*, *> ?: bad("missing animations")
            val animations = LinkedHashMap<String, PetAnimation>()
            for ((k, v) in animsRaw) {
                val name = k as? String ?: bad("bad animation name")
                val a = v as? Map<*, *> ?: bad("bad animation $name")
                val sheet = a["sheet"] as? String ?: bad("$name: no sheet")
                if (sheet.contains('/') || sheet.contains('\\') || sheet.startsWith('.')) bad("$name: bad sheet")
                val box = box(a["box"]) ?: bad("$name: no box")
                val fw = num(a["frameW"])?.toInt() ?: bad("$name: no frameW")
                val fh = num(a["frameH"])?.toInt() ?: bad("$name: no frameH")
                if (fw != (box.w * scale).toInt() || fh != (box.h * scale).toInt()) bad("$name: cell ≠ box × scale")
                val cols = num(a["cols"])?.toInt()?.takeIf { it >= 1 } ?: bad("$name: no cols")
                val frames = (a["frames"] as? List<*>).orEmpty().map { f ->
                    val m = f as? Map<*, *> ?: bad("$name: bad frame")
                    val cell = num(m["i"])?.toInt()?.takeIf { it >= 0 } ?: bad("$name: bad frame index")
                    val ms = num(m["ms"])?.toInt()?.takeIf { it > 0 } ?: bad("$name: bad frame time")
                    PetFrame(cell, ms)
                }
                if (frames.isEmpty()) bad("$name: no frames")
                animations[name] = PetAnimation(name, sheet, fw, fh, cols, box, frames, a["loop"] != false)
            }
            if (animations.isEmpty()) bad("no animations")
            fun ref(name: Any?, where: String): String =
                (name as? String)?.takeIf { it in animations } ?: bad("$where names a missing animation")
            val states = LinkedHashMap<String, List<String>>()
            (root["states"] as? Map<*, *>)?.forEach { (k, v) ->
                val list = (v as? List<*>).orEmpty().map { ref(it, "states.$k") }
                if (k is String && list.isNotEmpty()) states[k] = list
            }
            val tiers = LinkedHashMap<String, List<PetTier>>()
            (root["tiers"] as? Map<*, *>)?.forEach { (k, v) ->
                val list = (v as? List<*>).orEmpty().map { t ->
                    val m = t as? Map<*, *> ?: bad("tiers.$k")
                    PetTier(num(m["min"])?.toInt() ?: 1, ref(m["anim"], "tiers.$k"))
                }.sortedByDescending { it.min }
                if (k is String && list.isNotEmpty()) tiers[k] = list
            }
            val reactions = LinkedHashMap<String, String>()
            (root["reactions"] as? Map<*, *>)?.forEach { (k, v) -> if (k is String) reactions[k] = ref(v, "reactions.$k") }
            (root["roam"] as? Map<*, *>)?.get("anim")?.let { ref(it, "roam") }
            val playMs = LinkedHashMap<String, Long>()
            ((root["timings"] as? Map<*, *>)?.get("playMs") as? Map<*, *>)?.forEach { (k, v) ->
                val ms = num(v)?.toLong()
                if (k is String && ms != null && ms > 0) playMs[k] = ms
            }
            val wideBox = box((root["hitBoxes"] as? Map<*, *>)?.get("wide"))
            // `idlePool: {everyMs, anims: [...]}`; a bare list is read too.
            val poolRaw = root["idlePool"].let { (it as? Map<*, *>)?.get("anims") ?: it } as? List<*>
            val idlePool = poolRaw?.map { item ->
                val m = item as? Map<*, *> ?: bad("idlePool")
                val anim = animations.getValue(ref(m["anim"], "idlePool"))
                PetIdleItem(anim, num(m["ms"])?.toLong()?.takeIf { it > 0 } ?: (2 * anim.totalMs), (num(m["weight"])?.toInt() ?: 1).coerceAtLeast(1))
            } ?: states[IDLE].orEmpty().drop(1).map { name ->
                val anim = animations.getValue(name)
                PetIdleItem(anim, playMs[name] ?: (2 * anim.totalMs), 1)
            }
            val bonus = if ("bonus" in root.keys) LinkedHashMap<String, PetBonus>() else null
            (root["bonus"] as? Map<*, *>)?.forEach { (k, v) ->
                val m = v as? Map<*, *> ?: return@forEach
                val anims = (m["anims"] as? List<*>).orEmpty().map { animations.getValue(ref(it, "bonus.$k")) }
                val chance = (num(m["chance"])?.toFloat() ?: 0f).coerceIn(0f, 1f)
                if (k is String) bonus?.put(k, PetBonus(anims, chance))
            }
            val anchor = root["anchor"] as? Map<*, *>
            val firstBox = animations.values.first().box
            return PetPack(
                id = id,
                name = (root["name"] as? String) ?: id,
                pixelArt = root["pixelArt"] == true,
                scale = scale,
                canvasW = canvasW,
                canvasH = canvasH,
                anchorX = num(anchor?.get("x"))?.toFloat() ?: (canvasW / 2f),
                baseline = num(anchor?.get("baseline"))?.toFloat() ?: canvasH.toFloat(),
                contentBox = box(root["contentBox"]) ?: firstBox,
                animations = animations,
                states = states,
                tiers = tiers,
                reactions = reactions,
                playMs = playMs,
                wideBox = wideBox,
                idlePool = idlePool,
                bonus = bonus,
            )
        }

        private fun bad(why: String): Nothing = throw PetPackException(why)

        private fun num(v: Any?): Number? = v as? Number

        private fun box(v: Any?): PetBox? {
            val m = v as? Map<*, *> ?: return null
            val x = num(m["x"])?.toFloat() ?: return null
            val y = num(m["y"])?.toFloat() ?: return null
            val w = num(m["w"])?.toFloat()?.takeIf { it > 0 } ?: return null
            val h = num(m["h"])?.toFloat()?.takeIf { it > 0 } ?: return null
            return PetBox(x, y, w, h)
        }
    }
}

class PetPackException(message: String) : Exception(message)
