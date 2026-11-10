package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.StateListDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

/** The app's 雾蓝 surfaces and ink (app/lib/ui/theme/palette.dart), as phone/a11y/ControlOverlay.kt uses them. */
internal class OverlayPalette(val fill: Int, val stroke: Int, val ink: Int, val muted: Int, val pressed: Int) {
    companion object {
        private val light = OverlayPalette(
            fill = 0xFFFBFCFF.toInt(), stroke = 0xFFDCE0E8.toInt(), ink = 0xFF1E232E.toInt(),
            muted = 0xFF646974.toInt(), pressed = 0xFFE7EBF4.toInt(),
        )
        private val dark = OverlayPalette(
            fill = 0xFF232730.toInt(), stroke = 0xFF343841.toInt(), ink = 0xFFE6E9F0.toInt(),
            muted = 0xFF9A9EA9.toInt(), pressed = 0xFF2D323C.toInt(),
        )

        fun of(context: Context): OverlayPalette =
            if (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) dark else light
    }
}

internal fun Context.dp(v: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

/**
 * Rounded card with a small tail pointing at the pet: down when the bubble is above it, up when
 * below, sideways when beside it ([Tail]); [tailAt] is where along that edge.
 */
internal class BubbleBackground(
    private val palette: OverlayPalette,
    private val radius: Float,
    private val tailW: Float,
    val tailH: Float,
    private val strokeW: Float,
) : Drawable() {
    var tailAt = 0f
    var tail = Tail.DOWN
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.fill; style = Paint.Style.FILL }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.stroke; style = Paint.Style.STROKE; strokeWidth = strokeW }
    private val path = Path()
    private val box = RectF()

    override fun draw(canvas: Canvas) {
        val b = bounds
        val inset = strokeW / 2
        box.set(
            b.left + inset + (if (tail == Tail.LEFT) tailH else 0f),
            b.top + inset + (if (tail == Tail.UP) tailH else 0f),
            b.right - inset - (if (tail == Tail.RIGHT) tailH else 0f),
            b.bottom - inset - (if (tail == Tail.DOWN) tailH else 0f),
        )
        path.reset()
        path.addRoundRect(box, radius, radius, Path.Direction.CW)
        val tail = Path()
        when (this.tail) {
            Tail.DOWN, Tail.UP -> {
                val tx = tailAt.coerceIn(box.left + radius, maxOf(box.left + radius, box.right - radius))
                val edge = if (this.tail == Tail.DOWN) box.bottom - inset else box.top + inset
                val tip = if (this.tail == Tail.DOWN) box.bottom + tailH else box.top - tailH
                tail.moveTo(tx - tailW / 2, edge)
                tail.lineTo(tx, tip)
                tail.lineTo(tx + tailW / 2, edge)
            }
            Tail.LEFT, Tail.RIGHT -> {
                // A short card: the tail may start on the corners' curve, the union covers it.
                val ty = tailAt.coerceIn(box.top + tailW / 2, maxOf(box.top + tailW / 2, box.bottom - tailW / 2))
                val edge = if (this.tail == Tail.RIGHT) box.right - inset else box.left + inset
                val tip = if (this.tail == Tail.RIGHT) box.right + tailH else box.left - tailH
                tail.moveTo(edge, ty - tailW / 2)
                tail.lineTo(tip, ty)
                tail.lineTo(edge, ty + tailW / 2)
            }
        }
        tail.close()
        path.op(tail, Path.Op.UNION)
        canvas.drawPath(path, fill)
        canvas.drawPath(path, stroke)
    }

    override fun setAlpha(alpha: Int) {
        fill.alpha = alpha
        stroke.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        fill.colorFilter = colorFilter
        stroke.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

/** The bubble: one line, 「标题 · 做完了」 (titles only, never conversation text). */
@SuppressLint("ViewConstructor")
internal class BubbleView(context: Context, onTap: () -> Unit) : LinearLayout(context) {
    private val palette = OverlayPalette.of(context)
    private val bg = BubbleBackground(
        palette,
        radius = context.dp(14f).toFloat(),
        tailW = context.dp(12f).toFloat(),
        tailH = context.dp(6f).toFloat(),
        strokeW = context.dp(1f).coerceAtLeast(1).toFloat(),
    )
    private val padH = context.dp(14f)
    private val padV = context.dp(8f)
    private val text = TextView(context).apply {
        textSize = 14f
        setTextColor(palette.ink)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    init {
        orientation = VERTICAL
        background = bg
        addView(text, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        isClickable = true
        setOnClickListener { onTap() }
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE
        setTail(0, Tail.DOWN)
    }

    val maxBubbleWidth = context.dp(240f)

    /** How far the tail reaches out of the card. */
    val tailPx: Int get() = bg.tailH.toInt()

    fun bind(b: PetBubble) {
        text.text = b.line
        contentDescription = b.line
    }

    /** Points the tail [tail]wards, [at] px along that edge; the window grows by [tailPx] on that side. */
    fun setTail(at: Int, tail: Tail) {
        bg.tailAt = at.toFloat()
        bg.tail = tail
        val t = tailPx
        setPadding(
            padH + (if (tail == Tail.LEFT) t else 0), padV + (if (tail == Tail.UP) t else 0),
            padH + (if (tail == Tail.RIGHT) t else 0), padV + (if (tail == Tail.DOWN) t else 0),
        )
        invalidate()
    }

    /** The card's size, the tail left out, within [maxBubbleWidth]. */
    fun measureCard(): Pair<Int, Int> {
        measure(
            MeasureSpec.makeMeasureSpec(maxBubbleWidth, MeasureSpec.AT_MOST),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
        )
        return when (bg.tail) {
            Tail.DOWN, Tail.UP -> measuredWidth to measuredHeight - tailPx
            Tail.LEFT, Tail.RIGHT -> measuredWidth - tailPx to measuredHeight
        }
    }
}

/** The 「×」 at the bottom middle while dragging; [setArmed] grows it when the pet is over it. */
internal class DismissTargetView(context: Context) : View(context) {
    private val palette = OverlayPalette.of(context)
    private val disc = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.fill; style = Paint.Style.FILL }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.stroke; style = Paint.Style.STROKE; strokeWidth = context.dp(1f).coerceAtLeast(1).toFloat()
    }
    private val cross = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.ink; style = Paint.Style.STROKE; strokeWidth = context.dp(2f).toFloat(); strokeCap = Paint.Cap.ROUND
    }
    var armed = false
        private set

    fun setArmed(on: Boolean) {
        if (on == armed) return
        armed = on
        animate().scaleX(if (on) 1.2f else 1f).scaleY(if (on) 1.2f else 1f).setDuration(120).start()
    }

    override fun onDraw(canvas: Canvas) {
        val c = width / 2f
        val r = c / 1.2f - ring.strokeWidth
        canvas.drawCircle(c, c, r, disc)
        canvas.drawCircle(c, c, r, ring)
        val a = r * 0.36f
        canvas.drawLine(c - a, c - a, c + a, c + a, cross)
        canvas.drawLine(c - a, c + a, c + a, c - a, cross)
    }
}

