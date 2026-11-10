package io.github.ccch1mneyyy.dsh_app.usage

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.update.ApkInstaller
import java.io.File
import java.util.Locale

/**
 * What anonymous usage statistics say about the phone: MethodChannel `dsh/usage` (see
 * lib/usage/usage_net.dart).
 *
 * - `device` → `{versionName, versionCode, sdk, abi, maker}`.
 *
 * Only facts shared by every phone of a kind: never the model, a serial, the Android ID or an
 * advertising ID.
 */
class UsagePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var methods: MethodChannel? = null
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        methods = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "device" -> result.success(device())
            else -> result.notImplemented()
        }
    }

    private fun device(): Map<String, Any?> {
        val pkg = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        return mapOf(
            "versionName" to pkg?.versionName,
            "versionCode" to pkg?.let { ApkInstaller.versionCodeOf(it) },
            "sdk" to Build.VERSION.SDK_INT,
            "abi" to UsageDevice.abiOf(context.applicationInfo.nativeLibraryDir?.let { File(it).name }, Build.SUPPORTED_ABIS.toList()),
            "maker" to UsageDevice.makerOf(Build.MANUFACTURER),
        )
    }

    companion object {
        const val CHANNEL = "dsh/usage"
    }
}

/** The pieces of [UsagePlugin.device] that are pure functions. */
object UsageDevice {
    /** The installer's library folder names (`lib/arm64`) by Android ABI name. */
    private val ABIS = mapOf("arm64" to "arm64-v8a", "arm" to "armeabi-v7a", "x86_64" to "x86_64", "x86" to "x86")

    /**
     * The ABI this APK runs as, in Android's naming (`arm64-v8a`): from its native library
     * folder, else the phone's first supported ABI. Empty when neither says.
     */
    fun abiOf(libraryDir: String?, supported: List<String>): String =
        ABIS[libraryDir] ?: supported.firstOrNull()?.takeIf { it.isNotBlank() } ?: ""

    /**
     * `Build.MANUFACTURER` the way the share host takes it: lower case, ASCII letters, digits,
     * spaces and `. _ -` only, starting with a letter or digit, 32 at most (`vivo`); `unknown`
     * when nothing is left. lib/usage/usage_ledger.dart `usageMaker` does the same.
     */
    fun makerOf(manufacturer: String?): String {
        val kept = manufacturer.orEmpty().lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9 ._-]"), "")
            .replaceFirst(Regex("^[^a-z0-9]+"), "")
            .take(32)
            .trim()
        return kept.ifEmpty { "unknown" }
    }
}
