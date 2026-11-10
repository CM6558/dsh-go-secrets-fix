package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import io.github.ccch1mneyyy.dsh_app.pet.Dock
import io.github.ccch1mneyyy.dsh_app.pet.EdgeSnap
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import io.github.ccch1mneyyy.dsh_app.pet.WindowPos
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt

/**
 * Where the ball's window goes, in px. Pure (measured in BallGeometryTest): the ball sits [edge]
 * from the screen side like the pill's card, and folding starts on the card's end circle.
 */
internal object BallGeometry {
    /** The window margin [EdgeSnap] keeps from the safe area so the ball itself is [edge] in. */
    fun margin(edge: Int, pad: Int) = edge - pad

    /**
     * The ball window over the open card's end circle on [side]: the pill window is [pillW] wide,
     * centred on a [screenW] screen at [pillY]; its root pads the card by [padL], [padR], [padTop].
     */
    fun pillEnd(screenW: Int, pillW: Int, pillY: Int, padL: Int, padR: Int, padTop: Int, ball: Int, pad: Int, side: Side): WindowPos {
        val windowX = (screenW - pillW) / 2
        val circleLeft = if (side == Side.RIGHT) windowX + pillW - padR - ball else windowX + padL
        return WindowPos(circleLeft - pad, pillY + padTop - pad)
    }
}

/**
 * The folded control pill: a 44 dp ball on the side of the screen (its own
 * TYPE_ACCESSIBILITY_OVERLAY window, 6 dp of room around it for the shadow). It shows the task's
 * state only — a slowly breathing ring while DSH works, a pause mark, a stop mark — and opens the
 * pill on a tap. Dragged, it follows the finger and settles on the nearer side, where it stays
 * (side and height kept across tasks, like the pet's dock: pet/EdgeSnap.kt).
 *
 * The window is added once per pill and shown or hidden (GONE windows take no touches); the
 * overlay folds and unfolds the pill around it ([ControlOverlay]).
 */
