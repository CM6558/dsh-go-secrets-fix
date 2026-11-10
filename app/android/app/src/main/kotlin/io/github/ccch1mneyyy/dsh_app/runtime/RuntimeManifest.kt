package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import org.json.JSONObject

/**
 * Describes the Linux runtime bundled in this APK flavor
 * (assets/runtime/manifest.json, written by runtime/build-runtime.sh).
 */
data class RuntimeManifest(
    val runtimeVersion: String,
    val abi: String,
    val rootfsAsset: String,
    val rootfsBytes: Long,
    val rootfsSha256: String?,
    val uncompressedBytes: Long,
    val dshVersion: String,
    val nodeVersion: String,
    /** proot argv template; placeholders are expanded by [LaunchSpec]. */
    val launchArgv: List<String>,
    val launchEnv: Map<String, String>,
    val raw: JSONObject,
) {
    companion object {
        const val ASSET_DIR = "runtime"

        fun load(context: Context): RuntimeManifest {
            val text = context.assets.open("$ASSET_DIR/manifest.json").bufferedReader().use { it.readText() }
            val json = JSONObject(text)
            val launch = json.optJSONObject("launch") ?: JSONObject()
            val argvJson = launch.optJSONArray("argv")
            val argv = if (argvJson != null) List(argvJson.length()) { argvJson.getString(it) } else emptyList()
            val envJson = launch.optJSONObject("env") ?: JSONObject()
            val env = envJson.keys().asSequence().associateWith { envJson.getString(it) }
            return RuntimeManifest(
                runtimeVersion = json.getString("runtimeVersion"),
                abi = json.optString("abi"),
                rootfsAsset = json.getString("rootfs"),
                rootfsBytes = json.optLong("rootfsBytes", -1L),
                rootfsSha256 = json.optString("rootfsSha256").ifEmpty { null },
                uncompressedBytes = json.optLong("uncompressedBytes", -1L),
                dshVersion = json.optString("dshVersion"),
                nodeVersion = json.optString("nodeVersion"),
                launchArgv = argv,
                launchEnv = env,
                raw = json,
            )
        }
    }
}
