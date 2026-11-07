package icu.wxxydouge.wxxy_pocket.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/**
 * 小组件「跨零点算不出今天的课」回归（用户 m20950 #5）。
 *
 * 用户原话：「小组件不闪退 但是无数据。」
 *
 * 这个 bug 修过三次：
 *  1. v1.0.8 根本没有 `recomputeToday`，过零点只能显示「点击刷新今日课表」；
 *  2. 第二次补了 `allCourses` + `recomputeToday`，第三轮「回退 v1.0.8」又把
 *     它一起退掉了 —— Dart 一直在发 `allCourses`，Kotlin 不再消费；
 *  3. 第三次（`6b10143`）从 `a4bba55` 恢复。
 *
 * 前两次都要**装包 → 过一夜 → 用户截图**才能发现，代价是一整天。而
 * `recomputeToday` 本身是纯 java.util 逻辑（周次减法 + 周次/单双周匹配 +
 * 星期几换算法），完全能在 JVM 里跑 —— 所以这里把它钉死。
 *
 * 注意：本文件跑的是 JVM 单测（`./gradlew testDebugUnitTest`），不打真机。
 * 它测不了「系统真的渲染了桌面」，但能证明「拿到整学期数据后算得出今天的课」。
 */
class WidgetRecomputeTodayTest {

    // 全部字段都有默认值 —— 这里不重复列举，避免和 data class 的默认值漂移
    private fun prefs() = WidgetPrefs()

    /** 昨天写的旧数据：date 已过期，这正是小组件读到的「stale」状态。 */
    private fun staleSaved(courses: List<WidgetTodayCourse> = emptyList()) = WidgetTodayData(
        date = "2020-01-01",
        semesterWeek = 99,
        weekday = 7,
        hasSchedule = true,
        courses = courses,
        prefs = prefs(),
    )

    private fun def(
        name: String,
        weekday: Int,
        weeks: String = "",
        weekType: Int = 0,
        pattern: Int = 0,
        startSlot: Int = 1,
        endSlot: Int = 2,
    ) = WidgetCourseDef(
        name = name,
        teacher = "",
        classroom = "",
        weekday = weekday,
        startSlot = startSlot,
        endSlot = endSlot,
        color = 0xFFF8D2D7.toInt(),
        timeText = "08:00-09:40",
        startMinute = 480,
        endMinute = 580,
        weeks = weeks,
        weekType = weekType,
        pattern = pattern,
    )

    /** 今天（用与实现同一套 Calendar 口径取，只用于构造期望值）。 */
    private fun todayWeekday(): Int {
        val cal = Calendar.getInstance().apply {
            time = java.util.Date()
        }
        return ((cal.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1
    }

    private fun todayYmd(): String {
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.CHINA)
        return fmt.format(java.util.Date())
    }

    /** 以今天为基准往前推 n 周的那一天（作为教学周起点）。 */
    private fun weeksAgo(n: Int): String {
        val cal = Calendar.getInstance().apply {
            time = java.util.Date()
            add(Calendar.DAY_OF_YEAR, -7 * n)
        }
        return java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.CHINA)
            .format(cal.time)
    }

    // ------------------------------------------------------------------ 核心

    @Test
    fun `旧数据 + 整学期数据 会重算出今天的课并把 date 换成今天`() {
        val defs = listOf(def("今天这门课", todayWeekday()))
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, weeksAgo(3))

