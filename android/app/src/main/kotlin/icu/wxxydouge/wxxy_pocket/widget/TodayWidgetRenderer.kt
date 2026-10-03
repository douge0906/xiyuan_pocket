package icu.wxxydouge.wxxy_pocket.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import icu.wxxydouge.wxxy_pocket.MainActivity
import icu.wxxydouge.wxxy_pocket.R

/**
 * 今日课表小组件渲染器（v2.2.14 三尺寸版）。
 *
 * 尺寸档位（按桌面格数，仿掌上徐工）：
 *  - SMALL  2×1：仅显示「下一节课」+ 周次/星期
 *  - MEDIUM 2×2：标题 + 单列课程色块（最多 3 门）
 *  - LARGE  4×2：标题 + 双列课程色块（最多 6 门）
 *
 * 数据由 Flutter 侧通过 home_widget 插件写入其共享存储（key：widget_today_courses），
 * 读取统一见 [WidgetDataStore.read]。
 */
object TodayWidgetRenderer {

    enum class Size { SMALL, MEDIUM, LARGE }

    private const val MAX_MEDIUM = 3
    private const val MAX_LARGE = 6

    fun isWidgetInstalled(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        val classes = listOf(
            SmallWidgetProvider::class.java,
            MediumWidgetProvider::class.java,
            LargeWidgetProvider::class.java,
        )
        return classes.any { c ->
            manager.getAppWidgetIds(ComponentName(context, c)).isNotEmpty()
        }
    }

    /** 更新指定尺寸的所有小部件（provider onUpdate / onEnabled 用）。 */
    fun updateAll(context: Context, size: Size) {
        val manager = AppWidgetManager.getInstance(context)
        val providerClass = when (size) {
            Size.SMALL -> SmallWidgetProvider::class.java
            Size.MEDIUM -> MediumWidgetProvider::class.java
            Size.LARGE -> LargeWidgetProvider::class.java
        }
        val ids = manager.getAppWidgetIds(ComponentName(context, providerClass))
        if (ids.isEmpty()) return
        val data = WidgetDataStore.read(context)
        for (id in ids) {
            manager.updateAppWidget(id, build(context, data, size))
        }
    }

    /** 更新全部三个尺寸的小部件（App 启动 / 数据变更时调用）。 */
    fun updateAll(context: Context) {
        updateAll(context, Size.SMALL)
        updateAll(context, Size.MEDIUM)
        updateAll(context, Size.LARGE)
        // v2.2.14：排下一个精准闹钟（下一节课开始/结束瞬间刷新）
        try {
            WidgetAlarmScheduler.scheduleNext(context)
        } catch (_: Exception) {
            // 精确闹钟不可用（缺权限/被限制）时静默降级，
            // 小组件仍按系统 60 分钟周期性刷新切换
        }
    }

    /** 若桌面上仍有任意小组件，则排下一个精准闹钟（Provider 用）。 */
    fun scheduleAlarmIfAny(context: Context) {
        if (!isWidgetInstalled(context)) return
        try {
            WidgetAlarmScheduler.scheduleNext(context)
        } catch (_: Exception) {
            // 精确闹钟不可用时静默降级
        }
    }

    fun build(context: Context, data: WidgetTodayData?, size: Size): RemoteViews {
        return when (size) {
            Size.SMALL -> buildSmall(context, data)
            Size.MEDIUM -> buildMedium(context, data)
            Size.LARGE -> buildLarge(context, data)
        }
    }

    private fun pendingOpenApp(context: Context): PendingIntent {
        return PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ---------------- SMALL：下一节课 ----------------

    private fun buildSmall(context: Context, data: WidgetTodayData?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_small)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpenApp(context))
        val sub = buildTitle(data)
        views.setTextViewText(R.id.widget_next_sub, sub)

        if (data == null || !data.hasSchedule || data.courses.isEmpty()) {
            views.setTextViewText(R.id.widget_next, "今日无课")
            return views
        }
        if (WidgetDataStore.isStale(data)) {
            views.setTextViewText(R.id.widget_next, "点击刷新今日课表")
            views.setTextViewText(R.id.widget_next_sub, sub)
            return views
        }

