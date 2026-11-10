package io.github.ccch1mneyyy.dsh_app.share

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ShareNamesTest {
    @Test fun safeNameDropsPathsControlsAndLeadingDots() {
        assertEquals("passwd", ShareNames.safeName("../../etc/passwd"))
        assertEquals("a_b_c.txt", ShareNames.safeName("a:b*c.txt"))
        assertEquals("bashrc", ShareNames.safeName(".bashrc"))
        assertEquals("shared", ShareNames.safeName("  "))
        assertEquals(120, ShareNames.safeName("x".repeat(300)).length)
    }

    @Test fun addsAnExtensionOnlyWhenMissing() {
        assertEquals("图片.jpg", ShareNames.withExtension("图片", "jpg"))
        assertEquals("报告.pdf", ShareNames.withExtension("报告.pdf", "png"))
        assertEquals("note.", ShareNames.withExtension("note.", null))
        assertEquals("note..txt", ShareNames.withExtension("note.", "txt"))
        assertEquals("profile.dshgo", ShareNames.withExtension("profile", ShareNames.SHARE_CODE_EXTENSION))
    }

    @Test fun fallbackNamesFollowTheType() {
        assertEquals("图片", ShareNames.fallbackName("image/heic"))
        assertEquals("视频", ShareNames.fallbackName("video/mp4"))
        assertEquals("文本", ShareNames.fallbackName("text/plain"))
        assertEquals("文件", ShareNames.fallbackName(null))
    }

    @Test fun replacesTheExtension() {
        assertEquals("IMG_1.jpg", ShareNames.replaceExtension("IMG_1.HEIC", "jpg"))
        assertEquals("photo.png", ShareNames.replaceExtension("photo", "png"))
    }

    @Test fun uniqueNamesCountUp() {
        val dir = Files.createTempDirectory("share").toFile()
        try {
            assertEquals("a.jpg", ShareNames.unique(dir, "a.jpg").name)
            File(dir, "a.jpg").writeText("1")
            assertEquals("a (2).jpg", ShareNames.unique(dir, "a.jpg").name)
            File(dir, "a (2).jpg").writeText("2")
            assertEquals("a (3).jpg", ShareNames.unique(dir, "a.jpg").name)
            File(dir, "README").writeText("3")
            assertEquals("README (2)", ShareNames.unique(dir, "README").name)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun fitKeepsTheAspectUnderTheLongSide() {
        assertEquals(1080 to 2400, ShareImages.fit(1080, 2400))
        assertEquals(2560 to 1920, ShareImages.fit(4000, 3000))
        assertEquals(1440 to 2560, ShareImages.fit(3000, 5333))
        assertEquals(2560 to 1, ShareImages.fit(30000, 2))
    }

    @Test fun onlyStillImagesAreScaled() {
        assertTrue(ShareImages.scalable("image/jpeg"))
        assertTrue(ShareImages.scalable("image/heic"))
        assertFalse(ShareImages.scalable("image/gif"))
        assertFalse(ShareImages.scalable("image/svg+xml"))
        assertFalse(ShareImages.scalable("application/pdf"))
        assertFalse(ShareImages.scalable(null))
    }
}
