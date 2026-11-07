package icu.wxxydouge.wxxy_pocket.widget

import android.content.Context
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * 今日课表数据模型。
 *
 * Flutter 侧通过 home_widget 插件把「今日课程 JSON」写入其共享存储
 * （`SharedPreferences("HomeWidgetPreferences")`，key：widget_today_courses），
 * 原生小组件直接读取。写入侧见 `lib/services/widget_sync_service.dart`。
 * 读取统一走 [WidgetDataStore.read]，不硬编码文件名。
 */
data class WidgetTodayCourse(
    val name: String,
    val teacher: String,
    val classroom: String,
    val startSlot: Int,
    val endSlot: Int,
    val color: Int,
    val timeText: String,
    val startMinute: Int,   // 当天 0 点起分钟数（如 08:00 → 480）
    val endMinute: Int,     // 结束分钟数
)

data class WidgetTodayData(
    val date: String,          // yyyy-MM-dd，Flutter 侧计算
    val semesterWeek: Int,     // 当前教学周
    val weekday: Int,          // 1=周一 ... 7=周日
    val hasSchedule: Boolean,  // 是否配置了课程表数据
    val courses: List<WidgetTodayCourse>,
    val prefs: WidgetPrefs = WidgetPrefs(),
)

/**
 * 一条「整学期」的课程定义（2026-11-04 新增）。
 *
 * ## 为什么要在小组件里存整学期
 *
 * 以前 Flutter 只下发**今天**要上的课。过了零点，这份 JSON 的 `date`
 * 就过期了，而重算「今天有哪些课」只能靠 Dart —— 全仓没有任何后台入口
 * 能跑 Dart（没注册 WorkManager / backgroundCallback），所以早上第一次
 * 看桌面，小组件永远停在「点击刷新今日课表」，直到用户打开一次 App。
 *
 * 现在把整学期下发给 Kotlin，由 [WidgetDataStore.read] 在发现数据过期时
 * **就地重算**今天的课 —— 判断只需要「教学周 + 星期几 + 周次规则」，这些
 * 全在数据里，不需要联网也不需要 Dart 活着。
 */
data class WidgetCourseDef(
    val name: String,
    val teacher: String,
    val classroom: String,
    val weekday: Int,
    val startSlot: Int,
    val endSlot: Int,
    val color: Int,
    val timeText: String,
    val startMinute: Int,
    val endMinute: Int,
    /** 原始周次文本，如 "1-15周(单)" / "1-3周,6-16周"。空 = 不限。 */
    val weeks: String,
    /** 0 = 每双周都上，1 = 只单周，2 = 只双周。 */
    val weekType: Int,
    /** 0 = 固定星期，1 = 每天，2 = 工作日。 */
    val pattern: Int,
)

/**
 * 小组件个性化设置（2026-10-12 新增）。
 *
 * 由 Flutter 侧（`lib/services/widget_prefs.dart`）写入同步 JSON 的 `prefs`
 * 字段下发。**字段名是 Dart ↔ Kotlin 的约定，改名要两边一起改。**
 * 全部带默认值：旧版本 App 写入的 JSON 没有 prefs 时，行为与以前完全一致。
 */
