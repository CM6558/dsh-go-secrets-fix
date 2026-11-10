package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Activity
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Choreographer
import android.view.Display
import android.view.Gravity
import android.view.Surface
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.PathInterpolator
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.phone.a11y.PhoneA11yService
import io.github.ccch1mneyyy.dsh_app.runtime.DshService
import io.github.ccch1mneyyy.dsh_app.runtime.RuntimeController
import io.github.ccch1mneyyy.dsh_app.shortcuts.EntryActivity
import java.util.Calendar
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The out-of-app pet (docs/design/pets.md): a window the size of the pack's wide hit
 * box (grown around the lifted pose while held, [PetFrames]), a separate bubble window, a
 * long-press menu, and a 「×」 target while dragging. Dart pushes
 * the reduced state ([push]); when it shows is [OverlayMachine]'s call, the permission branches
 * [OverlayAccess]'s, the dock [EdgeSnap]'s, what plays [PetPlayer]'s.
 *
 * Window type: TYPE_ACCESSIBILITY_OVERLAY through the phone-control accessibility service when it
 * is on (no other permission), else TYPE_APPLICATION_OVERLAY with 「显示在其他应用上层」. Whether
 * that works is decided by adding the window, not by `canDrawOverlays` (vendor switches).
 *
 * Process-wide, main thread only. [init] comes from [PetOverlayPlugin] with the engine.
 */
internal object PetOverlay {
    interface Listener {
        fun onStatus(status: Map<String, Any?>)
        fun onOpenSettings()
    }

    private const val TAG = "DshPet"
    private const val PREFS = "dsh_pet_overlay"
    private const val K_ENABLED = "enabled"
    private const val K_ALWAYS = "alwaysShow"
    private const val K_SNOOZE = "snoozedUntil"
    private const val K_SIDE = "dockSide"
    private const val K_Y = "dockY"
    private const val EDGE_DP = 8f
    private const val POLL_MS = 2_000L
    private const val OPEN_CHECK_MS = 1_500L
    private const val MENU_MS = 8_000L
    private const val TARGET_DP = 56f
    private const val TARGET_GAP_DP = 28f
    private const val CHANNEL_OPEN = "dsh-pet-open"
    private const val NOTICE_ID = 3091

    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var sprites: PetSprites
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-pet").apply { isDaemon = true } }
    private var initialized = false

    val machine = OverlayMachine()
    private var listener: Listener? = null
    private val producer = OverlayProducerOwner()

    /**
     * The pet is on screen, lit, not hidden by the system, with bubbles on: 「做完了」「出错了」
     * notifications go silent meanwhile (notify/ChatNotifier.kt), the bubble says it.
     */
    @Volatile var speaksForResults = false
        private set

    // ---- permission bookkeeping ----
    private var lastAdd: AddResult? = null
    private var failedAt = 0L
    private var lastCanDraw: Boolean? = null

    // ---- pack ----
    private var loaded: PetSprites.Loaded? = null
    private var loadedKey: String? = null
    private var loadingKey: String? = null
    private var loadRequest = 0L
    private val failedIds = HashSet<String>()

    // ---- windows ----
    private val windows = OverlayWindowOwner()
    private val windowTickets = IdentityHashMap<View, OverlayWindowOwner.Ticket>()
    private var petTicket: OverlayWindowOwner.Ticket? = null
    private var host = OverlayHost.NONE
    private var hostContext: Context? = null
    private var appWindowContext: Context? = null
    private var wm: WindowManager? = null
    private var petView: PetView? = null
    private var petParams: WindowManager.LayoutParams? = null
    private var systemShown = true
    private var bubbleView: BubbleView? = null
    private var bubbleId: String? = null
    private var menuView: PetMenuView? = null
    private var target: DismissTargetView? = null
    private var targetCenter: WindowPos? = null
    private var dock = Dock.DEFAULT
    private var tucked = false
    private var dragStart: WindowPos? = null
    /** Where the finger puts the rest frame, kept on screen as before the window grew: release and 「×」 read it. */
    private var dropAt: WindowPos? = null
    private var dragging = false
    private var slideAnim: ValueAnimator? = null
    private var lastVisibility = Visibility.HIDDEN
    private var lastWhy = ""

    // ---- animation ----
    private val player = PetPlayer()
    private var stateKey: String? = null
    private var looping = false

    // ---- app state ----
    private var started = 0
    private var pendingSettings = false
    private var lastStatus: Map<String, Any?>? = null
    private var lastConfig: Configuration? = null
    private var openPendingIntent: PendingIntent? = null

