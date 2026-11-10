package io.github.ccch1mneyyy.dsh_app.update

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Flutter bridge for in-app updates: MethodChannel `dsh/update` (see lib/update/installer.dart). */
class UpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private lateinit var installer: ApkInstaller
    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        installer = ApkInstaller(appContext)
        channel = MethodChannel(binding.binaryMessenger, "dsh/update").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> result.success(installer.info())
            "canRequestInstalls" -> result.success(installer.canRequestInstalls())
            "openInstallPermission" -> result.success(installer.openInstallPermission(activity))
            "inspect" -> {
                val apk = apkArgument(call, result) ?: return
                worker.execute {
                    val info = runCatching { installer.inspect(apk) }.getOrElse { mapOf("valid" to false) }
                    main.post { result.success(info) }
                }
            }
            "install" -> {
                val apk = apkArgument(call, result) ?: return
                var replied = false
                worker.execute {
                    installer.install(
                        apk,
                        confirm = ::showConfirm,
                        onResult = { outcome ->
                            main.post {
                                if (!replied) {
                                    replied = true
                                    result.success(outcome)
                                }
                            }
                        },
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun apkArgument(call: MethodCall, result: MethodChannel.Result): File? {
        val path = call.argument<String>("path")
        val file = path?.let(::File)
        if (file == null || !file.isFile) {
            result.error("no_file", "APK not found: $path", null)
            return null
        }
        return file
    }

    /** The system's "install this update?" dialog, over our activity when we have one. */
    private fun showConfirm(intent: Intent): Boolean {
        val host = activity
        return runCatching {
            if (host != null) host.startActivity(intent) else appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
    }
}