data class WidgetPrefs(
    val theme: String = "system",             // system | light | dark
    val accent: Int = 0xFF1F2937.toInt(),     // 主题色（暂用于强调，预留）
    val fontScale: Float = 1f,                // 字号档位：0.85 / 1.0 / 1.15
    val showTeacher: Boolean = true,
    val showClassroom: Boolean = true,
    val showTime: Boolean = true,
    val showWeek: Boolean = true,
    val countdown: Boolean = true,
    // 2026-10-30：小号第二行只保留两种机制 —— time（上课时间）/ countdown（倒计时）。
    val smallMode: String = "countdown",
    // v1.6.7：中号 / 大号**各自独立**的显示开关。
    // 此前三种尺寸共用同一组开关 —— 中号关掉「老师」，大号跟着变（用户反馈的 bug）。
    // 旧版 App 下发的 JSON 没有这些字段 → 回落到上面那组全局值（行为不变）。
    val showTeacherMedium: Boolean = true,
    val showClassroomMedium: Boolean = true,
    val showTimeMedium: Boolean = true,
    val showTeacherLarge: Boolean = true,
    val showClassroomLarge: Boolean = true,
    val showTimeLarge: Boolean = true,
) {
    /** 按尺寸取「任课老师」开关（小号走 [showTeacher]）。 */
    fun teacherFor(size: TodayWidgetRenderer.Size): Boolean = when (size) {
        TodayWidgetRenderer.Size.MEDIUM -> showTeacherMedium
        TodayWidgetRenderer.Size.LARGE -> showTeacherLarge
        else -> showTeacher
    }

    /** 按尺寸取「教室」开关。 */
    fun classroomFor(size: TodayWidgetRenderer.Size): Boolean = when (size) {
        TodayWidgetRenderer.Size.MEDIUM -> showClassroomMedium
        TodayWidgetRenderer.Size.LARGE -> showClassroomLarge
        else -> showClassroom
    }

    /** 按尺寸取「上课时间」开关。 */
    fun timeFor(size: TodayWidgetRenderer.Size): Boolean = when (size) {
        TodayWidgetRenderer.Size.MEDIUM -> showTimeMedium
        TodayWidgetRenderer.Size.LARGE -> showTimeLarge
        else -> showTime
    }
    /** 结合系统深浅色，判断最终用浅色还是深色皮肤。 */
    fun useDark(context: Context): Boolean = when (theme) {
        "dark" -> true
        "light" -> false
        else -> (context.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES
    }
}

private fun parseHexColor(hex: String?): Int {
    val h = (hex ?: "").trim().removePrefix("#")
    return try {
        if (h.length == 6) (0xFF000000 or h.toLong(16)).toInt() else 0xFF1F2937.toInt()
    } catch (_: Exception) {
        0xFF1F2937.toInt()
    }
}

object WidgetDataStore {

    private const val KEY = "widget_today_courses"

    /**
     * 读取 Flutter 侧写入的今日课程 JSON。
     *
     * 存储位置由 home_widget 插件决定，这里走插件的 `getData()` 而不是硬编码
     * SharedPreferences 文件名——插件若调整存储实现，本处自动跟随；若签名变更
     * 则编译期报错（而不是运行时静默读不到数据）。
     *
     * 写入由 Dart 侧 `HomeWidget.saveWidgetData` 完成，原生侧不再提供 write。
     */
    fun read(context: Context): WidgetTodayData? {
        val raw = HomeWidgetPlugin.getData(context).getString(KEY, null) ?: return null
        return try {
            val out = parseTodayData(raw)
            if (out != null) {
                WidgetDiagnostics.recordRead(
                    context,
                    hasData = true,
                    date = out.date,
                    count = out.courses.size,
                )
            }
            out
        } catch (e: Exception) {
            // 2026-11-03：解析失败原来是**完全静默**的（只 return null），
            // 于是「JSON 结构不对」和「今天确实没课」在界面上是同一个样子。
            // 现在把真实原因记进自检，用户能在 App 里看到。
            WidgetDiagnostics.recordError(context, "WidgetDataStore.read 解析失败", e)
            null
        }
    }

    /**
     * 把 Flutter 下发的原始 JSON 解析成今日数据（**纯函数，不碰 Context**）。
     *
     * 单独拆出来的理由（2026-11-04）：这条链路是 Dart 写 → Kotlin 读，
     * 跨语言的字段约定一旦漂移（`allCourses` / `semesterStart` / `weeks`），
     * 表现就是「小组件不闪退但没数据」，而这个项目为它返工了三次。
     * 拆成纯函数后可以在 JVM 单测里用 **Dart 侧真实产出的 JSON** 反向验证，
     * 不需要真机、也不需要 App 跑起来。
     */
    internal fun parseTodayData(raw: String): WidgetTodayData? {
        return try {
            val root = JSONObject(raw)
            val courses = mutableListOf<WidgetTodayCourse>()
            val arr = root.optJSONArray("courses") ?: return null
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                courses.add(
                    WidgetTodayCourse(
                        name = o.optString("name", ""),
                        teacher = o.optString("teacher", ""),
                        classroom = o.optString("classroom", ""),
                        startSlot = o.optInt("startSlot", 0),
                        endSlot = o.optInt("endSlot", 0),
                        color = o.optInt("color", 0xFFF8D2D7.toInt()),
                        timeText = o.optString("timeText", ""),
                        startMinute = o.optInt("startMinute", 8 * 60),
                        endMinute = o.optInt("endMinute", 8 * 60 + 45),
                    )
                )
            }
            val pj = root.optJSONObject("prefs")
            val saved = WidgetTodayData(
                date = root.optString("date", ""),
                semesterWeek = root.optInt("semesterWeek", 0),
                weekday = root.optInt("weekday", 0),
                hasSchedule = root.optBoolean("hasSchedule", false),
                courses = courses,
                // prefs 缺失（旧版 App 写入的数据）→ 全默认，行为与以前一致
                prefs = readPrefs(pj),
            )

            // 🔴 2026-11-04 修「跨零点后小组件取不到数据」：
            //    数据里的 date 不是今天就说明这份是**昨天写的**。以前只能
            //    显示「点击刷新今日课表」，因为重算「今天有哪些课」只能靠
            //    Dart，而小组件刷新时 Dart 根本没在跑（全仓没有
            //    backgroundCallback / WorkManager）。现在 Flutter 把整学期
            //    （allCourses）与教学周起点（semesterStart）一起下发，这里
            //    就地算出今天的课 —— 不联网、也不需要 App 被打开过。
            if (!isStale(saved)) return saved
            val defs = mutableListOf<WidgetCourseDef>()
            val allArr = root.optJSONArray("allCourses")
            if (allArr != null) {
                for (i in 0 until allArr.length()) {
                    val o = allArr.optJSONObject(i) ?: continue
                    defs.add(
                        WidgetCourseDef(
                            name = o.optString("name", ""),
                            teacher = o.optString("teacher", ""),
                            classroom = o.optString("classroom", ""),
                            weekday = o.optInt("weekday", 0),
                            startSlot = o.optInt("startSlot", 0),
                            endSlot = o.optInt("endSlot", 0),
                            color = o.optInt("color", 0xFFF8D2D7.toInt()),
                            timeText = o.optString("timeText", ""),
                            startMinute = o.optInt("startMinute", 8 * 60),
                            endMinute = o.optInt("endMinute", 8 * 60 + 45),
                            weeks = o.optString("weeks", ""),
                            weekType = o.optInt("weekType", 0),
                            pattern = o.optInt("pattern", 0),
                        )
                    )
                }
            }
            recomputeToday(saved, defs, root.optString("semesterStart", ""))
        } catch (_: Exception) {
            // 解析失败交由调用方（read）记录到自检，纯函数保持无副作用。
            null
        }
    }

    /** 跨天检测：小部件渲染时若今天日期与缓存的 date 不一致，说明是旧数据。 */
    fun isStale(data: WidgetTodayData): Boolean {
        val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.CHINA)
            .format(java.util.Date())
        return data.date != today
    }

    private fun readPrefs(pj: JSONObject?): WidgetPrefs = WidgetPrefs(
        theme = pj?.optString("theme", "system") ?: "system",
        accent = parseHexColor(pj?.optString("accent", "1F2937")),
        fontScale = (pj?.optDouble("fontScale", 1.0) ?: 1.0).toFloat(),
        showTeacher = pj?.optBoolean("showTeacher", true) ?: true,
        showClassroom = pj?.optBoolean("showClassroom", true) ?: true,
        showTime = pj?.optBoolean("showTime", true) ?: true,
        showWeek = pj?.optBoolean("showWeek", true) ?: true,
        countdown = pj?.optBoolean("countdown", true) ?: true,
        smallMode = pj?.optString(
            "smallMode",
            if (pj?.optBoolean("countdown", true) == true) "countdown" else "time"
        ) ?: "countdown",
        // 新字段缺失时**回落到全局旧值**，老用户的设置不会丢
        showTeacherMedium = pj?.optBoolean(
            "showTeacherMedium", pj.optBoolean("showTeacher", true)
        ) ?: true,
        showClassroomMedium = pj?.optBoolean(
            "showClassroomMedium", pj.optBoolean("showClassroom", true)
        ) ?: true,
        showTimeMedium = pj?.optBoolean(
            "showTimeMedium", pj.optBoolean("showTime", true)
        ) ?: true,
        showTeacherLarge = pj?.optBoolean(
            "showTeacherLarge", pj.optBoolean("showTeacher", true)
        ) ?: true,
        showClassroomLarge = pj?.optBoolean(
            "showClassroomLarge", pj.optBoolean("showClassroom", true)
        ) ?: true,
        showTimeLarge = pj?.optBoolean(
            "showTimeLarge", pj.optBoolean("showTime", true)
        ) ?: true,
    )

    /**
     * 用整学期数据重算「今天有哪些课」。
     *
     * 只要三样东西：教学周起点（推周次）、今天星期几、每门课的周次规则。
     * 没有 `allCourses`（旧版 App 写入）或读不出开学日时**原样返回**，
     * 让上层按「数据过期」处理 —— 不能凭空造一个「今日无课」，
     * 那会把「读不到」伪装成「今天休息」。
     */
    internal fun recomputeToday(
        saved: WidgetTodayData,
        defs: List<WidgetCourseDef>,
        semesterStart: String,
    ): WidgetTodayData {
        if (defs.isEmpty()) return saved
        val startCal = startOfDay(parseYmd(semesterStart)) ?: return saved
        val todayCal = startOfDay(java.util.Date()) ?: return saved

        // 与 Dart 侧 CourseStorage.teachingWeek 同口径：按「日」做差整除 7，
        // 还没开学（负数）算第 1 周。
        val diffDays =
            ((todayCal.timeInMillis - startCal.timeInMillis) / 86_400_000L).toInt()
        val week = if (diffDays < 0) 1 else diffDays / 7 + 1
        // Calendar.DAY_OF_WEEK: 周日=1..周六=7；App 口径 周一=1..周日=7。
        val weekday = ((todayCal.get(java.util.Calendar.DAY_OF_WEEK) + 5) % 7) + 1

        val list = defs
            .filter { d ->
                d.startSlot in 1..12 &&
                    d.endSlot in d.startSlot..12 &&
                    patternMatches(d.pattern, d.weekday, weekday) &&
                    weekMatches(d.weeks, d.weekType, week)
            }
            .sortedBy { it.startSlot }
            .map {
                WidgetTodayCourse(
                    name = it.name,
                    teacher = it.teacher,
                    classroom = it.classroom,
                    startSlot = it.startSlot,
                    endSlot = it.endSlot,
                    color = it.color,
                    timeText = it.timeText,
                    startMinute = it.startMinute,
                    endMinute = it.endMinute,
                )
            }
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.CHINA)
        return saved.copy(
            date = fmt.format(todayCal.time),
            semesterWeek = week,
            weekday = weekday,
            hasSchedule = list.isNotEmpty(),
            courses = list,
        )
    }

    /** 0 固定 / 1 每天 / 2 工作日。 */
    internal fun patternMatches(pattern: Int, courseWeekday: Int, today: Int): Boolean =
        when (pattern) {
            1 -> true
            2 -> today in 1..5
            else -> courseWeekday == today
        }

    /**
     * 周次判定，与 Dart 侧 `parseWeeks` / `normalizeWeeksText` 同一套规则：
     * 先归一化全角括号、`第`、破折号、波浪号，再逐段解析 `起-止(单|双)`。
     *
     * 空文本 = 不限周次；**一段都解析不出时同样按不限处理** —— 与 Dart 侧
     * 「返回 null 表示不限制」保持一致，宁可多显示也别静默丢课。
     */
    internal fun weekMatches(weeks: String, weekType: Int, week: Int): Boolean {
        if (weekType == 1 && week % 2 == 0) return false // 只单周
        if (weekType == 2 && week % 2 == 1) return false // 只双周
        val text = weeks.trim()
        if (text.isEmpty()) return true
        val norm = text
            .replace('（', '(').replace('）', ')')
            .replace("第", "")
            .replace('—', '-').replace('–', '-')
            .replace('～', '-').replace('~', '-')
            .replace('　', ' ')
        val re = Regex("""^(\d+)(?:\s*-\s*(\d+))?\s*周?\s*(?:\((单|双)\))?$""")
        var sawAny = false
        for (part in norm.split(Regex("""[,，;；\s]+"""))) {
            val m = re.find(part.trim()) ?: continue
            sawAny = true
            val start = m.groupValues[1].toIntOrNull() ?: continue
            val end = m.groupValues[2].toIntOrNull() ?: start
            val parity = m.groupValues[3]
            if (week in start..end) {
                if (parity == "单" && week % 2 == 0) continue
                if (parity == "双" && week % 2 == 1) continue
                return true
            }
        }
        return !sawAny
    }

    internal fun parseYmd(text: String): java.util.Date? {
        if (text.length < 10) return null
        return try {
            java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.CHINA).parse(text)
        } catch (_: Exception) {
            null
        }
    }

    internal fun startOfDay(date: java.util.Date?): java.util.Calendar? {
        if (date == null) return null
        return java.util.Calendar.getInstance().apply {
            time = date
            set(java.util.Calendar.HOUR_OF_DAY, 0)
            set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
    }
}