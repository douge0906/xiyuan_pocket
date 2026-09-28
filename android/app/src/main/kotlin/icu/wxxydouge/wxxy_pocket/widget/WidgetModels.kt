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
)

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
            WidgetTodayData(
                date = root.optString("date", ""),
                semesterWeek = root.optInt("semesterWeek", 0),
                weekday = root.optInt("weekday", 0),
                hasSchedule = root.optBoolean("hasSchedule", false),
                courses = courses,
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