/** Long-press menu: 「今天不再显示」, 「宠物设置」. A touch outside closes it. */
@SuppressLint("ViewConstructor")
internal class PetMenuView(
    context: Context,
    onSnooze: () -> Unit,
    onSettings: () -> Unit,
    private val onOutside: () -> Unit,
) : LinearLayout(context) {
    private val palette = OverlayPalette.of(context)

    init {
        orientation = VERTICAL
        val pad = context.dp(4f)
        setPadding(0, pad, 0, pad)
        background = GradientDrawable().apply {
            cornerRadius = context.dp(16f).toFloat()
            setColor(palette.fill)
            setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
        }
        addView(row(AppStrings.get(context, R.string.pet_snooze), onSnooze))
        addView(row(AppStrings.get(context, R.string.pet_settings), onSettings))
    }

    private fun row(label: String, action: () -> Unit) = TextView(context).apply {
        text = label
        textSize = 15f
        setTextColor(palette.ink)
        gravity = Gravity.CENTER_VERTICAL
        minHeight = context.dp(44f)
        minWidth = context.dp(168f)
        // A rounded highlight inset from the card's edge: software windows can't clip to the card.
        // Set before the padding: a background with insets would replace it.
        val inset = context.dp(4f)
        background = StateListDrawable().apply {
            addState(
                intArrayOf(android.R.attr.state_pressed),
                InsetDrawable(GradientDrawable().apply { cornerRadius = context.dp(12f).toFloat(); setColor(palette.pressed) }, inset, 0, inset, 0),
            )
        }
        setPadding(context.dp(16f), 0, context.dp(16f), 0)
        isClickable = true
        isFocusable = true
        setOnClickListener { action() }
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
            onOutside()
            return true
        }
        return super.dispatchTouchEvent(event)
    }

    fun measureFor(): Pair<Int, Int> {
        measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        return measuredWidth to measuredHeight
    }
}
