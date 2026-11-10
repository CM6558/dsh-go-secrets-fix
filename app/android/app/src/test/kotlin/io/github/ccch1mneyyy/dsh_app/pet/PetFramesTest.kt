package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * The alpha of a palette PNG (how the bundled sheets are stored: 4- or 8-bit indices with a tRNS
 * table), decoded by hand: unit tests compile against android.jar, without javax.imageio.
 */
private class PaletteAlpha(val width: Int, val height: Int, private val alpha: ByteArray) {
    fun alpha(x: Int, y: Int): Int = alpha[y * width + x].toInt() and 0xff

    companion object {
        fun read(file: File): PaletteAlpha {
            val d = file.readBytes()
            fun int(at: Int) = ((d[at].toInt() and 0xff) shl 24) or ((d[at + 1].toInt() and 0xff) shl 16) or
                ((d[at + 2].toInt() and 0xff) shl 8) or (d[at + 3].toInt() and 0xff)
            var w = 0
            var h = 0
            var depth = 0
            var trns = ByteArray(0)
            val idat = ByteArrayOutputStream()
            var i = 8
            while (i < d.size) {
                val n = int(i)
                when (String(d, i + 4, 4, Charsets.US_ASCII)) {
                    "IHDR" -> {
                        w = int(i + 8)
                        h = int(i + 12)
                        depth = d[i + 16].toInt()
                        check(d[i + 17].toInt() == 3 && d[i + 20].toInt() == 0) { "${file.name}: not a plain palette PNG" }
                    }
                    "tRNS" -> trns = d.copyOfRange(i + 8, i + 8 + n)
                    "IDAT" -> idat.write(d, i + 8, n)
                }
                i += 12 + n
            }
            val stride = (w * depth + 7) / 8
            val raw = ByteArray(h * (stride + 1))
            Inflater().run {
                setInput(idat.toByteArray())
                var got = 0
                while (got < raw.size && !finished()) got += inflate(raw, got, raw.size - got)
                end()
            }
            val out = ByteArray(w * h)
            var prev = ByteArray(stride)
            for (y in 0 until h) {
                val row = raw.copyOfRange(y * (stride + 1) + 1, (y + 1) * (stride + 1))
                val filter = raw[y * (stride + 1)].toInt()
                for (x in 0 until stride) {
                    val a = if (x > 0) row[x - 1].toInt() and 0xff else 0
                    val b = prev[x].toInt() and 0xff
                    val c = if (x > 0) prev[x - 1].toInt() and 0xff else 0
                    val add = when (filter) {
                        1 -> a
                        2 -> b
                        3 -> (a + b) / 2
                        4 -> {
                            val p = a + b - c
                            val pa = abs(p - a)
                            val pb = abs(p - b)
                            val pc = abs(p - c)
                            if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c
                        }
                        else -> 0
                    }
                    row[x] = ((row[x].toInt() and 0xff) + add).toByte()
                }
                for (x in 0 until w) {
                    val index = if (depth == 8) {
                        row[x].toInt() and 0xff
                    } else {
                        val perByte = 8 / depth
                        val shift = 8 - depth * (x % perByte + 1)
                        ((row[x / perByte].toInt() and 0xff) shr shift) and ((1 shl depth) - 1)
                    }
                    out[y * w + x] = if (index < trns.size) trns[index] else 0xff.toByte()
                }
                prev = row
            }
            return PaletteAlpha(w, h, out)
        }
    }
}


/** The out-of-app window's frames (rest, held around the lifted pose, grown around happy / waking / typing) and their placement. */
class PetFramesTest {
    private fun packDir(id: String): File? =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .flatMap { sequenceOf(File(it, "app/assets/pets/$id"), File(it, "assets/pets/$id")) }
            .firstOrNull { File(it, "pack.json").isFile }

    private fun shipped(id: String): PetPack {
        val dir = packDir(id)
        assertNotNull("bundled pack $id", dir)
        return PetPack.parse(File(dir, "pack.json").readText())
    }

    private val packs = listOf("deepy-whale", "whale-girl")

    private fun frames(p: PetPack, size: String = "medium", density: Float = 2.75f) =
        PetFrames.of(p, p.windowBox(), p.screenScale(PetPack.bodyDp(size), density))