        // 🔴 这一行是 bug 的靶心：修复前直接 return saved，date 还是 2020-01-01
        assertEquals(todayYmd(), out.date)
        assertTrue(out.hasSchedule)
        assertEquals(1, out.courses.size)
        assertEquals("今天这门课", out.courses[0].name)
        // 周次也要跟着重算（3 周前开学 → 第 4 周）
        assertEquals(4, out.semesterWeek)
        assertEquals(todayWeekday(), out.weekday)
    }

    @Test
    fun `不是今天的课不会被算进来（说明真的重算了，不是原样返回）`() {
        val yesterday = (todayWeekday() - 2 + 7) % 7 + 1
        val defs = listOf(def("别的天的课", yesterday))
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, weeksAgo(3))

        assertEquals(todayYmd(), out.date) // 日期仍被刷新
        assertFalse(out.hasSchedule)
        assertTrue(out.courses.isEmpty())
    }

    @Test
    fun `每一天各一门时只挑中今天那门`() {
        val defs = (1..7).map { def("wd$it", it) }
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, weeksAgo(1))

        assertEquals(1, out.courses.size)
        assertEquals("wd${out.weekday}", out.courses[0].name)
    }

    @Test
    fun `没有整学期数据时原样返回，不伪造今天没课`() {
        val saved = staleSaved()
        val out = WidgetDataStore.recomputeToday(saved, emptyList(), weeksAgo(3))
        // 关键：不能把「读不到」伪装成「今天休息」
        assertEquals("2020-01-01", out.date)
        assertEquals(99, out.semesterWeek)
    }

    @Test
    fun `开学日读不出来时原样返回`() {
        val defs = listOf(def("今天这门课", todayWeekday()))
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, "")
        assertEquals("2020-01-01", out.date)
    }

    @Test
    fun `本学期之外的课被周次规则滤掉`() {
        // 3 周前开学 = 第 4 周；这门课只在第 1 周上
        val defs = listOf(def("只在第1周", todayWeekday(), weeks = "1-1"))
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, weeksAgo(3))
        assertTrue(out.courses.isEmpty())
    }

    @Test
    fun `单双周规则生效`() {
        val week = 4 // 偶数周
        val odd = listOf(def("单周课", todayWeekday(), weeks = "1-18", weekType = 1))
        val even = listOf(def("双周课", todayWeekday(), weeks = "1-18", weekType = 2))
        val start = weeksAgo(week - 1)
        assertTrue(WidgetDataStore.recomputeToday(staleSaved(), odd, start).courses.isEmpty())
        assertEquals(1, WidgetDataStore.recomputeToday(staleSaved(), even, start).courses.size)
    }

    @Test
    fun `每天与工作日模式按 pattern 而不是 weekday 命中`() {
        val today = todayWeekday()
        val daily = listOf(def("每天", 0, pattern = 1))
        assertEquals(1, WidgetDataStore.recomputeToday(staleSaved(), daily, weeksAgo(1)).courses.size)

        val workday = listOf(def("工作日", -1, pattern = 2))
        val out = WidgetDataStore.recomputeToday(staleSaved(), workday, weeksAgo(1))
        assertEquals(today in 1..5, out.courses.isNotEmpty())
    }

    @Test
    fun `越界节次的脏数据不会进来`() {
        val defs = listOf(
            def("开始0", todayWeekday(), startSlot = 0),
            def("结束13", todayWeekday(), startSlot = 12, endSlot = 13),
            def("倒挂", todayWeekday(), startSlot = 5, endSlot = 3),
            def("正常", todayWeekday(), startSlot = 3, endSlot = 4),
        )
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, weeksAgo(1))
        assertEquals(1, out.courses.size)
        assertEquals("正常", out.courses[0].name)
    }

    @Test
    fun `多门课按开始节次排序`() {
        val defs = listOf(
            def("第三节", todayWeekday(), startSlot = 3, endSlot = 4),
            def("第一节", todayWeekday(), startSlot = 1, endSlot = 2),
            def("第五节", todayWeekday(), startSlot = 5, endSlot = 6),
        )
        val out = WidgetDataStore.recomputeToday(staleSaved(), defs, weeksAgo(1))
        assertEquals(listOf("第一节", "第三节", "第五节"), out.courses.map { it.name })
    }

    // ------------------------------------------------------- 周次文本归一化

    @Test
    fun `周次写法全角半角破折号都能认`() {
        val ok = listOf("1-18", "1—18", "1–18", "1～18", "1~18", "第1-18周", "1-18周")
        for (text in ok) {
            assertTrue("应命中: $text", WidgetDataStore.weekMatches(text, 0, 10))
            assertFalse("不该命中: $text", WidgetDataStore.weekMatches(text, 0, 20))
        }
    }

    @Test
    fun `周次里的单双周括号`() {
        assertTrue(WidgetDataStore.weekMatches("1-18(单)", 0, 9))
        assertFalse(WidgetDataStore.weekMatches("1-18(单)", 0, 10))
        assertTrue(WidgetDataStore.weekMatches("1-18（双）", 0, 10))
        assertFalse(WidgetDataStore.weekMatches("1-18（双）", 0, 9))
    }

    @Test
    fun `多段周次与逗号分隔`() {
        assertTrue(WidgetDataStore.weekMatches("1-5,10-15", 0, 12))
        assertFalse(WidgetDataStore.weekMatches("1-5,10-15", 0, 7))
        assertTrue(WidgetDataStore.weekMatches("1-5，10-15", 0, 3)) // 全角逗号
    }

    @Test
    fun `空周次和解析不出的乱码都当不限（宁可多显示也别静默丢课）`() {
        assertTrue(WidgetDataStore.weekMatches("", 0, 3))
        assertTrue(WidgetDataStore.weekMatches("   ", 0, 3))
        assertTrue(WidgetDataStore.weekMatches("乱码", 0, 3))
    }

    @Test
    fun `单双周字段优先于文本`() {
        assertFalse(WidgetDataStore.weekMatches("1-18", 1, 4)) // 只单周，第 4 周
        assertTrue(WidgetDataStore.weekMatches("1-18", 1, 5))
        assertFalse(WidgetDataStore.weekMatches("1-18", 2, 5)) // 只双周，第 5 周
        assertTrue(WidgetDataStore.weekMatches("1-18", 2, 6))
    }
}