    fun init(context: Context, assetPath: (String) -> String) {
        if (initialized) return
        initialized = true
        app = context.applicationContext
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        sprites = PetSprites(app, assetPath)
        machine.enabled = prefs.getBoolean(K_ENABLED, false)
        machine.alwaysShow = prefs.getBoolean(K_ALWAYS, false)
        machine.snoozedUntil = prefs.getLong(K_SNOOZE, 0L)
        dock = Dock(
            if (prefs.getString(K_SIDE, null) == "left") Side.LEFT else Side.RIGHT,
            prefs.getFloat(K_Y, Dock.DEFAULT.yFraction),
        )
        if (MainActivity.inForeground) started = 1
        (app as? Application)?.registerActivityLifecycleCallbacks(lifecycle)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED) else app.registerReceiver(screen, filter)
        lastConfig = Configuration(app.resources.configuration)
        app.registerComponentCallbacks(config)
        RuntimeController.get(app).addSink { event -> if (event["type"] == "status") main.postDelayed(evaluateRunnable, 300) }
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) PetOverlayProbe.register(app)
        machine.onForeground(started > 0, now())
    }

    // ---- from Dart ------------------------------------------------------------------------------

    fun attachProducer(nextListener: Listener): Long {
        val token = producer.attach()
        resetProducer()
        listener = nextListener
        lastStatus = null
        return token
    }

    fun ownsProducer(token: Long) = producer.owns(token)

    fun detachProducer(token: Long) {
        if (!producer.detach(token)) return
        listener = null
        resetProducer()
    }

    private fun resetProducer() {
        loadRequest++
        loadingKey = null
        pendingSettings = false
        machine.resetProducer()
        removeWindows()
        evaluate()
    }

    fun push(args: Map<*, *>) {
        if (!initialized) return
        val p = PetPush.fromMap(args, now())
        machine.onPush(p, now())
        p.packId?.let { ensurePack(it, p.size) }
        retarget()
        evaluate()
    }

    fun setEnabled(on: Boolean): Map<String, Any?> {
        machine.enabled = on
        prefs.edit().putBoolean(K_ENABLED, on).apply()
        if (on) {
            failedIds.clear()
            machine.last?.let { p -> p.packId?.let { ensurePack(it, p.size) } }
        }
        evaluate()
        return status()
    }

    fun setAlwaysShow(on: Boolean): Map<String, Any?> {
        machine.alwaysShow = on
        prefs.edit().putBoolean(K_ALWAYS, on).apply()
        evaluate()
        return status()
    }

    fun unsnooze(): Map<String, Any?> {
        machine.snoozedUntil = 0L
        prefs.edit().putLong(K_SNOOZE, 0L).apply()
        evaluate()
        return status()
    }

    /** Status after a real check: adds (and removes) an invisible window unless the pet's own proves it. */
    fun permissionStatus(): Map<String, Any?> {
        refreshCanDraw()
        if (!a11yConnected() && !(host == OverlayHost.APPLICATION && petView?.isAttachedToWindow == true)) probe()
        evaluate()
        return status()
    }

    fun status(): Map<String, Any?> {
        val canDraw = canDraw()
        val a11y = a11yConnected()
        return mapOf(
            "enabled" to machine.enabled,
            "alwaysShow" to machine.alwaysShow,
            "permission" to OverlayAccess.permission(a11y, canDraw, lastAdd).wire,
            "canDraw" to canDraw,
            "accessibility" to a11y,
            "snoozed" to machine.snoozed(now()),
            "showing" to (petView?.isAttachedToWindow == true),
            "sdk" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
        )
    }

    /** 「今天不再显示」: hidden until local midnight. */
    fun snoozeToday() {
        val c = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        machine.snoozedUntil = c.timeInMillis
        prefs.edit().putLong(K_SNOOZE, c.timeInMillis).apply()
        evaluate()
    }

    // ---- the rules, applied ---------------------------------------------------------------------

    private fun now() = System.currentTimeMillis()

    private val evaluateRunnable = Runnable { evaluate() }

    fun evaluate() {
        if (!initialized) return
        main.removeCallbacks(evaluateRunnable)
        refreshCanDraw()
        machine.canHost = OverlayAccess.host(a11yConnected(), lastAdd) != OverlayHost.NONE
        machine.hasPet = loaded != null && loadedKey == packKey(machine.last)
        machine.phoneTask = PhoneControl.peek()?.foregroundLine() != null
        machine.dshService = DshService.isRunning
        machine.interactive = interactive()
        val t = now()
        val d = machine.decide(t)
        if (d.visibility != lastVisibility || d.why != lastWhy) {
            Log.i(TAG, "overlay ${d.visibility.name.lowercase()}: ${d.why}")
            lastVisibility = d.visibility
            lastWhy = d.why
        }
        when (d.visibility) {
            Visibility.HIDDEN -> {
                stopLoop()
                removeWindows()
            }
            Visibility.PAUSED -> {
                stopLoop()
                dismissMenu()
            }
            Visibility.SHOWN -> {
                val before = lastAdd
                if (!attachPet()) {
                    // With the permission now known not to work, decide again; else retry at the next poll.
                    if (lastAdd != before) main.post(evaluateRunnable)
                } else {
                    retarget()
                    if (!dragging) setTucked(d.tucked)
                    if (tucked || !systemShown) stopLoop() else startLoop()
                    showBubble(d.bubble)
                }
            }
        }
        speaksForResults = ResultSilence.petSpeaks(d.visibility, petView?.isAttachedToWindow == true, systemShown, machine.last?.quiet == true)
        PetOverlayService.ensure(app, d.ownService)
        // Polled only while out (or held back by a phone task): the accessibility service, a phone
        // task and DshService change without telling us.
        val poll = d.visibility == Visibility.SHOWN || (machine.phoneTask && machine.enabled && !machine.appForeground)
        val wake = listOfNotNull(d.wakeAt?.let { it - t }, if (poll) POLL_MS else null).minOrNull()
        if (wake != null) main.postDelayed(evaluateRunnable, wake.coerceAtLeast(50))
        publishStatus()
    }

    private fun publishStatus() {
        val s = status()
        if (s != lastStatus) {
            lastStatus = s
            listener?.onStatus(s)
        }
    }

    // ---- permission -----------------------------------------------------------------------------

    private fun a11yConnected() = PhoneA11yService.instance != null

    private fun canDraw(): Boolean = try { Settings.canDrawOverlays(app) } catch (_: Exception) { false }

    private fun refreshCanDraw() {
        val cd = canDraw()
        val changed = lastCanDraw != null && lastCanDraw != cd
        lastCanDraw = cd
        if (lastAdd == AddResult.FAILED && OverlayAccess.retry(lastAdd, failedAt, now(), cd, changed)) lastAdd = null
    }

    /** Adds a 1×1 invisible application overlay and removes it again; the result is the permission. */
    private fun probe() {
        val ctx = appWindowContext()
        val w = ctx.getSystemService(WindowManager::class.java) ?: return
        val v = View(ctx)
        val p = WindowManager.LayoutParams(
            1, 1, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply { alpha = 0f; gravity = Gravity.TOP or Gravity.START; title = AppStrings.get(app, R.string.pet_window_title) }
        lastAdd = try {
            w.addView(v, p)
            try { w.removeViewImmediate(v) } catch (_: Exception) {}
            AddResult.OK
        } catch (e: Exception) {
            Log.i(TAG, "overlay permission probe failed: ${e.javaClass.simpleName}")
            failedAt = now()
            AddResult.FAILED
        }
    }

    // ---- pack -----------------------------------------------------------------------------------

    private fun packKey(p: PetPush?): String? = p?.packId?.let { "$it@${p.size}" }

    private fun ensurePack(id: String, size: String) {
        val key = "$id@$size"
        if (key == loadedKey || key == loadingKey || id in failedIds) return
        loadingKey = key
        val request = ++loadRequest
        val density = app.resources.displayMetrics.density
        worker.execute {
            val l = sprites.load(id, worker) { pack -> pack.screenScale(PetPack.bodyDp(size), density) }
            l?.warmResident()
            main.post {
                if (request != loadRequest || loadingKey != key || packKey(machine.last) != key) {
                    if (request == loadRequest) loadingKey = null
                    l?.release()
                    return@post
                }
                loadingKey = null
                if (l == null) {
                    Log.w(TAG, "pet pack $id not found")
                    failedIds += id
                } else {
                    loaded?.release()
                    loaded = l
                    loadedKey = key
                    stateKey = null
                    if (petView != null) removeWindows()
                }
                evaluate()
            }
        }
    }

    // ---- animation ------------------------------------------------------------------------------

    /** Starts the pushed state's animation; restarts only when the state, tier or pack changes. */
    private fun retarget() {
        val l = loaded ?: return
        val p = machine.last ?: return
        // The floating pet doesn't roam: roam plays as idle.
        val state = if (p.state == PetPush.ROAM) PetPack.IDLE else p.state
        val key = "${l.pack.id}|$state|${p.tier}|${p.reduceMotion}"
        if (key == stateKey) return
        stateKey = key
        val pack = l.pack
        // Calm states hold a still frame and play one action every 8–15 s: for idle,
        // a cycle of the plain idle (blink, breath) or now and then one from the pack's idle pool.
        val calmPool = when (state) {
            PetPack.IDLE -> pack.primary(state, 0).let { base -> listOf(PetIdleItem(base, base.totalMs, 3)) } + pack.idlePool
            PetPush.SLEEPING -> pack.primary(state, 0).let { listOf(PetIdleItem(it, it.totalMs, 1)) }
            else -> null
        }
        player.setState(pack.primary(state, p.tier), calmPool, pack.bonusOf(state, p.tier), SystemClock.uptimeMillis())
        if (looping) restartLoop() else petView?.let { drawStill() }
    }

    private fun react(kind: String, loop: Boolean) {
        val a = loaded?.pack?.reaction(kind) ?: return
        player.react(a, loop, SystemClock.uptimeMillis())
        restartLoop()
    }

    private var frame: Choreographer.FrameCallback? = null

    private fun startLoop() {
        if (looping) return
        if (!alive(petTicket)) return
        looping = true
        tick()
    }

    private fun restartLoop() {
        if (!looping) return
        frame?.let { Choreographer.getInstance().removeFrameCallback(it) }
        frame = null
        tick()
    }

    private fun stopLoop() {
        looping = false
        frame?.let { Choreographer.getInstance().removeFrameCallback(it) }
        frame = null
    }

    /** One frame, then sleep until the picture next changes (the still idle frame waits seconds). */
    private fun tick() {
        if (!looping) return
        val ticket = petTicket
        if (!alive(ticket)) return
        val view = petView ?: return
        val l = loaded ?: return
        player.still = !animationsOn()
        val f = player.frame(SystemClock.uptimeMillis()) ?: return
        if (!view.show(f.anim, f.index)) {
            l.request(f.anim) { if (alive(ticket) && loaded === l) redraw() }
            return
        }
        onShown()
        f.nextInMs?.let { delay ->
            lateinit var callback: Choreographer.FrameCallback
            callback = Choreographer.FrameCallback {
                if (frame === callback) {
                    frame = null
                    if (alive(ticket)) tick()
                }
            }
            frame = callback
            Choreographer.getInstance().postFrameCallbackDelayed(callback, delay.coerceAtLeast(8))
        }
    }

    /** Paused or tucked: still draw the current picture once (sheet permitting). */
    private fun drawStill() {
        val ticket = petTicket
        if (!alive(ticket)) return
        val view = petView ?: return
        val l = loaded ?: return
        val f = player.frame(SystemClock.uptimeMillis()) ?: return
        if (view.show(f.anim, f.index)) onShown() else l.request(f.anim) { if (alive(ticket) && loaded === l) redraw() }
    }

    /** A picture is on screen: the window fits it, a bubble moves over it. */
    private fun onShown() {
        fitFrame()
        followBubble()
    }

    /** A sheet arrived: carry on playing, or show its still picture. */
    private fun redraw() {
        if (looping) restartLoop() else drawStill()
    }

    // ---- the window's frame ---------------------------------------------------------------------

    /** Where the rest frame sits now: the window, less how far its frame reaches past rest. */
    private fun restPos(v: PetView, p: WindowManager.LayoutParams) = PetFrames.restOf(WindowPos(p.x, p.y), v.frame)

    private fun placeRest(v: PetView, p: WindowManager.LayoutParams, rest: WindowPos) {
        val at = PetFrames.windowAt(rest, v.frame)
        p.x = at.x
        p.y = at.y
    }

    /**
     * Sizes the pet window to what it shows (docs/design/pets.md §6.1): grown around the lifted pose
     * while held and until that picture is gone, around happy / waking / typing while one of them
     * shows, the rest frame otherwise. The rest frame keeps its place, so the pet doesn't move on
     * screen: held, the grown window is kept whole on screen; docked, the dock already left room for
     * every frame ([PetFrames.reach]). One window update when the frame changes, none while it stays.
     */
    private fun fitFrame() {
        val v = petView ?: return
        val p = petParams ?: return
        val l = loaded ?: return
        if (!alive(petTicket)) return
        val next = l.frames.frameFor(v.shown, dragging)
        if (next == v.frame) return
        val rest = restPos(v, p)
        v.setFrame(next)
        p.width = next.width
        p.height = next.height
        placeRest(v, p, rest)
        if (dragging) EdgeSnap.clampDrag(p.x, p.y, p.width, p.height, safeArea()).let { p.x = it.x; p.y = it.y }
        update(v, p)
    }

    // ---- windows --------------------------------------------------------------------------------

    private fun appWindowContext(): Context {
        appWindowContext?.let { return it }
        val ctx = if (Build.VERSION.SDK_INT >= 30) {
            val display = app.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
            app.createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
        } else {
            app
        }
        appWindowContext = ctx
        return ctx
    }

    private fun windowType(h: OverlayHost) =
        if (h == OverlayHost.ACCESSIBILITY) WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY else WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY

    private fun baseParams(w: Int, h: Int, flags: Int) = WindowManager.LayoutParams(
        w, h, windowType(host),
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or flags,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        title = AppStrings.get(app, R.string.pet_window_title)
        if (Build.VERSION.SDK_INT >= 28) layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    private fun edge(ctx: Context) = ctx.dp(EDGE_DP)

    /** The pet window, on the right host; false when it couldn't be added. */
    private fun attachPet(): Boolean {
        val want = OverlayAccess.host(a11yConnected(), lastAdd)
        if (want == OverlayHost.NONE) return false
        val ctx = if (want == OverlayHost.ACCESSIBILITY) PhoneA11yService.instance ?: return false else appWindowContext()
        val current = petView
        if (current != null && host == want && windows.isHost(ctx) && alive(petTicket)) return true
        removeWindows()
        if (!windows.begin(ctx)) return false
        val w = ctx.getSystemService(WindowManager::class.java) ?: return false
        host = want
        hostContext = ctx
        wm = w
        val ticket = windows.claim(OverlayWindowOwner.Role.PET) ?: return false
        petTicket = ticket
        val view = PetView(ctx, petListener(ticket)).apply { setSprites(loaded) }
        if (view.pixelWidth <= 0) {
            removeWindows()
            return false
        }
        view.contentDescription = loaded?.pack?.name ?: AppStrings.get(app, R.string.pet_label)
        tucked = false
        systemShown = true
        val pos = EdgeSnap.position(dock, view.reach, safeArea(), edge(ctx))
        val params = baseParams(view.pixelWidth, view.pixelHeight, 0).apply { x = pos.x; y = pos.y }
        petView = view
        petParams = params
        return try {
            // The 「×」 goes in first, hidden, so the dragged pet stays above it.
            addTarget(ctx, w)
            if (!installWindow(ticket, view, w, params)) {
                removeWindows()
                return false
            }
            if (want == OverlayHost.APPLICATION) lastAdd = AddResult.OK
            enter(view)
            drawStill()
            true
        } catch (e: Exception) {
            Log.i(TAG, "overlay add failed (${want.name.lowercase()}): ${e.javaClass.simpleName}")
            removeWindows()
            if (want == OverlayHost.APPLICATION) {
                lastAdd = AddResult.FAILED
                failedAt = now()
            }
            host = OverlayHost.NONE
            false
        }
    }

    private fun removeWindows() {
        // Invalidate input/async callbacks before cancel() or platform removal can call us back.
        windows.retire()
        stopLoop()
        openPendingIntent?.cancel()
        openPendingIntent = null
        if (initialized) app.getSystemService(NotificationManager::class.java)?.cancel(NOTICE_ID)
        slideAnim?.cancel()
        slideAnim = null
        dismissMenu()
        removeBubble()
        removeTarget()
        petView?.let { remove(it) }
        petView = null
        petTicket = null
        petParams = null
        dragging = false
        tucked = false
        player.endReaction()
        speaksForResults = false
        host = OverlayHost.NONE
        hostContext = null
        wm = null
        scheduleCleanup()
    }

    private fun update(v: View, p: WindowManager.LayoutParams) {
        if (!alive(windowTickets[v])) return
        try { wm?.updateViewLayout(v, p) } catch (e: Exception) { Log.w(TAG, "overlay update failed", e) }
    }

    private fun remove(v: View) {
        val ticket = windowTickets.remove(v)
        windows.remove(ticket)
        v.animate().cancel()
        scheduleCleanup()
    }

    private fun alive(ticket: OverlayWindowOwner.Ticket?) = windows.owns(petTicket) && windows.owns(ticket)

    private val cleanupRunnable = Runnable {
        windows.retryRemovals()
        scheduleCleanup()
        evaluate()
    }

    private fun scheduleCleanup() {
        main.removeCallbacks(cleanupRunnable)
        if (windows.pendingRemovals > 0) main.postDelayed(cleanupRunnable, POLL_MS)
    }

    private fun installWindow(ticket: OverlayWindowOwner.Ticket, v: View, manager: WindowManager, p: WindowManager.LayoutParams): Boolean {
        val attached = object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = Unit
            override fun onViewDetachedFromWindow(view: View) {
                if (!windows.owns(ticket)) return
                windows.revoke(ticket)
                main.post {
                    if (petTicket == ticket) removeWindows() else if (windowTickets[v] == ticket) remove(v)
                    evaluate()
                }
            }
        }
        v.addOnAttachStateChangeListener(attached)
        windowTickets[v] = ticket
        val removal = OverlayRemoval(
            request = {
                // The exact manager which accepted add; pending attachment is still owned.
                try {
                    manager.removeViewImmediate(v)
                } catch (e: IllegalArgumentException) {
                    // WindowManager reports an unregistered view, including failed add.
                    // Do not infer this from attachment state without actually trying remove.
                    if (v.isAttachedToWindow || v.parent != null) throw e
                }
            },
            detached = { !v.isAttachedToWindow && v.parent == null },
            nextTurn = { confirm ->
                main.post {
                    confirm()
                    windows.retryRemovals()
                    scheduleCleanup()
                    evaluate()
                }
            },
        )
        return try {
            windows.install(ticket, remove = {
                if (removal.attempt()) {
                    v.removeOnAttachStateChangeListener(attached)
                    if (windowTickets[v] == ticket) windowTickets.remove(v)
                    true
                } else {
                    false
                }
            }, add = { manager.addView(v, p) })
        } finally {
            scheduleCleanup()
        }
    }

    private val easing = PathInterpolator(0.2f, 0f, 0f, 1f)

    private fun animationsOn() = machine.last?.reduceMotion != true && ValueAnimator.areAnimatorsEnabled()

    private fun enter(v: PetView) {
        if (!animationsOn()) return
        v.alpha = 0f
        v.scaleX = 0.9f
        v.scaleY = 0.9f
        v.pivotX = v.pixelWidth / 2f
        v.pivotY = v.pixelHeight.toFloat()
        v.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(220).setInterpolator(easing).start()
    }

    /** Slides into or out of the half-hidden spot at the edge. */
    private fun setTucked(on: Boolean) {
        if (on == tucked) return
        val v = petView ?: return
        val p = petParams ?: return
        tucked = on
        if (on) {
            dismissMenu()
            removeBubble()
        }
        val area = safeArea()
        val to = if (on) EdgeSnap.tucked(dock, v.pixelWidth, v.reach, area, edge(v.context)) else EdgeSnap.position(dock, v.reach, area, edge(v.context))
        // Out again: the bubble that called it waits for the slide, then shows.
        slide(v, p, to, then = if (on) null else ({ evaluate() }))
    }

    /** The screen minus status / navigation bars and the cutout. */
    private fun safeArea(): SafeArea {
        val w = wm ?: appWindowContext().getSystemService(WindowManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) {
            val m = w.currentWindowMetrics
            val i = m.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return SafeArea(m.bounds.width(), m.bounds.height(), i.left, i.top, i.right, i.bottom)
        }
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        val display = w.defaultDisplay
        @Suppress("DEPRECATION")
        display.getRealMetrics(dm)
        val res = Resources.getSystem()
        fun dimen(name: String) = res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize) ?: 0
        val status = dimen("status_bar_height")
        val nav = dimen("navigation_bar_height")
        return when (display.rotation) {
            Surface.ROTATION_90 -> SafeArea(dm.widthPixels, dm.heightPixels, 0, status, nav, 0)
            Surface.ROTATION_270 -> SafeArea(dm.widthPixels, dm.heightPixels, nav, status, 0, 0)
            else -> SafeArea(dm.widthPixels, dm.heightPixels, 0, status, 0, nav)
        }
    }

    // ---- touch ----------------------------------------------------------------------------------

    private fun petListener(ticket: OverlayWindowOwner.Ticket) = object : PetView.Listener {
        override fun onDragStart() {
            if (!alive(ticket)) return
            val v = petView ?: return
            val p = petParams ?: return
            slideAnim?.cancel()
            // Kept as the rest frame's place: the window grows around the lifted pose (fitFrame).
            dragStart = restPos(v, p)
            dropAt = dragStart
            dragging = true
            tucked = false
            machine.onTouch(now())
            dismissMenu()
            removeBubble()
            showTarget()
            react("drag", loop = true)
            startLoop()
            fitFrame()
        }

        override fun onDrag(dx: Int, dy: Int) {
            if (!alive(ticket)) return
            val v = petView ?: return
            val p = petParams ?: return
            val s = dragStart ?: return
            val area = safeArea()
            // The window, lifted pose and all, stays whole on screen.
            val pos = EdgeSnap.carry(s, dx, dy, v.frame, area)
            p.x = pos.x
            p.y = pos.y
            update(v, p)
            // Release and 「×」 read the rest frame where the finger puts it, kept on screen as it
            // always was: docking doesn't change, though at the top the held window stops earlier.
            val drop = EdgeSnap.clampDrag(s.x + dx, s.y + dy, v.pixelWidth, v.pixelHeight, area)
            dropAt = drop
            val c = targetCenter
            target?.setArmed(c != null && EdgeSnap.overDismiss(drop, v.pixelWidth, v.pixelHeight, c, v.context.dp(TARGET_DP)))
        }

        override fun onDragEnd(velocityX: Float) {
            if (!alive(ticket)) return
            val v = petView ?: return
            val p = petParams ?: return
            dragging = false
            player.endReaction()
            val dismiss = target?.armed == true
            hideTarget()
            machine.onTouch(now())
            if (dismiss) {
                // Dropped on 「×」: today it stays away.
                snoozeToday()
                return
            }
            // Put down: the state's picture now, and the window back to rest around the same
            // origin (later, if that picture's sheet has to be decoded again first).
            redraw()
            fitFrame()
            val area = safeArea()
            val drop = dropAt ?: restPos(v, p)
            dock = EdgeSnap.dockFor(drop, v.pixelWidth, v.reach, area, edge(v.context), velocityX)
            prefs.edit().putString(K_SIDE, if (dock.side == Side.LEFT) "left" else "right").putFloat(K_Y, dock.yFraction).apply()
            slide(v, p, EdgeSnap.position(dock, v.reach, area, edge(v.context))) { evaluate() }
        }

        override fun onTap(leftHalf: Boolean) {
            if (!alive(ticket)) return
            machine.onTouch(now())
            dismissMenu()
            react(if (leftHalf) "tapLeft" else "tapRight", loop = false)
            val push = machine.last
            open(push?.sessionId, push?.host, null)
        }

        override fun onLongPress() {
            if (!alive(ticket)) return
            machine.onTouch(now())
            if (tucked) evaluate()
            showMenu()
        }

        override fun onShownChanged(shown: Boolean) {
            if (!alive(ticket)) return
            if (shown == systemShown) return
            systemShown = shown
            // Hidden by the system (another app's setHideOverlayWindows): wait, don't re-add.
            main.post(evaluateRunnable)
        }
    }

    /** Slides the rest frame to [to]; the window follows with whatever frame it has at each step. */
    private fun slide(v: PetView, p: WindowManager.LayoutParams, to: WindowPos, then: (() -> Unit)?) {
        val ticket = windowTickets[v]
        if (!alive(ticket)) return
        slideAnim?.cancel()
        if (!animationsOn()) {
            placeRest(v, p, to)
            update(v, p)
            then?.invoke()
            return
        }
        val from = restPos(v, p)
        slideAnim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 260
            interpolator = easing
            addUpdateListener { a ->
                if (!alive(ticket)) return@addUpdateListener
                val f = a.animatedValue as Float
                placeRest(v, p, WindowPos((from.x + (to.x - from.x) * f).roundToInt(), (from.y + (to.y - from.y) * f).roundToInt()))
                update(v, p)
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (slideAnim === animation) slideAnim = null
                    if (!cancelled && alive(ticket)) then?.invoke()
                }
            })
            start()
        }
    }

    // ---- 「×」 target ----------------------------------------------------------------------------

    private fun addTarget(ctx: Context, w: WindowManager) {
        removeTarget()
        val ticket = windows.claim(OverlayWindowOwner.Role.TARGET) ?: return
        val size = (ctx.dp(TARGET_DP) * 1.2f).roundToInt()
        val c = EdgeSnap.dismissCenter(safeArea(), size, ctx.dp(TARGET_GAP_DP))
        val view = DismissTargetView(ctx).apply { visibility = View.GONE }
        val params = baseParams(size, size, WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE).apply {
            x = c.x - size / 2
            y = c.y - size / 2
        }
        target = view
        targetCenter = c
        installWindow(ticket, view, w, params)
    }

    private fun showTarget() {
        val view = target ?: return
        view.setArmed(false)
        view.visibility = View.VISIBLE
        if (animationsOn()) {
            view.alpha = 0f
            view.animate().alpha(1f).setDuration(150).start()
        }
    }

    private fun hideTarget() {
        target?.let {
            it.animate().cancel()
            it.visibility = View.GONE
        }
    }

    private fun removeTarget() {
        target?.let { remove(it) }
        target = null
        targetCenter = null
    }

    // ---- bubble ---------------------------------------------------------------------------------

    private fun showBubble(b: PetBubble?) {
        if (b == null || dragging || tucked || slideAnim != null) {
            removeBubble()
            return
        }
        val ctx = hostContext ?: return
        if (bubbleId == b.id && alive(bubbleView?.let { windowTickets[it] })) return
        removeBubble()
        val ticket = windows.claim(OverlayWindowOwner.Role.BUBBLE) ?: return
        val view = BubbleView(ctx) { if (alive(ticket)) onBubbleTap(b) }
        view.bind(b)
        val card = view.measureCard()
        val shown = petView?.shown?.name
        val place = bubblePlace(card, view.tailPx) ?: return
        view.setTail(place.tailAt, place.tail)
        val params = baseParams(place.w, place.h, 0).apply { x = place.pos.x; y = place.pos.y }
        try {
            val manager = wm ?: return
            if (!installWindow(ticket, view, manager, params)) return
        } catch (e: Exception) {
            Log.w(TAG, "bubble add failed", e)
            return
        }
        bubbleView = view
        bubbleId = b.id
        bubbleParams = params
        bubbleCard = card
        bubbleFor = shown
        if (animationsOn()) {
            // Comes out of the tail's side, towards where it rests.
            val d = ctx.dp(4f).toFloat()
            view.alpha = 0f
            when (place.tail) {
                Tail.DOWN -> view.translationY = d
                Tail.UP -> view.translationY = -d
                Tail.RIGHT -> view.translationX = d
                Tail.LEFT -> view.translationX = -d
            }
            view.animate().alpha(1f).translationX(0f).translationY(0f).setDuration(200).setInterpolator(easing).start()
        }
    }

    /**
     * Where the bubble goes for the picture on screen now (docs/design/pets.md §2.7): over the
     * body and the current animation's cell, so a jump or a thought cloud stays in front of it.
     */
    private fun bubblePlace(card: Pair<Int, Int>, tailPx: Int): BubblePlacement? {
        val ctx = hostContext ?: return null
        val pv = petView ?: return null
        val pp = petParams ?: return null
        val f = loaded?.frames ?: return null
        val rest = restPos(pv, pp)
        return EdgeSnap.bubble(
            f.body.at(rest), f.art(pv.shown).at(rest), dock.side, card.first, card.second, tailPx, safeArea(),
            gap = ctx.dp(4f), margin = edge(ctx), tailInset = ctx.dp(20f),
        )
    }

    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleCard: Pair<Int, Int>? = null
    /** The animation the bubble was placed over. */
    private var bubbleFor: String? = null
    private var bubbleMove: ValueAnimator? = null

    /**
     * The picture under a bubble changed (idle to a jump, say): the bubble glides to its place over
     * the new one, the way the chat page's bubble follows the head. Nothing to do while it stays.
     */
    private fun followBubble() {
        val view = bubbleView ?: return
        val p = bubbleParams ?: return
        val card = bubbleCard ?: return
        val ticket = windowTickets[view]
        if (!alive(ticket)) return
        val shown = petView?.shown?.name
        if (shown == bubbleFor) return
        bubbleFor = shown
        val place = bubblePlace(card, view.tailPx) ?: return
        bubbleMove?.cancel()
        view.setTail(place.tailAt, place.tail)
        p.width = place.w
        p.height = place.h
        val from = WindowPos(p.x, p.y)
        if (!animationsOn() || from == place.pos) {
            p.x = place.pos.x
            p.y = place.pos.y
            update(view, p)
            return
        }
        bubbleMove = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 200
            interpolator = easing
            addUpdateListener { a ->
                if (!alive(ticket) || bubbleParams !== p) return@addUpdateListener
                val t = a.animatedValue as Float
                p.x = (from.x + (place.pos.x - from.x) * t).roundToInt()
                p.y = (from.y + (place.pos.y - from.y) * t).roundToInt()
                update(view, p)
            }
            start()
        }
    }

    private fun removeBubble() {
        bubbleMove?.cancel()
        bubbleMove = null
        bubbleView?.let { remove(it) }
        bubbleView = null
        bubbleId = null
        bubbleParams = null
        bubbleCard = null
        bubbleFor = null
    }

    private fun onBubbleTap(b: PetBubble) {
        machine.onTouch(now())
        machine.bubbles.dismiss()
        removeBubble()
        val push = machine.last
        if (b.sessionId != null) open(b.sessionId, b.host, b.title) else open(push?.sessionId, push?.host, b.title)
    }

    // ---- menu -----------------------------------------------------------------------------------

    private var menuTimeout: Runnable? = null

    private fun showMenu() {
        val currentTicket = menuView?.let { windowTickets[it] }
        if (currentTicket != null && alive(currentTicket)) {
            // Reuse the live menu: removing it would reserve MENU until the
            // next-loop confirmation, so an immediate replacement cannot add.
            scheduleMenuTimeout(currentTicket)
            return
        }
        dismissMenu()
        val ctx = hostContext ?: return
        val pv = petView ?: return
        val reach = pv.reach
        val ph = pv.pixelHeight
        val ticket = windows.claim(OverlayWindowOwner.Role.MENU) ?: return
        val view = PetMenuView(
            ctx,
            onSnooze = {
                if (alive(ticket)) {
                    dismissMenu()
                    snoozeToday()
                }
            },
            onSettings = {
                if (alive(ticket)) {
                    dismissMenu()
                    pendingSettings = true
                    open(null, null, null)
                    if (started > 0) deliverSettings()
                }
            },
            onOutside = { if (alive(ticket)) dismissMenu() },
        )
        val (mw, mh) = view.measureFor()
        val area = safeArea()
        val gap = ctx.dp(8f)
        // Beside the docked spot (the pet may still be sliding out of its tucked one), clear of
        // whatever frame the window may grow to there.
        val at = EdgeSnap.position(dock, reach, area, edge(ctx))
        val x = if (dock.side == Side.RIGHT) at.x + reach.left - gap - mw else at.x + reach.right + gap
        val y = at.y + ph / 2 - mh / 2
        val params = baseParams(mw, mh, WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH).apply {
            this.x = x.coerceIn(area.left + gap, max(area.left + gap, area.screenW - area.right - gap - mw))
            this.y = y.coerceIn(area.top + gap, max(area.top + gap, area.screenH - area.bottom - gap - mh))
        }
        try {
            val manager = wm ?: return
            if (!installWindow(ticket, view, manager, params)) return
        } catch (e: Exception) {
            Log.w(TAG, "menu add failed", e)
            return
        }
        menuView = view
        if (animationsOn()) {
            view.alpha = 0f
            view.animate().alpha(1f).setDuration(150).setInterpolator(easing).start()
        }
        scheduleMenuTimeout(ticket)
    }

    private fun scheduleMenuTimeout(ticket: OverlayWindowOwner.Ticket) {
        menuTimeout?.let(main::removeCallbacks)
        Runnable { if (alive(ticket)) dismissMenu() }.also {
            menuTimeout = it
            main.postDelayed(it, MENU_MS)
        }
    }

    private fun dismissMenu() {
        menuTimeout?.let(main::removeCallbacks)
        menuTimeout = null
        menuView?.let { remove(it) }
        menuView = null
    }

    private fun deliverSettings() {
        if (!pendingSettings) return
        pendingSettings = false
        listener?.onOpenSettings()
    }

    // ---- opening the app ------------------------------------------------------------------------

    /**
     * Opens [sessionId] (or just the app) through EntryActivity. A tap on an overlay may start an
     * activity on stock Android, but some vendors block 「后台弹出界面」 on their own: when the app
     * isn't up shortly after, a notification takes the tap instead (as SystemActions.kt does).
     */
    private fun open(sessionId: String?, host: String?, title: String?) {
        val token = windows.openToken() ?: return
        val intent = if (sessionId != null) {
            EntryActivity.openChat(app, sessionId, host)
        } else {
            EntryActivity.openApp(app)
        }.putExtra(EntryActivity.EXTRA_PET_GENERATION, token).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            app.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "open failed", e)
            if (windows.acceptsOpen(token)) postOpenNotice(intent, title)
            return
        }
        main.postDelayed({ if (started == 0 && windows.acceptsOpen(token)) postOpenNotice(intent, title) }, OPEN_CHECK_MS)
    }

    fun acceptsOpen(token: String?) = windows.acceptsOpen(token)

    private fun postOpenNotice(intent: Intent, title: String?) {
        val nm = app.getSystemService(NotificationManager::class.java) ?: return
        if (!nm.areNotificationsEnabled()) return
        nm.createNotificationChannel(NotificationChannel(CHANNEL_OPEN, AppStrings.get(app, R.string.pet_open_channel), NotificationManager.IMPORTANCE_HIGH))
        val pi = PendingIntent.getActivity(app, NOTICE_ID, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        openPendingIntent = pi
        val n = Notification.Builder(app, CHANNEL_OPEN)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(title ?: AppStrings.APP_NAME)
            .setContentText(AppStrings.get(app, R.string.pet_tap_open))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setTimeoutAfter(60_000)
            .build()
        nm.notify(NOTICE_ID, n)
    }

    // ---- system signals -------------------------------------------------------------------------

    private fun interactive(): Boolean {
        val pm = app.getSystemService(PowerManager::class.java)
        val km = app.getSystemService(KeyguardManager::class.java)
        return (pm?.isInteractive != false) && (km?.isKeyguardLocked != true)
    }

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            evaluate()
        }
    }

    private val config = object : ComponentCallbacks2 {
        override fun onConfigurationChanged(newConfig: Configuration) {
            val diff = lastConfig?.diff(newConfig) ?: 0
            lastConfig = Configuration(newConfig)
            val relevant = ActivityInfo.CONFIG_ORIENTATION or ActivityInfo.CONFIG_SCREEN_SIZE or ActivityInfo.CONFIG_UI_MODE or ActivityInfo.CONFIG_DENSITY
            if (diff and relevant == 0) return
            removeWindows()
            if (diff and ActivityInfo.CONFIG_DENSITY != 0) {
                loadRequest++
                loadingKey = null
                loaded?.release()
                loaded = null
                loadedKey = null
                machine.last?.let { p -> p.packId?.let { ensurePack(it, p.size) } }
            }
            evaluate()
        }

        @Deprecated("Deprecated in Java")
        override fun onLowMemory() = Unit

        override fun onTrimMemory(level: Int) {
            if (petView == null) loaded?.release()
        }
    }

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            if (activity !is MainActivity) return
            started++
            machine.onForeground(true, now())
            app.getSystemService(NotificationManager::class.java)?.cancel(NOTICE_ID)
            evaluate()
            deliverSettings()
        }

        override fun onActivityStopped(activity: Activity) {
            if (activity !is MainActivity) return
            started = (started - 1).coerceAtLeast(0)
            if (started == 0) {
                machine.onForeground(false, now())
                evaluate()
            }
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityResumed(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    /** For the debug probe: what the window is doing now. */
    fun debugState(): Map<String, Any?> = mapOf(
        "visibility" to lastVisibility.name.lowercase(),
        "why" to lastWhy,
        "host" to host.name.lowercase(),
        "x" to petParams?.x, "y" to petParams?.y, "w" to petParams?.width, "h" to petParams?.height,
        "frame" to petView?.frame?.let { "${it.left},${it.top} ${it.width}x${it.height}" },
        "shown" to petView?.shown?.name,
        "dragging" to dragging,
        "dock" to "${dock.side.name.lowercase()}@${"%.2f".format(dock.yFraction)}",
        "tucked" to tucked,
        "looping" to looping,
        "bubble" to bubbleId,
        "menu" to (menuView != null),
        "service" to PetOverlayService.running,
        "scale" to loaded?.screenScale,
        "pack" to loadedKey,
        "speaksForResults" to speaksForResults,
        "windowGeneration" to windows.generation,
        "registeredWindows" to windows.registeredWindows,
        "pendingRemovals" to windows.pendingRemovals,
        "lastRemovalFailure" to windows.lastRemovalFailure,
    )
}
