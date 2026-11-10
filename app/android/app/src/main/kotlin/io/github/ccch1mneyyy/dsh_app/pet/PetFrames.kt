package io.github.ccch1mneyyy.dsh_app.pet

import kotlin.math.roundToInt

/** A rectangle in physical pixels, relative to the rest frame's top-left (the pet's fixed origin). */
data class FramePx(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top

    fun union(o: FramePx) = FramePx(minOf(left, o.left), minOf(top, o.top), maxOf(right, o.right), maxOf(bottom, o.bottom))

    fun contains(o: FramePx) = o.left >= left && o.top >= top && o.right <= right && o.bottom <= bottom

    /** On screen, with the rest frame's top-left at [rest]. */
    fun at(rest: WindowPos) = ScreenRect(rest.x + left, rest.y + top, rest.x + right, rest.y + bottom)
}

/**
 * The out-of-app pet window's frames (docs/design/pets.md §6.1), in physical pixels around one
 * origin, the rest frame's top-left, so switching between them moves nothing on screen:
 *
 * - **rest**: [restBox] × k, the pack's wide hit box with the idle picture's cell
 *   ([PetPack.windowBox]). Kept small: on Android 12+ an app overlay takes every touch over its whole
 *   frame, transparent pixels included, so a bigger window is a bigger dead spot over other apps;
 * - **held**: rest plus the drag reaction's whole cell. Picked up, the pet is drawn lifted (Deepy's
 *   react-drag body reaches 13.6 art px above the wide box), so while held, and until that
 *   picture is gone, the window grows to hold it;
 * - **grown**: rest plus the cell of a state animation that reaches past it ([GROWN_STATES]: Deepy's
 *   happy and waking jump 13–14 art px above it, its typing laptop sticks out 8 on the left), while
 *   that animation shows. A union, so it only grows where the cell does (Deepy's typing: 8 art px
 *   left, and above only the 1 its top row needs).
 *
 * [reach] is every frame the window can take while docked; the dock keeps all of it on screen and
 * clear of the bars, so a grown frame never has to move the pet.
 *
 * Cells are placed as [PetView] draws them: the box offset rounded to whole physical pixels, the
 * size rounded on its own. Pure, for the JVM tests.
 */
class PetFrames(
    val restBox: PetBox,
    val k: Float,
    private val heldAnim: PetAnimation?,
    grownAnims: Collection<PetAnimation> = emptyList(),
    bodyBox: PetBox = restBox,
) {
    val rest = FramePx(0, 0, (restBox.w * k).roundToInt(), (restBox.h * k).roundToInt())

    /** [box] (canvas px) in physical px around the rest origin, placed as cells are. */
    fun place(box: PetBox): FramePx {
        val l = ((box.x - restBox.x) * k).roundToInt()
        val t = ((box.y - restBox.y) * k).roundToInt()
        return FramePx(l, t, l + (box.w * k).roundToInt(), t + (box.h * k).roundToInt())
    }

    /** Where [anim]'s cell is drawn, relative to the rest frame's origin. */
    fun cell(anim: PetAnimation): FramePx = place(anim.box)

    /** The idle body ([PetPack.contentBox]): what a bubble lines up with and points at. */
    val body: FramePx = place(bodyBox)

    /** The picture [shown] makes: the body with that animation's cell (a jump, a cloud, a 「!」). */
    fun art(shown: PetAnimation?): FramePx = shown?.let { body.union(cell(it)) } ?: body

    val held: FramePx = heldAnim?.let { rest.union(cell(it)) } ?: rest

    /** By animation name: the frame each grown animation gets while it shows. */
    val grown: Map<String, FramePx> = grownAnims.associate { it.name to rest.union(cell(it)) }

    /** Rest and every grown frame: what a docked pet may need on screen. */
    val reach: FramePx = grown.values.fold(rest, FramePx::union)

    /**
     * The frame for [shown]: held while [holding] or while the held picture is still up (its
     * successor's sheet may lag), a grown one while its animation shows, else rest.
     */
    fun frameFor(shown: PetAnimation?, holding: Boolean): FramePx = when {
        holding || (heldAnim != null && shown?.name == heldAnim.name) -> held
        shown != null -> grown[shown.name] ?: rest
        else -> rest
    }

    companion object {
        /**
         * States whose animation gets its own frame: attention (happy), waking and working (typing),
         * each by the state's own first animation. Picked by the owner (10-29) for reaching furthest
         * past the rest frame; the others' effects (thought clouds, Zzz) are still cut, as §6.1 accepts.
         */
        val GROWN_STATES = listOf("attention", "waking", "working")

        fun of(pack: PetPack, restBox: PetBox, k: Float) = PetFrames(
            restBox, k, pack.reaction("drag"),
            GROWN_STATES.mapNotNull { s -> pack.states[s]?.firstOrNull()?.let { pack.animations[it] } }.distinct(),
            pack.contentBox,
        )

        /** Window position of [frame] when the rest frame sits at [rest]. */
        fun windowAt(rest: WindowPos, frame: FramePx) = WindowPos(rest.x + frame.left, rest.y + frame.top)

        /** Where the rest frame sits for a window of [frame] at [window]. */
        fun restOf(window: WindowPos, frame: FramePx) = WindowPos(window.x - frame.left, window.y - frame.top)
    }
}
