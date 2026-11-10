package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Bundle
import io.github.muntashirakon.adb.AdbStream

/**
 * One live link to the privileged engine. Two implementations, one contract: the driver
 * sends a request Bundle and gets a response Bundle, never caring whether the engine is
 * reached over a Shizuku binder or an adb stream. Calls are serialised by the caller
 * (the bridge's single worker thread); [execute] blocks.
 */
interface PrivilegedChannel {
    fun execute(request: Bundle): Bundle
    fun alive(): Boolean
    fun close()
}

/** Shizuku transport: a straight Binder call into [PrivilegedDisplayService]. */
class ShizukuChannel(private val remote: IPrivilegedDisplay) : PrivilegedChannel {
    override fun execute(request: Bundle): Bundle = remote.execute(request)
    override fun alive(): Boolean = runCatching { remote.asBinder().pingBinder() }.getOrDefault(false)
    override fun close() { /* UserService unbind is the starter's job */ }
}

/**
 * Self-ADB transport: framed Bundles over the adb shell stream that launched
 * [PrivilegedDisplayMain]. A response frame always follows its request frame on this
 * single stream, so one lock keeps request/response paired.
 */
class AdbChannel(private val stream: AdbStream) : PrivilegedChannel {
    private val lock = Any()
    private val out = stream.openOutputStream()
    private val input = stream.openInputStream()
    private var synced = false

    override fun execute(request: Bundle): Bundle = synchronized(lock) {
        if (!synced) {
            if (!Frames.syncToMagic(input)) return Bundle().apply {
                putBoolean(Proto.OK, false); putString(Proto.ERROR, "deviceUnavailable")
            }
            synced = true
        }
        Frames.write(out, Bundles.marshal(request))
        val frame = Frames.read(input) ?: return Bundle().apply {
            putBoolean(Proto.OK, false); putString(Proto.ERROR, "deviceUnavailable")
        }
        Bundles.unmarshal(frame)
    }

    override fun alive(): Boolean = runCatching { !stream.isClosed }.getOrDefault(false)

    override fun close() {
        runCatching { execute(Bundle().apply { putString(Proto.OP, Proto.OP_DESTROY) }) }
        runCatching { stream.close() }
    }
}