    /** The animations that get their own frame: each grown state's first. */
    private fun grownAnims(p: PetPack) = PetFrames.GROWN_STATES.map { p.animations.getValue(p.states.getValue(it).first()) }

    /**
     * Against the art itself: the visible pixels of every frame of [a], in physical px around the
     * rest origin, as PetView's drawBitmap(src, dst) scales the cell into [PetFrames.cell].
     */
    private fun drawn(id: String, a: PetAnimation, f: PetFrames): FramePx {
        val dst = f.cell(a)
        val sheet = PaletteAlpha.read(File(packDir(id), a.sheet))
        var top = Double.MAX_VALUE
        var bottom = -Double.MAX_VALUE
        var left = Double.MAX_VALUE
        var right = -Double.MAX_VALUE
        val sx = dst.width.toDouble() / a.frameW
        val sy = dst.height.toDouble() / a.frameH
        for (cell in a.frames.map { it.cell }.toSet()) {
            val ox = (cell % a.cols) * a.frameW
            val oy = (cell / a.cols) * a.frameH
            for (y in 0 until a.frameH) for (x in 0 until a.frameW) {
                if (sheet.alpha(ox + x, oy + y) == 0) continue
                left = minOf(left, dst.left + x * sx)
                top = minOf(top, dst.top + y * sy)
                right = maxOf(right, dst.left + (x + 1) * sx)
                bottom = maxOf(bottom, dst.top + (y + 1) * sy)
            }
        }
        return FramePx(floor(left).toInt(), floor(top).toInt(), ceil(right).toInt(), ceil(bottom).toInt())
    }

