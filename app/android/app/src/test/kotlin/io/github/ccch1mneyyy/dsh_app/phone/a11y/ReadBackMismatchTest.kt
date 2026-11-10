package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.phone.TargetInfo
import org.junit.Assert.*
import org.junit.Test

/**
 * A `type` whose read-back differs (the field cut or filtered what was typed): the result goes to
 * the model, so a password or code field never says what it holds, while an ordinary one keeps
 * its diagnostic.
 */
class ReadBackMismatchTest {
    /** The single input of a screen, as the driver hands it to the core and the gate. */
    private fun field(hint: String? = null, viewId: String? = null, password: Boolean = false): TargetInfo {
        val bounds = Box(0, 0, 400, 800)
        val node = UiNode(className = "android.widget.EditText", hint = hint, viewId = viewId,
            bounds = Box(0, 100, 300, 150), editable = true, password = password)
        val screen = ScreenFormat.format(ScreenInput("s1", "Example", "example.app", 400, 800, false,
            listOf(UiWindow(1, WindowKind.APP, "example.app", null, bounds, UiNode(bounds = bounds, children = listOf(node))))))
        val e = screen.elements.single()
        return TargetInfo("s1", e.id, e.role, e.label, e.packageName, "Example", e.password, e.secret, e.editable, e.viewId)
    }

    @Test fun aCodeOrPasswordFieldNeverSaysWhatItHolds() {
        for (target in listOf(field(hint = "验证码"), field(hint = "请输入短信校验码"), field(viewId = "app:id/et_pwd"), field(hint = "密码", password = true))) {
            val message = MainScreenDriver.readBackMismatch("13579", target)
            assertFalse(message, message.any(Char::isDigit))
            assertTrue(message, message.startsWith("已输入，但回读不一致"))
            assertTrue(message, message.contains("没有重试，也没有提交"))
        }
    }

    @Test fun anOrdinaryFieldStillSaysWhatItHolds() {
        val nickname = field(hint = "昵称")
        assertEquals(
            "已输入，但回读不一致：框里现在是「小明 123456」。没有重试，也没有提交；请看新屏幕决定下一步。",
            MainScreenDriver.readBackMismatch("小明 123456", nickname),
        )
        assertTrue(MainScreenDriver.readBackMismatch(null, nickname).contains("框里现在是空"))
        assertTrue(MainScreenDriver.readBackMismatch("4111 1111 1111 1111", nickname).contains("«银行卡 ****1111»"))
    }
}
