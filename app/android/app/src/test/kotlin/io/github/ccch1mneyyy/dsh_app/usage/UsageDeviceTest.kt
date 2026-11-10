package io.github.ccch1mneyyy.dsh_app.usage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UsageDeviceTest {
    @Test fun libraryFolderNamesBecomeAndroidAbiNames() {
        assertEquals("arm64-v8a", UsageDevice.abiOf("arm64", listOf("x86_64")))
        assertEquals("armeabi-v7a", UsageDevice.abiOf("arm", emptyList()))
        assertEquals("x86_64", UsageDevice.abiOf("x86_64", listOf("arm64-v8a")))
        assertEquals("x86", UsageDevice.abiOf("x86", emptyList()))
    }

    @Test fun withoutAKnownFolderThePhonesFirstAbi() {
        assertEquals("arm64-v8a", UsageDevice.abiOf(null, listOf("arm64-v8a", "armeabi-v7a")))
        assertEquals("arm64-v8a", UsageDevice.abiOf("mips", listOf("arm64-v8a")))
        assertEquals("", UsageDevice.abiOf(null, emptyList()))
        assertEquals("", UsageDevice.abiOf(null, listOf(" ")))
    }

    @Test fun theMakerInLowerCaseAndNothingElse() {
        assertEquals("vivo", UsageDevice.makerOf("vivo"))
        assertEquals("xiaomi", UsageDevice.makerOf("Xiaomi"))
        assertEquals("huawei", UsageDevice.makerOf(" HUAWEI "))
        assertEquals("hmd global", UsageDevice.makerOf("HMD Global"))
        assertEquals("sony mobile communications inc.", UsageDevice.makerOf("Sony Mobile Communications Inc."))
        assertEquals(32, UsageDevice.makerOf("x".repeat(80)).length)
    }

    @Test fun onlyWhatTheShareHostTakes() {
        // ^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$ (services/share-worker/src/usage.ts), stored in lower case.
        val rule = Regex("^[a-z0-9][a-z0-9 ._-]{0,31}$")
        for (raw in listOf("Asus+", "_Lenovo", "  -OnePlus", "华为", "Nothing (London)", "a".repeat(40) + " b", "", null)) {
            val maker = UsageDevice.makerOf(raw)
            assertTrue("$raw → $maker", rule.matches(maker))
        }
        assertEquals("asus", UsageDevice.makerOf("Asus+"))
        assertEquals("lenovo", UsageDevice.makerOf("_Lenovo"))
        assertEquals("oneplus", UsageDevice.makerOf("  -OnePlus"))
        assertEquals("nothing london", UsageDevice.makerOf("Nothing (London)"))
        assertEquals("unknown", UsageDevice.makerOf("华为"))
        assertEquals("unknown", UsageDevice.makerOf(null))
    }

    @Test fun lowerCaseIgnoresTheDeviceLocale() {
        // Turkish dotless i must not turn "INFINIX" into "ınfınıx".
        val before = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.forLanguageTag("tr-TR"))
            assertEquals("infinix", UsageDevice.makerOf("INFINIX"))
        } finally {
            java.util.Locale.setDefault(before)
        }
    }
}
