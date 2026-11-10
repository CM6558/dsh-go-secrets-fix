package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.Gravity
import android.widget.TextView

/**
 * Text with a halo: before the glyphs, the same line stroked [haloWidth] wide in [haloColor] (the
 * map-label trick). On the opaque pill the halo is the card's own colour, so it doesn't show; on a
 * dimmed pill it keeps an opaque rim of surface around every stroke, so the line reads as well as
 * on the opaque one over whatever the page shows through.
 *
 * The halo pass draws the text layout directly with the view's paint switched to a stroke for the
 * moment (TextView itself sets the fill colour again on its own pass).
 */
internal class HaloText(context: Context) : TextView(context) {
    var haloColor: Int = Color.TRANSPARENT
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    var haloWidth: Float = 0f
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    override fun onDraw(canvas: Canvas) {
        val l = layout
        if (l != null && haloWidth > 0f && Color.alpha(haloColor) > 0) {
            val p = paint
            val style = p.style
            val stroke = p.strokeWidth
            val join = p.strokeJoin
            val color = p.color
            p.style = Paint.Style.STROKE
            p.strokeWidth = haloWidth
            p.strokeJoin = Paint.Join.ROUND
            p.color = haloColor
            // Where TextView puts the layout: inside the padding, centred vertically when asked.
            val box = height - extendedPaddingTop - extendedPaddingBottom
            val voffset = when (gravity and Gravity.VERTICAL_GRAVITY_MASK) {
                Gravity.CENTER_VERTICAL -> (box - l.height) / 2
                Gravity.BOTTOM -> box - l.height
                else -> 0
            }.coerceAtLeast(0)
            val save = canvas.save()
            canvas.translate(compoundPaddingLeft.toFloat() - scrollX, (extendedPaddingTop + voffset).toFloat() - scrollY)
            l.draw(canvas)
            canvas.restoreToCount(save)
            p.style = style
            p.strokeWidth = stroke
            p.strokeJoin = join
            p.color = color
        }
        super.onDraw(canvas)
    }
}
