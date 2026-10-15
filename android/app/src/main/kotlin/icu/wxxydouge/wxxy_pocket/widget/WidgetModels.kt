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
            WidgetTodayData(
                date = root.optString("date", ""),
                semesterWeek = root.optInt("semesterWeek", 0),
                weekday = root.optInt("weekday", 0),
                hasSchedule = root.optBoolean("hasSchedule", false),
                courses = courses,
                // prefs 缺失（旧版 App 写入的数据）→ 全默认，行为与以前一致
                prefs = WidgetPrefs(
                    theme = pj?.optString("theme", "system") ?: "system",
                    accent = parseHexColor(pj?.optString("accent", "1F2937")),
                    fontScale = (pj?.optDouble("fontScale", 1.0) ?: 1.0).toFloat(),
                    showTeacher = pj?.optBoolean("showTeacher", true) ?: true,
                    showClassroom = pj?.optBoolean("showClassroom", true) ?: true,
                    showTime = pj?.optBoolean("showTime", true) ?: true,
                    showWeek = pj?.optBoolean("showWeek", true) ?: true,
                    countdown = pj?.optBoolean("countdown", true) ?: true,
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
                ),
            )
        } catch (_: Exception) {
            null
        }
    }

    /** 跨天检测：小部件渲染时若今天日期与缓存的 date 不一致，说明是旧数据。 */
    fun isStale(data: WidgetTodayData): Boolean {
        val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.CHINA)
            .format(java.util.Date())
        return data.date != today
    }
}