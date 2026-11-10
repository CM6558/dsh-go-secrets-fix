package io.github.ccch1mneyyy.dsh_app.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class DiagnosticsTailTest {
    @get:Rule
    val dir = TemporaryFolder()

    @Test
    fun missingFileIsEmpty() {
        assertEquals(emptyList<String>(), DiagnosticsPlugin.tail(File(dir.root, "nope.log"), 1024))
    }

    @Test
    fun smallFileComesBackWhole() {
        val file = dir.newFile("dsh.log").apply { writeText("one\ntwo\nthree\n") }
        assertEquals(listOf("one", "two", "three"), DiagnosticsPlugin.tail(file, 1024))
    }

    @Test
    fun cutFirstLineIsDropped() {
        val file = dir.newFile("dsh.log").apply { writeText("first line\nsecond\nthird\n") }
        // The last 12 bytes start inside "second"; 14 start on the newline before it.
        assertEquals(listOf("third"), DiagnosticsPlugin.tail(file, 12))
        assertEquals(listOf("second", "third"), DiagnosticsPlugin.tail(file, 14))
    }

    @Test
    fun multiByteTextSurvives() {
        val file = dir.newFile("dsh.log").apply { writeText("[dsh-app] 已启动\n引擎就绪\n") }
        assertEquals(listOf("[dsh-app] 已启动", "引擎就绪"), DiagnosticsPlugin.tail(file, 4096))
    }
}