    // A 1080×2400 phone: 96 px status bar, 63 px gesture bar (as EdgeSnapTest).
    private val portrait = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)

    /** The bug: picked up, Deepy is drawn 14 art px higher than the window ever reached. */
    @Test fun deepyHeldGrowsUpwardsAroundTheLiftedPose() {
        val p = shipped("deepy-whale")
        val drag = p.reaction("drag")!!
        assertEquals("react-drag", drag.name)
        // Rest: wide hit box (8, 18, 44 × 31) with the idle cell's shadow row → 44 × 32 art px.
        assertEquals(PetBox(8f, 18f, 44f, 32f), p.windowBox())
        // Medium on a 2.75 phone: 30 dp × 2.75 / 22 = 3.75 px per art px.
        val f = frames(p)
        assertEquals(FramePx(0, 0, 165, 120), f.rest)
        // react-drag's cell starts at y 4: (4 − 18) × 3.75 = 52.5 px above the rest frame.
        assertEquals(FramePx(8, -52, 162, 121), f.cell(drag))
        assertFalse(f.rest.contains(f.cell(drag)))
        assertEquals(FramePx(0, -52, 165, 121), f.held)
        assertTrue(f.held.contains(f.rest))
        assertTrue(f.held.contains(f.cell(drag)))
    }

    @Test fun girlHeldGrowsLeftAndUp() {
        val p = shipped("whale-girl")
        val drag = p.reaction("drag")!!
        assertEquals(PetBox(10f, 12f, 54f, 49f), p.windowBox())
        // Crisp: 2 px per art px. drag reaches 5 art px left and 2 up of the rest frame.
        val f = frames(p)
        assertEquals(FramePx(0, 0, 108, 98), f.rest)
        assertEquals(FramePx(-10, -4, 108, 98), f.cell(drag))
        assertEquals(FramePx(-10, -4, 108, 98), f.held)
    }

    /** Deepy's three: each grows only where its art reaches past the rest frame. */
    @Test fun deepyGrowsOnlyWhereHappyWakingAndTypingNeedIt() {
        val p = shipped("deepy-whale")
        val f = frames(p)
        assertEquals(listOf("happy", "waking", "typing"), grownAnims(p).map { it.name })
        // typing: the laptop, 8 art px left (30 px); above only its top row's 1 art px; right and bottom as at rest.
        assertEquals(FramePx(-30, -4, 165, 120), f.grown["typing"])
        // happy jumps 13 art px up and reaches 8 left; waking jumps 14 up (its last row rounds 1 px below).
        assertEquals(FramePx(-30, -49, 165, 120), f.grown["happy"])
        assertEquals(FramePx(0, -52, 165, 121), f.grown["waking"])
        assertEquals(FramePx(-30, -52, 165, 121), f.reach)
        assertEquals(f.rest, f.frameFor(p.primary("working", 2), holding = false))
    }

    @Test fun girlGrowsOnlyWhereHappyWakingAndTypingNeedIt() {
        val p = shipped("whale-girl")
        val f = frames(p)
        assertEquals(listOf("happy", "waking", "typing"), grownAnims(p).map { it.name })
        // typing: what it shows above her head reaches 8 art px up, and nothing reaches past rest elsewhere.
        assertEquals(FramePx(0, -16, 108, 98), f.grown["typing"])
        assertEquals(FramePx(-10, -12, 108, 98), f.grown["happy"])
        assertEquals(FramePx(-2, -2, 108, 98), f.grown["waking"])
    }

    /** Every size on several screens: idle whole at rest, the drag pose whole while held, the three in theirs. */
    @Test fun everyFrameHoldsItsCell() {
        for (id in packs) {
            val p = shipped(id)
            for (size in listOf("small", "medium", "large")) {
                for (density in listOf(1.5f, 2f, 2.625f, 2.75f, 3f, 3.5f)) {
                    val f = frames(p, size, density)
                    val where = "$id $size @$density"
                    assertTrue("$where idle", f.rest.contains(f.cell(p.primary(PetPack.IDLE, 0))))
                    assertTrue("$where drag", f.held.contains(f.cell(p.reaction("drag")!!)))
                    assertTrue("$where rest ⊂ held", f.held.contains(f.rest))
                    for (a in grownAnims(p)) {
                        val g = f.frameFor(a, holding = false)
                        assertEquals("$where ${a.name}", f.rest.union(f.cell(a)), g)
                        assertTrue("$where ${a.name} ⊂ reach", f.reach.contains(g))
                    }
                    assertEquals(where, 0, f.rest.left)
                    assertEquals(where, 0, f.rest.top)
                }
            }
        }
    }

    /**
     * Against the art: every visible pixel of every react-drag / drag frame lands inside the held
     * frame, and for Deepy a good part of the body was above the rest frame.
     */
    @Test fun everyDragPixelIsInsideTheHeldFrame() {
        for (id in packs) {
            val p = shipped(id)
            val f = frames(p)
            val d = drawn(id, p.reaction("drag")!!, f)
            assertTrue("$id: $d in ${f.held}", f.held.contains(d))
            assertFalse("$id: $d would be cut at rest ${f.rest}", f.rest.contains(d))
            if (id == "deepy-whale") assertTrue("Deepy's lifted head: $d", d.top <= -50)
        }
    }

    /**
     * Against the art: every visible pixel of every frame of happy, waking and typing lands inside
     * the frame the window takes for it, and each side reaches past rest only as far as the art
     * does (within one art px of rounding), so the dead spot over other apps grows no more than it must.
     */
    @Test fun happyWakingAndTypingAreWholeAndGrowOnlyWhereNeeded() {
        for (id in packs) {
            val p = shipped(id)
            for (density in listOf(2f, 2.75f, 3.5f)) {
                val f = frames(p, density = density)
                val k = ceil(f.k.toDouble()).toInt()
                for (a in grownAnims(p)) {
                    val g = f.frameFor(a, holding = false)
                    val d = drawn(id, a, f)
                    val where = "$id ${a.name} @$density: drawn $d, frame $g, rest ${f.rest}"
                    assertTrue(where, g.contains(d))
                    assertFalse("$where (cut at rest)", f.rest.contains(d))
                    // Per side: as at rest unless the art reaches past it there, and then no further than the art.
                    if (g.left < 0) assertTrue("$where left", d.left < 0 && d.left - g.left <= k) else assertEquals(where, 0, g.left)
                    if (g.top < 0) assertTrue("$where top", d.top < 0 && d.top - g.top <= k) else assertEquals(where, 0, g.top)
                    if (g.right > f.rest.right) assertTrue("$where right", d.right > f.rest.right && g.right - d.right <= k) else assertEquals(where, f.rest.right, g.right)
                    if (g.bottom > f.rest.bottom) assertTrue("$where bottom", d.bottom > f.rest.bottom && g.bottom - d.bottom <= k) else assertEquals(where, f.rest.bottom, g.bottom)
                }
            }
        }
    }

    @Test fun eachFrameLastsWhileItsPictureIsUp() {
        val p = shipped("deepy-whale")
        val f = frames(p)
        val idle = p.primary(PetPack.IDLE, 0)
        val drag = p.reaction("drag")!!
        val typing = p.animations.getValue("typing")
        assertEquals(f.held, f.frameFor(idle, holding = true))
        assertEquals(f.held, f.frameFor(typing, holding = true))
        assertEquals(f.held, f.frameFor(null, holding = true))
        // Let go while the state's sheet is still decoding: the lifted picture is still up.
        assertEquals(f.held, f.frameFor(drag, holding = false))
        assertEquals(f.grown["typing"], f.frameFor(typing, holding = false))
        assertEquals(f.grown["happy"], f.frameFor(p.primary("attention", 0), holding = false))
        assertEquals(f.rest, f.frameFor(idle, holding = false))
        assertEquals(f.rest, f.frameFor(null, holding = false))
        assertEquals(f.rest, f.frameFor(p.reaction("tapLeft"), holding = false))
        assertEquals(f.rest, f.frameFor(p.primary("thinking", 0), holding = false))
    }

    @Test fun aPackWithoutADragReactionOrGrownStatesNeverGrows() {
        val p = shipped("deepy-whale")
        val f = PetFrames(p.windowBox(), 3.75f, heldAnim = null)
        assertEquals(f.rest, f.held)
        assertEquals(f.rest, f.reach)
        assertEquals(f.rest, f.frameFor(p.reaction("drag"), holding = true))
        assertEquals(f.rest, f.frameFor(p.animations.getValue("typing"), holding = false))
    }

    /** Growing and shrinking moves nothing: a cell lands on the same screen pixels in every frame. */
    @Test fun theAnchorStaysPutAcrossFrames() {
        val p = shipped("deepy-whale")
        val f = frames(p)
        val rest = WindowPos(907, 1405)
        val all = listOf(f.rest, f.held) + f.grown.values
        for (anim in listOf(p.primary(PetPack.IDLE, 0), p.reaction("drag")!!) + grownAnims(p)) {
            val cell = f.cell(anim)
            val screens = all.map { frame ->
                val window = PetFrames.windowAt(rest, frame)
                // PetView draws the cell at (cell − frame origin) inside the window.
                WindowPos(window.x + cell.left - frame.left, window.y + cell.top - frame.top)
            }.toSet()
            assertEquals(anim.name, setOf(WindowPos(rest.x + cell.left, rest.y + cell.top)), screens)
        }
        for (frame in all) assertEquals(rest, PetFrames.restOf(PetFrames.windowAt(rest, frame), frame))
        assertEquals(WindowPos(907, 1405 - 52), PetFrames.windowAt(rest, f.held))
        assertEquals(WindowPos(907 - 30, 1405 - 4), PetFrames.windowAt(rest, f.grown.getValue("typing")))
    }

    /**
     * Docked anywhere, every frame the window may take there (typing's laptop, happy's jump) is
     * inside the margins: no frame has to move the pet, none reaches under a bar or off the screen.
     */
    @Test fun theDockLeavesRoomForEveryGrownFrame() {
        val landscape = SafeArea(2400, 1080, left = 96, top = 0, right = 0, bottom = 63)
        for (id in packs) {
            val p = shipped(id)
            for (size in listOf("small", "medium", "large")) {
                val f = frames(p, size, 2.75f)
                for (area in listOf(portrait, landscape)) {
                    val m = 22
                    for (side in Side.values()) for (y in listOf(0f, 0.37f, 1f)) {
                        val dock = Dock(side, y)
                        val rest = EdgeSnap.position(dock, f.reach, area, m)
                        for (frame in listOf(f.rest) + f.grown.values) {
                            val w = PetFrames.windowAt(rest, frame)
                            val where = "$id $size $dock $area: $frame at $w"
                            assertTrue(where, w.x >= area.left + m && w.x + frame.width <= area.screenW - area.right - m)
                            assertTrue(where, w.y >= area.top + m && w.y + frame.height <= area.screenH - area.bottom - m)
                        }
                        // Released where it docked: the same dock back.
                        val again = EdgeSnap.dockFor(rest, f.rest.width, f.reach, area, m)
                        assertEquals(dock.side, again.side)
                        assertEquals(y, again.yFraction, 0.01f)
                        // Tucked: the same height, 40 % of the rest frame past the edge.
                        val t = EdgeSnap.tucked(dock, f.rest.width, f.reach, area, m)
                        assertEquals(rest.y, t.y)
                        val hidden = (f.rest.width * EdgeSnap.TUCK_SHARE).roundToInt()
                        assertEquals(if (side == Side.LEFT) -hidden else area.screenW - f.rest.width + hidden, t.x)
                    }
                }
            }
        }
    }

    /** With nothing past the rest frame, the dock is exactly what it was. */
    @Test fun aRestOnlyReachDocksAsBefore() {
        val w = 165
        val h = 120
        val reach = FramePx(0, 0, w, h)
        for (side in Side.values()) for (y in listOf(0f, 0.5f, 1f)) {
            val dock = Dock(side, y)
            assertEquals(EdgeSnap.position(dock, w, h, portrait, 22), EdgeSnap.position(dock, reach, portrait, 22))
            assertEquals(EdgeSnap.tucked(dock, w, h, portrait, 22), EdgeSnap.tucked(dock, w, reach, portrait, 22))
        }
        for ((x, y) in listOf(10 to 300, 900 to 1200, 500 to 5000)) {
            assertEquals(EdgeSnap.dockFor(x, y, w, h, portrait, 22, 300f), EdgeSnap.dockFor(WindowPos(x, y), w, reach, portrait, 22, 300f))
        }
    }

    /** Away from the edges, held follows the finger exactly: the dock on release is as before. */
    @Test fun heldFollowsTheFingerAndReleasesWhereTheRestFrameIs() {
        val f = frames(shipped("deepy-whale"))
        val start = WindowPos(400, 1200)
        val window = EdgeSnap.carry(start, -120, 300, f.held, portrait)
        assertEquals(WindowPos(400 - 120, 1200 + 300 - 52), window)
        val rest = PetFrames.restOf(window, f.held)
        assertEquals(WindowPos(280, 1500), rest)
        val old = EdgeSnap.clampDrag(start.x - 120, start.y + 300, f.rest.width, f.rest.height, portrait)
        assertEquals(old, rest)
    }

    /** At every edge the whole held window, lifted head and all, stays on screen and clear of the bars. */
    @Test fun heldStaysWholeOnScreenAtTheEdges() {
        val f = frames(shipped("deepy-whale"))
        val m = 22
        val top = EdgeSnap.position(Dock(Side.RIGHT, 0f), f.reach, portrait, m)
        for ((dx, dy) in listOf(0 to 0, 0 to -3000, 3000 to 0, -3000 to 0, 0 to 3000, -3000 to -3000, 3000 to 3000)) {
            val w = EdgeSnap.carry(top, dx, dy, f.held, portrait)
            val where = "($dx, $dy) → $w"
            assertTrue(where, w.x >= 0 && w.x + f.held.width <= portrait.screenW)
            assertTrue(where, w.y >= portrait.top && w.y + f.held.height <= portrait.screenH - portrait.bottom)
        }
        // Pinned to the top, the rest frame sits 52 px lower than the window, so the head shows.
        val pinned = EdgeSnap.carry(top, 0, -3000, f.held, portrait)
        assertEquals(portrait.top, pinned.y)
        assertEquals(portrait.top + 52, PetFrames.restOf(pinned, f.held).y)
        // The release reads where the finger put the rest frame (as before the window grew), so the
        // top dock is still reachable.
        val drop = EdgeSnap.clampDrag(top.x, top.y - 3000, f.rest.width, f.rest.height, portrait)
        val dock = EdgeSnap.dockFor(drop, f.rest.width, f.reach, portrait, m)
        assertEquals(Side.RIGHT, dock.side)
        assertEquals(0f, dock.yFraction)
    }

    /** Dragged into a corner on the left: the held window stops at the screen edge, no part cut. */
    @Test fun girlHeldAtTheLeftEdgeKeepsItsSwingingSide() {
        val f = frames(shipped("whale-girl"))
        // drag reaches 10 px left of the rest frame: pushed against x 0, the rest frame stops at 10.
        val w = EdgeSnap.carry(WindowPos(300, 1000), -3000, 0, f.held, portrait)
        assertEquals(0, w.x)
        assertEquals(10, PetFrames.restOf(w, f.held).x)
    }
}