        // v2.2.14 精准切换：按当前时间找「下一节还没结束的课」。
        // - 进行中的课 → 显示它（倒计时到结束）；
        // - 下一节未开始 → 显示它；
        // - 今天课全上完 → 显示「今日课程已结束」。
        val next = nextUpcomingCourse(data)
        if (next == null) {
            views.setTextViewText(R.id.widget_next, "今日课程已结束")
            views.setTextViewText(R.id.widget_next_sub, "明天再来看看～")
            return views
        }
        val detail = listOfNotNull(
            next.timeText.ifBlank { null },
            next.classroom.ifBlank { null },
        ).joinToString("  ")
        views.setTextViewText(R.id.widget_next, next.name)
        views.setTextViewText(R.id.widget_next_sub, detail)
        return views
    }

    /** 当前时间之后的「下一节」：进行中的课优先，其次最近未开始的课。 */
    private fun nextUpcomingCourse(data: WidgetTodayData): WidgetTodayCourse? {
        val cal = java.util.Calendar.getInstance()
        val nowMinute = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 +
            cal.get(java.util.Calendar.MINUTE)

        // 1) 进行中的课
        val ongoing = data.courses.firstOrNull { c ->
            nowMinute >= c.startMinute && nowMinute < c.endMinute
        }
        if (ongoing != null) return ongoing

        // 2) 最近的未开始课程
        return data.courses.firstOrNull { c -> c.startMinute > nowMinute }
    }

    // ---------------- MEDIUM：单列列表 ----------------

    private fun buildMedium(context: Context, data: WidgetTodayData?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_medium)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpenApp(context))
        views.setTextViewText(R.id.widget_title, buildTitle(data))

        if (data == null || !data.hasSchedule || data.courses.isEmpty()) {
            views.setViewVisibility(R.id.widget_courses_container, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_more, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "今日无课，好好休息吧")
            return views
        }
        if (WidgetDataStore.isStale(data)) {
            views.setViewVisibility(R.id.widget_courses_container, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_more, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "点击打开 App 刷新今日课表")
            return views
        }

        views.setViewVisibility(R.id.widget_empty, android.view.View.GONE)
        views.setViewVisibility(R.id.widget_courses_container, android.view.View.VISIBLE)
        views.removeAllViews(R.id.widget_courses_container)

        data.courses.take(MAX_MEDIUM).forEach { course ->
            views.addView(
                R.id.widget_courses_container,
                buildCourseItem(context, course.name, course.teacher, course.timeText, course.classroom, course.color)
            )
        }

        val extra = data.courses.size - MAX_MEDIUM
        if (extra > 0) {
            views.setTextViewText(R.id.widget_more, "还有 $extra 门课")
            views.setViewVisibility(R.id.widget_more, android.view.View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_more, android.view.View.GONE)
        }
        return views
    }

    // ---------------- LARGE：双列列表 ----------------

    private fun buildLarge(context: Context, data: WidgetTodayData?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_large)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpenApp(context))
        views.setTextViewText(R.id.widget_title, buildTitle(data))

        if (data == null || !data.hasSchedule || data.courses.isEmpty()) {
            views.setViewVisibility(R.id.widget_columns, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_more, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "今日无课，好好休息吧")
            return views
        }
        if (WidgetDataStore.isStale(data)) {
            views.setViewVisibility(R.id.widget_columns, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_more, android.view.View.GONE)
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "点击打开 App 刷新今日课表")
            return views
        }

        views.setViewVisibility(R.id.widget_empty, android.view.View.GONE)
        views.setViewVisibility(R.id.widget_columns, android.view.View.VISIBLE)
        views.removeAllViews(R.id.widget_left_column)
        views.removeAllViews(R.id.widget_right_column)

        val shown = data.courses.take(MAX_LARGE)
        for ((index, course) in shown.withIndex()) {
            val item = buildCourseItem(context, course.name, course.teacher, course.timeText, course.classroom, course.color)
            val container = if (index % 2 == 0) R.id.widget_left_column else R.id.widget_right_column
            views.addView(container, item)
        }

        val extra = data.courses.size - MAX_LARGE
        if (extra > 0) {
            views.setTextViewText(R.id.widget_more, "还有 $extra 门课，打开 App 查看全部")
            views.setViewVisibility(R.id.widget_more, android.view.View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_more, android.view.View.GONE)
        }
        return views
    }

    // ---------------- 共用 ----------------

    private fun buildCourseItem(
        context: Context,
        name: String,
        teacher: String,
        timeText: String,
        classroom: String,
        color: Int,
    ): RemoteViews {
        val item = RemoteViews(context.packageName, R.layout.widget_course_item)
        // 左侧课程色条（浅色卡，深色文字自适应）
        item.setInt(R.id.item_color_bar, "setBackgroundColor", color)
        item.setTextColor(R.id.item_name, 0xFF1F2937.toInt())
        item.setTextColor(R.id.item_detail, 0xFF667085.toInt())
        val title = if (teacher.isNotEmpty()) "$name · $teacher" else name
        item.setTextViewText(R.id.item_name, title)
        val detail = listOfNotNull(
            timeText.ifBlank { null },
            classroom.ifBlank { null },
        ).joinToString("  ")
        item.setTextViewText(R.id.item_detail, detail)
        return item
    }

    private fun buildTitle(data: WidgetTodayData?): String {
        if (data == null) return "今日课表"
        val weekNames = arrayOf("", "周一", "周二", "周三", "周四", "周五", "周六", "周日")
        val week = if (data.weekday in 1..7) weekNames[data.weekday] else ""
        val weekLabel = if (data.semesterWeek > 0) "第 ${data.semesterWeek} 周" else ""
        return listOfNotNull(week, weekLabel).joinToString(" · ")
    }

    /** 与 Flutter textOnColor 一致：按亮度选择深/浅文字色。 */
    private fun textOnColor(bg: Int): Int {
        val r = (bg shr 16) and 0xFF
        val g = (bg shr 8) and 0xFF
        val b = bg and 0xFF
        val luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        return if (luminance > 0.62) 0xFF1F2937.toInt() else Color.WHITE
    }
}