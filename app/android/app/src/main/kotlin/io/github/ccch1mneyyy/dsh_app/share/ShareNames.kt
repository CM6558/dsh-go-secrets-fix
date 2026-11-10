package io.github.ccch1mneyyy.dsh_app.share

import java.io.File

/** File names for shared items (pure: unit-tested on the JVM). */
internal object ShareNames {
    /** A share-code file (lib/share_code/share_codec.dart `shareFileExtension`). */
    const val SHARE_CODE_MIME = "application/vnd.dshgo+json"
    const val SHARE_CODE_EXTENSION = "dshgo"

    private val unsafe = Regex("[\\u0000-\\u001f\\\\:*?\"<>|]")

    /** A file name without path separators or control characters, at most 120 chars. */
    fun safeName(name: String): String {
        val cleaned = name.substringAfterLast('/').replace(unsafe, "_").trim().trimStart('.')
        return cleaned.ifEmpty { "shared" }.take(120)
    }

    /** What to call an item whose sender gave no name. */
    fun fallbackName(
        mime: String?,
        file: String = "文件", // l10n:keep test default
        image: String = "图片", // l10n:keep test default
        video: String = "视频", // l10n:keep test default
        audio: String = "音频", // l10n:keep test default
        text: String = "文本", // l10n:keep test default
    ): String = when {
        mime == null -> file
        mime.startsWith("image/") -> image
        mime.startsWith("video/") -> video
        mime.startsWith("audio/") -> audio
        mime.startsWith("text/") -> text
        else -> file
    }

    /** [name] with `.extension` added when it has none. */
    fun withExtension(name: String, extension: String?): String {
        if (extension.isNullOrEmpty() || hasExtension(name)) return name
        return "$name.$extension"
    }

    fun hasExtension(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        return dot > 0 && dot < name.length - 1
    }

    /** [name], or `name (2).ext`, `name (3).ext`… when [dir] already has it. */
    fun unique(dir: File, name: String): File {
        var file = File(dir, name)
        if (!file.exists()) return file
        val dot = name.lastIndexOf('.')
        val (base, ext) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
        var n = 2
        while (file.exists()) file = File(dir, "$base ($n)$ext").also { n++ }
        return file
    }

    /** [name] with its extension swapped for [extension] (`IMG_1.HEIC` → `IMG_1.jpg`). */
    fun replaceExtension(name: String, extension: String): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        return "$base.$extension"
    }
}
