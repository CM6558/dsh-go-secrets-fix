package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class JsonTest {
    @Test fun roundTripsObjectsArraysEscapesAndNumbers() {
        val value = linkedMapOf("line" to "a\n\"b\\c", "values" to listOf(null, true, false, 12L, -3L, 1.25), "nested" to mapOf("中文" to "值"))
        assertEquals(value, Json.parse(Json.write(value)))
    }

    @Test fun invalidSyntaxIsRejected() {
        for (bad in listOf("", "undefined", "[1,]", "{\"a\":}", "{\"a\" 1}", "\"unterminated", "true false", "\"\\q\"")) {
            try {
                Json.parse(bad)
                fail("accepted invalid syntax")
            } catch (_: Json.JsonException) {
            }
        }
    }
}