internal class OverlayBall(
    private val context: Context,
    private val wm: WindowManager,
    private val area: () -> SafeArea,
    private val onTap: () -> Unit,
    /** A finger came down on the ball (tap or drag): it is not idle. */
    private val onTouchDown: () -> Unit = {},
) {
    enum class Look { RUNNING, PAUSED, STOPPED }

    class Colors(val top: Int, val bottom: Int, val stroke: Int, val accent: Int, val muted: Int)

    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Where the ball rests; saved when the person drops it somewhere. */
    var dock: Dock = Dock(
        if (prefs.getString(K_SIDE, null) == "left") Side.LEFT else Side.RIGHT,
        prefs.getFloat(K_Y, DEFAULT_Y),
    )
        private set

    /** Room around the ball for its shadow, on every side (the window is square and centred on it). */
    val pad = dp(PAD_DP)
    val diameter = dp(BALL_DP)

    /** Window side. */
    val size = diameter + 2 * pad

    /** The ball's gap to the screen side, as a window margin: 12 dp, like the pill and the composer. */
    private val margin = BallGeometry.margin(dp(EDGE_DP), pad)

    private val ball = BallView(context)
    val root: FrameLayout = FrameLayout(context).apply {
        setPadding(pad, pad, pad, pad)
        clipToPadding = false
        clipChildren = false
        addView(ball, FrameLayout.LayoutParams(diameter, diameter))
    }

    val params = WindowManager.LayoutParams(
        size,
        size,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    private val glideCurve = PathInterpolator(0.32f, 0.72f, 0f, 1f)
    private var glide: ValueAnimator? = null
    private var markFade: ValueAnimator? = null
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var dragging = false
    private var tracker: VelocityTracker? = null

    init {
        ball.setOnClickListener { onTap() }
        ball.setOnTouchListener { v, e -> onTouch(v, e) }
    }

    val attached: Boolean get() = root.isAttachedToWindow

    /** Adds the window, hidden, at [at]; false when the system refused it. */
    fun attach(title: CharSequence, untouchable: Boolean, at: WindowPos): Boolean {
        if (attached) return true
        params.title = title
        params.flags = if (untouchable) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        params.x = at.x
        params.y = at.y
        root.visibility = View.GONE
        return try {
            wm.addView(root, params)
            true
        } catch (e: Exception) {
            Log.w(TAG, "ball addView failed", e)
            false
        }
    }

    fun detach() {
        cancelGlide()
        markFade?.cancel()
        markFade = null
        endDrag()
        root.animate().cancel()
        try { wm.removeView(root) } catch (_: Exception) {}
    }

    fun setColors(colors: Colors) = ball.setColors(colors)

    /** The surface's opacity (闲置时不透明度); the mark stays at full. */
    fun setSurfaceAlpha(alpha: Float) = ball.setSurfaceAlpha(alpha)

    fun setLook(look: Look, description: CharSequence) {
        ball.look = look
        ball.contentDescription = description
    }

    /** Where the ball rests now ([dock] on the current screen). */
    fun dockPos(): WindowPos = EdgeSnap.position(dock, size, size, area(), margin)

    val pos: WindowPos get() = WindowPos(params.x, params.y)

    fun move(to: WindowPos) {
        cancelGlide()
        params.x = to.x
        params.y = to.y
        update()
    }

    /** Slides the window to [to] (at once when [animated] is false), then runs [then]. */
    fun glideTo(to: WindowPos, animated: Boolean, durationMs: Long = GLIDE_MS, then: (() -> Unit)? = null) {
        cancelGlide()
        val fromX = params.x
        val fromY = params.y
        if (!animated || (fromX == to.x && fromY == to.y)) {
            move(to)
            then?.invoke()
            return
        }
        glide = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = durationMs
            interpolator = glideCurve
            addUpdateListener { a ->
                val f = a.animatedValue as Float
                params.x = (fromX + (to.x - fromX) * f).roundToInt()
                params.y = (fromY + (to.y - fromY) * f).roundToInt()
                update()
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (glide === animation) glide = null
                    if (!cancelled) then?.invoke()
                }
            })
            start()
        }
    }

    fun cancelGlide() {
        glide?.cancel()
        glide = null
    }

    /** Fades the mark inside the ball (the surface stays): out on the way back into the pill, in after a fold. */
    fun fadeMark(to: Float, animated: Boolean, durationMs: Long = MARK_MS) {
        markFade?.cancel()
        markFade = null
        if (!animated || !animationsOn()) {
            ball.markAlpha = to
            return
        }
        markFade = ValueAnimator.ofFloat(ball.markAlpha, to).apply {
            duration = durationMs
            interpolator = glideCurve
            addUpdateListener { ball.markAlpha = it.animatedValue as Float }
            start()
        }
    }

    private fun update() {
        try { if (root.isAttachedToWindow) wm.updateViewLayout(root, params) } catch (e: Exception) { Log.w(TAG, "ball update failed", e) }
    }

    // ---- touch ----------------------------------------------------------------------------------

    private fun onTouch(v: View, e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                cancelGlide()
                onTouchDown()
                downX = e.rawX
                downY = e.rawY
                startX = params.x
                startY = params.y
                dragging = false
                tracker?.recycle()
                tracker = VelocityTracker.obtain().also { track(it, e) }
                press(true)
            }
            MotionEvent.ACTION_MOVE -> {
                tracker?.let { track(it, e) }
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                    dragging = true
                    press(false)
                }
                if (dragging) {
                    val p = EdgeSnap.clampDrag(startX + dx.roundToInt(), startY + dy.roundToInt(), size, size, area())
                    params.x = p.x
                    params.y = p.y
                    update()
                }
            }
            MotionEvent.ACTION_UP -> {
                tracker?.let { track(it, e) }
                press(false)
                if (dragging) settle(velocityX()) else v.performClick()
                endDrag()
            }
            MotionEvent.ACTION_CANCEL -> {
                press(false)
                if (dragging) settle(0f)
                endDrag()
            }
        }
        return true
    }

    /** Raw coordinates: the window moves under the finger, so view coordinates stand still. */
    private fun track(t: VelocityTracker, e: MotionEvent) {
        val copy = MotionEvent.obtain(e)
        copy.setLocation(e.rawX, e.rawY)
        t.addMovement(copy)
        copy.recycle()
    }

    private fun velocityX(): Float {
        val t = tracker ?: return 0f
        t.computeCurrentVelocity(1000)
        return t.xVelocity
    }

    private fun endDrag() {
        dragging = false
        tracker?.recycle()
        tracker = null
    }

    private fun settle(velocityX: Float) {
        val a = area()
        dock = EdgeSnap.dockFor(params.x, params.y, size, size, a, margin, velocityX)
        prefs.edit().putString(K_SIDE, if (dock.side == Side.LEFT) "left" else "right").putFloat(K_Y, dock.yFraction).apply()
        glideTo(EdgeSnap.position(dock, size, size, a, margin), animationsOn())
    }

    private fun press(down: Boolean) {
        val scale = if (down) PRESS_SCALE else 1f
        if (!animationsOn()) {
            ball.scaleX = scale
            ball.scaleY = scale
            return
        }
        ball.animate().scaleX(scale).scaleY(scale).setDuration(if (down) 90 else 200).setInterpolator(glideCurve).start()
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), context.resources.displayMetrics).roundToInt()

    /**
     * The ball itself: the pill's surface as a circle, and one mark in the 22 dp glyph square —
     * a thin ring with a dot (working; the ring breathes like the engine page's), two bars (paused),
     * a rounded square (stopped). Everything centred: the marks are symmetric about both axes.
     */
    private class BallView(context: Context) : View(context) {
        private var colors: Colors? = null
        private val surface = GradientDrawable().apply { shape = GradientDrawable.OVAL }
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val rect = RectF()
        private var breath: ValueAnimator? = null
        private var phase = 1f
        private var shown = false

        var look: Look = Look.RUNNING
            set(value) {
                if (field == value) return
                field = value
                syncBreath()
                invalidate()
            }

        /** The mark's opacity (0–1) on top of its own; the surface is not affected. */
        var markAlpha = 1f
            set(value) {
                val v = value.coerceIn(0f, 1f)
                if (field == v) return
                field = v
                invalidate()
            }

        init {
            background = surface
            elevation = dpf(3f)
            isClickable = true
            isFocusable = true
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        }

        fun setColors(c: Colors) {
            colors = c
            surface.orientation = GradientDrawable.Orientation.TOP_BOTTOM
            surface.colors = intArrayOf(c.top, c.bottom)
            surface.setStroke(dpf(1f).roundToInt().coerceAtLeast(1), c.stroke)
            invalidate()
        }

        fun setSurfaceAlpha(a: Float) {
            val v = (255 * a.coerceIn(0f, 1f)).roundToInt()
            if (surface.alpha == v) return
            surface.alpha = v
            invalidate()
        }

        override fun onVisibilityAggregated(isVisible: Boolean) {
            super.onVisibilityAggregated(isVisible)
            shown = isVisible
            syncBreath()
        }

        override fun onDetachedFromWindow() {
            shown = false
            syncBreath()
            super.onDetachedFromWindow()
        }

        private fun syncBreath() {
            val want = shown && look == Look.RUNNING && animationsOn()
            if (want && breath == null) {
                breath = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = BREATH_MS
                    repeatCount = ValueAnimator.INFINITE
                    interpolator = LinearInterpolator()
                    addUpdateListener {
                        // 1 → 0 → 1 over one period, eased at both ends (a cosine).
                        phase = (0.5f + 0.5f * cos(2 * PI * (it.animatedValue as Float))).toFloat()
                        invalidate()
                    }
                    start()
                }
            } else if (!want && breath != null) {
                breath?.cancel()
                breath = null
                phase = 1f
                invalidate()
            }
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val c = colors ?: return
            if (markAlpha <= 0f) return
            val cx = width / 2f
            val cy = height / 2f
            ring.strokeWidth = dpf(2f)
            // Ring centre line at 10 dp: with the 2 dp stroke the mark fills the 22 dp glyph square.
            val r = dpf(10f)
            fun alpha(a: Float) = (255 * a * markAlpha).roundToInt().coerceIn(0, 255)
            when (look) {
                Look.RUNNING -> {
                    ring.color = c.accent
                    ring.alpha = alpha(0.32f + 0.68f * phase)
                    canvas.drawCircle(cx, cy, r, ring)
                    fill.color = c.accent
                    fill.alpha = alpha(1f)
                    canvas.drawCircle(cx, cy, dpf(3.5f), fill)
                }
                Look.PAUSED -> {
                    ring.color = c.muted
                    ring.alpha = alpha(0.36f)
                    canvas.drawCircle(cx, cy, r, ring)
                    fill.color = c.muted
                    fill.alpha = alpha(1f)
                    val w = dpf(2.5f)
                    val h = dpf(9f)
                    val gap = dpf(3f)
                    rect.set(cx - gap / 2 - w, cy - h / 2, cx - gap / 2, cy + h / 2)
                    canvas.drawRoundRect(rect, w / 2, w / 2, fill)
                    rect.set(cx + gap / 2, cy - h / 2, cx + gap / 2 + w, cy + h / 2)
                    canvas.drawRoundRect(rect, w / 2, w / 2, fill)
                }
                Look.STOPPED -> {
                    ring.color = c.muted
                    ring.alpha = alpha(0.36f)
                    canvas.drawCircle(cx, cy, r, ring)
                    fill.color = c.muted
                    fill.alpha = alpha(1f)
                    val s = dpf(8f)
                    rect.set(cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2)
                    canvas.drawRoundRect(rect, dpf(2f), dpf(2f), fill)
                }
            }
        }

        private fun dpf(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)
    }

    companion object {
        private const val TAG = "DshA11y"
        private const val PREFS = OverlayPrefs.FILE
        private const val K_SIDE = "ballSide"
        private const val K_Y = "ballY"

        /** First fold: the right side, a third of the way down — clear of most apps' top bars. */
        const val DEFAULT_Y = 0.3f
        const val BALL_DP = 44
        const val PAD_DP = 6
        const val EDGE_DP = 12
        const val GLIDE_MS = 260L
        const val MARK_MS = 200L
        const val BREATH_MS = 2_400L
        const val PRESS_SCALE = 0.94f

        fun animationsOn() = if (Build.VERSION.SDK_INT >= 26) ValueAnimator.areAnimatorsEnabled() else true
    }
}
