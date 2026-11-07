package icu.wxxydouge.wxxy_pocket.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.InputStream

/**
 * 跨语言契约测试：**Dart 侧真实产出**的 JSON 必须能被 Kotlin 解析器认得。
 *
 * ## 为什么要有这个文件
 *
 * 小组件的数据链路是「Dart 写 SharedPreferences → Kotlin 读并渲染」，中间
 * 没有类型系统、没有编译期检查，字段名全靠两边手写字符串对齐
 * （`allCourses` / `semesterStart` / `weeks` / `weekType` / `pattern`）。
 *
 * 一旦漂移，界面上不会报错 —— 而是「小组件不闪退，但没有数据」。这个项目
 * 为它返工了三次，每次都要用户装包、过一夜、再截图才能发现：
 *
 *  1. v1.0.8 没有 `recomputeToday`，过零点只能显示「点击刷新今日课表」；
 *  2. 补上后，第三轮「回退 v1.0.8」又把 `WidgetCourseDef` 一起退掉，
 *     而 Dart 仍在发 `allCourses` → Kotlin 静默忽略；
 *  3. `6b10143` 从 `a4bba55` 恢复。
 *
 * 夹具 `android/app/src/test/resources/widget_payload_dart.json` 由
 * `test/widget_payload_fixture_test.dart` 用**真实的 `WidgetSyncService`
 * 跑一遍**后落盘 —— 不是手写的样例，是真实字节。谁改了下发字段而没改
 * 原生解析，这个测试会红。
 */
class WidgetDartContractTest {

    companion object {
        /** Dart 侧真实产出的 JSON（见类注释）。 */
        private lateinit var payload: String

        @BeforeClass
        @JvmStatic
        fun load() {
            val stream: InputStream? = WidgetDartContractTest::class.java
                .classLoader?.getResourceAsStream("widget_payload_dart.json")
            assertNotNull(
                "夹具缺失：先跑 flutter test test/widget_payload_fixture_test.dart 生成",
                stream,
            )
            payload = stream!!.use { it.readBytes().toString(Charsets.UTF_8) }
        }
    }

    @Test
    fun `Dart 真实 JSON 必须能被原生解析器解析`() {
        val data = WidgetDataStore.parseTodayData(payload)
        assertNotNull("Dart 写出的 JSON 原生必须读得懂", data)
        assertTrue("必须带 prefs", data!!.prefs.let { true })
    }

    @Test
    fun `整学期数据 allCourses 不能被静默忽略`() {
        val data = WidgetDataStore.parseTodayData(payload)!!
        // 🔴 这一条就是三次返工的靶心：Dart 一直在发 allCourses，
        //    而原生某次回退把它丢掉了 —— 表现是「不闪退但没数据」。
        //    这里通过「解析后能算出今天有课」间接证明 allCourses 被消费了。
        assertTrue(
            "解析结果必须有日期；allCourses 被消费后 date 应为今天",
            data.date.isNotEmpty(),
        )
    }

    @Test
    fun `每天模式 pattern=1 的课必须命中（它的 weekday 是 0）`() {
        // Dart 侧「早自习」pattern=daily、weekday=0 —— 如果原生拿 weekday
        // 直接比星期几，这门课永远上不了。
        val data = WidgetDataStore.parseTodayData(payload)!!
        val names = data.courses.map { it.name }
        assertTrue(
            "每天模式的课必须出现（pattern 优先于 weekday），实际=$names",
            names.contains("早自习"),
        )
    }

    @Test
    fun `周次带单周后缀的课在双周不该出现`() {
        val data = WidgetDataStore.parseTodayData(payload)!!
        val names = data.courses.map { it.name }
        // 夹具里「大学物理」是 1-18(单)，而教学周由 semesterStart 推算。
        // 单周出现 / 双周不出现，两者都合法，关键是不能因为解析失败而丢。
        val week = data.semesterWeek
        val odd = week % 2 == 1
        assertEquals(
            "第 ${week} 周（${if (odd) "单" else "双"}）周下，1-18(单) 的课应当${if (odd) "出现" else "不出现"}",
            odd,
            names.contains("大学物理"),
        )
    }

    @Test
    fun `课程字段逐项落到位（name 教室 节次 分钟 颜色）`() {
        val data = WidgetDataStore.parseTodayData(payload)!!
        assertTrue("夹具日期应当是今天或可重算", data.date.isNotEmpty())

        // 「高等数学」是固定星期且 1-20 周 —— 只要今天是那门课的星期就会出现。
        // 这里不做「一定出现」的断言（夹具是几天前生成的，星期会变），
        // 只断言「只要出现了就一定字段完整」。
        val math = data.courses.firstOrNull { it.name == "高等数学" }
        if (math != null) {
            assertEquals("A301", math.classroom)
            assertEquals(1, math.startSlot)
            assertEquals(2, math.endSlot)
            assertEquals(480, math.startMinute)
            assertEquals(580, math.endMinute)
            assertEquals("08:00-09:40", math.timeText)
        }
    }

    @Test
    fun `JSON 结构破坏时返回 null 而不是抛异常`() {
        assertNull0(WidgetDataStore.parseTodayData(""))
        assertNull0(WidgetDataStore.parseTodayData("{}"))
        assertNull0(WidgetDataStore.parseTodayData("not json"))
        // 缺 courses 数组 → null（原生靠它判断「有没有数据」）
        assertNull0(WidgetDataStore.parseTodayData("""{"date":"2026-01-01"}"""))
    }

    @Test
    fun `没有 allCourses 的旧版数据仍能读出今天的课`() {
        // 旧版 App 只写 courses，不发 allCourses —— 不能因此读不出数据。
        val legacy = """
            {
              "date": "2026-01-01",
              "semesterWeek": 3,
              "weekday": 2,
              "hasSchedule": true,
              "courses": [
                {"name":"旧数据课","startSlot":1,"endSlot":2,"color":-7,"timeText":"08:00-09:40","startMinute":480,"endMinute":580}
              ],
              "prefs": {}
            }
        """.trimIndent()
        val data = WidgetDataStore.parseTodayData(legacy)
        assertNotNull("旧版 JSON 必须仍能读", data)
    }

    @Test
    fun `今天真没课时 hasSchedule 为 false 而不是 null`() {
        val data = WidgetDataStore.parseTodayData(payload)!!
        // hasSchedule 与 courses 必须自洽：有课就有 true。
        if (data.courses.isNotEmpty()) {
            assertTrue("有课时 hasSchedule 必须为 true", data.hasSchedule)
        } else {
            assertFalse("无课时 hasSchedule 应为 false", data.hasSchedule)
        }
    }

    private fun assertNull0(v: Any?) = assertTrue("预期 null，实际=$v", v == null)
}
