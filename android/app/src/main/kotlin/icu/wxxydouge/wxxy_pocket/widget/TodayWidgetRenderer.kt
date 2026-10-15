package icu.wxxydouge.wxxy_pocket.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import icu.wxxydouge.wxxy_pocket.MainActivity
import icu.wxxydouge.wxxy_pocket.R

/**
 * 今日课表小组件渲染器（2026-10-12 加个性化设置版）。
 *
 * 尺寸档位：
 *  - SMALL  2×1：三行 —— 课程名 / 时间 / 教室（可开关倒计时）
 *  - MEDIUM 2×2：标题 + 单行课程条目（条数按真实高度算）
 *  - LARGE  4×2：标题 + 三列单行条目（**最多 4 门**）
 *
 * 个性化设置由 Flutter 侧经同步 JSON 的 `prefs` 字段下发（见 Dart 的
 * WidgetPrefs / 本包的 WidgetModels.WidgetPrefs），本文件负责落地：
 * 深浅色皮肤、主题色、字号档位、显示内容开关、倒计时开关。
 *
 * 数据读取统一见 [WidgetDataStore.read]。
 */
object TodayWidgetRenderer {

    enum class Size { SMALL, MEDIUM, LARGE }

    /// 大号最多显示几门（用户要求：只要 4 门）。
    private const val MAX_LARGE = 4

    /// 各尺寸在拿不到真实高度时的兜底值（dp，与 *_info.xml 的 minHeight 对齐）。
    private fun defaultHeightDp(size: Size): Int = when (size) {
        Size.SMALL -> 60
        Size.MEDIUM -> 110
        Size.LARGE -> 110
    }

    // 卡片内边距（上下各 12dp）、标题行（13~14sp + 与列表的间距）、
    // 「还有 N 门」那一行的高度 —— 都按 dp 估，用于算「放得下几门」。
    private const val CARD_PAD_V = 24
    private const val TITLE_BLOCK = 23
    private const val MORE_BLOCK = 14

    /// 条目样式：布局 + 高度（含内边距）+ 间距。
    ///
    /// 两个尺寸统一用**单行条目**（21dp）。为什么不用两行的：
    /// 4×2 的高度（110dp）扣掉内边距与标题只剩约 63dp，
    /// 两行条目（34dp）一列只放得下 1 门 → 3 列也才 3 门，大块地方空着。
    /// 单行条目 21dp 一列能放 2 门 → 3 列最多 6 门（本档限 4 门）。
    private data class ItemStyle(
        val layoutId: Int,
        val heightDp: Int,
        val gapDp: Int,
        /// 是否三行条目（课程名 / 时间 / 教室 各占一行，v1.6.7）。
        val isTriple: Boolean = false,
    )

    private val SLIM = ItemStyle(R.layout.widget_course_item_slim, 21, 4)

    /// 平分条目（v1.6.4）：root 用 height=0 + weight=1 —— 让同一容器里的
    /// 多门课**平分**可用高度。
    private val EVEN = ItemStyle(R.layout.widget_course_item_even, 0, 0)

    /// 三行平分条目（v1.6.7）：中号 / 大号用它 —— **课程名 / 上课时间 / 教室**
    /// 一行一件事（此前挤在一行、信息被截断，用户反馈设计有误）。
    private val TRIPLE = ItemStyle(R.layout.widget_course_item_triple, 0, 0, isTriple = true)

    // ---------------- 颜色（浅色 / 深色两套皮肤）----------------

    private fun ink(dark: Boolean) = if (dark) 0xFFF3F4F6.toInt() else 0xFF1F2937.toInt()
    private fun subText(dark: Boolean) = if (dark) 0xFF9CA3AF.toInt() else 0xFF667085.toInt()
    private fun moreText(dark: Boolean) = if (dark) 0xFF6B7280.toInt() else 0xFF98A2B3.toInt()
    private fun cardBg(dark: Boolean) =
        if (dark) R.drawable.widget_card_bg_dark else R.drawable.widget_card_bg_light
    private fun itemBg(dark: Boolean) =
        if (dark) R.drawable.widget_course_item_bg_dark else R.drawable.widget_course_item_bg

    private fun prefsOf(data: WidgetTodayData?) = data?.prefs ?: WidgetPrefs()

    /// 图标着色：深色皮肤下把过暗的主题色提亮，保证可见。
    private fun iconTint(prefs: WidgetPrefs, dark: Boolean): Int {
        val c = prefs.accent
        val r = (c shr 16) and 0xFF
        val g = (c shr 8) and 0xFF
        val b = c and 0xFF
        val lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        return if (dark && lum < 0.5) 0xFFE5E7EB.toInt() else c
    }

    /// 桌面上有几种尺寸的小组件 + 是否装了任意一个。
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
            // 拿真实高度来渲染 —— 桌面格子多高就放几门课。
            // 以前写死条数，格子矮的时候后面的课程会被裁掉（用户反馈过），
            // 现在按高度算，放不下就显示「还有 N 门」，永不遮盖。
            val heightDp = try {
                manager.getAppWidgetOptions(id)
                    .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, defaultHeightDp(size))
            } catch (_: Exception) {
                defaultHeightDp(size)
            }
            manager.updateAppWidget(id, build(context, data, size, heightDp))
        }
    }

    /** 更新全部三个尺寸的小部件（App 启动 / 数据变更时调用）。 */
    fun updateAll(context: Context) {
        updateAll(context, Size.SMALL)
        updateAll(context, Size.MEDIUM)
        updateAll(context, Size.LARGE)
        try {
            WidgetAlarmScheduler.scheduleNext(context)
        } catch (_: Exception) {
            // 精确闹钟不可用（缺权限/被限制）时静默降级
        }
    }

    /** 若桌面上仍有任意小组件，则排下一个精准闹钟（Provider 用）。 */
    fun scheduleAlarmIfAny(context: Context) {
        if (!isWidgetInstalled(context)) return
        try {
            WidgetAlarmScheduler.scheduleNext(context)
        } catch (_: Exception) {
            // 静默降级
        }
    }

    fun build(context: Context, data: WidgetTodayData?, size: Size, heightDp: Int): RemoteViews {
        return when (size) {
            Size.SMALL -> buildSmall(context, data)
            Size.MEDIUM -> buildMedium(context, data, heightDp)
            Size.LARGE -> buildLarge(context, data, heightDp)
        }
    }

    /// 点击小组件 → **直达课表页**（2026-10-12）。
    ///
    /// 走 home_widget 的 launch intent：Dart 侧用
    /// `HomeWidget.initiallyLaunchedFromHomeWidget()` / `widgetClicked` 拿到
    /// 这个 URI，再导航到课表页。以前是打开 App 首页，用户还得自己点进去。
    private fun pendingOpenApp(context: Context): PendingIntent {
        return HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.parse("homewidget://course"),
        )
    }

    // ---------------- 皮肤 / 字号 / 显示开关 ----------------

    /// 卡片底 + 标题/正文颜色 + 主题色图标，一次性套上。
    private fun applySkin(views: RemoteViews, dark: Boolean) {
        views.setInt(R.id.widget_root, "setBackgroundResource", cardBg(dark))
    }

    private fun scaled(prefs: WidgetPrefs, base: Float): Float = base * prefs.fontScale

    private fun setSize(views: RemoteViews, id: Int, sp: Float) {
        views.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, sp)
    }

    /// 「还有多久」文案（倒计时开关打开时才用）。
    private fun countdownText(course: WidgetTodayCourse, now: Int, ongoing: Boolean): String {
        val mins = if (ongoing) course.endMinute - now else course.startMinute - now
        if (mins <= 0) return ""
        return when {
            mins >= 60 -> {
                val h = mins / 60
                val m = mins % 60
                if (m == 0) "还有 $h 小时" + (if (ongoing) "下课" else "上课")
                else "还有 $h 小时 $m 分"
            }
            else -> "还有 $mins 分钟" + (if (ongoing) "下课" else "上课")
        }
    }

    // ---------------- SMALL：下一节课（三行）----------------

    private fun buildSmall(context: Context, data: WidgetTodayData?): RemoteViews {
        val prefs = prefsOf(data)
        val dark = prefs.useDark(context)
        val views = RemoteViews(context.packageName, R.layout.widget_small)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpenApp(context))
        applySkin(views, dark)

        val weekTitle = if (prefs.showWeek) buildTitle(data) else ""
        val inkC = ink(dark)
        val subC = subText(dark)

        views.setTextColor(R.id.widget_next, inkC)
        views.setTextColor(R.id.widget_next_time, subC)
        views.setTextColor(R.id.widget_next_place, subC)
        // 2026-10-13：主题色落地 —— 设置页选的主题色此前下发后从未被消费
        //（属「假设置」）。现在给左上角图标着色，选了就看得见。
        // 深色皮肤下要提亮：默认主题色是墨黑（#1F2937），落在深色卡片（#1E1E1E）
        // 上几乎看不见；用户选的彩色（蓝/绿/紫…）亮度够就保持原样。
        views.setInt(R.id.widget_icon, "setColorFilter", iconTint(prefs, dark))
        setSize(views, R.id.widget_next, scaled(prefs, 13f))
        setSize(views, R.id.widget_next_time, scaled(prefs, 10f))
        setSize(views, R.id.widget_next_place, scaled(prefs, 10f))

        if (data == null || !data.hasSchedule || data.courses.isEmpty()) {
            views.setTextViewText(R.id.widget_next, "今日无课")
            views.setTextViewText(R.id.widget_next_time, weekTitle)
            views.setViewVisibility(R.id.widget_next_place, View.GONE)
            return views
        }
        if (WidgetDataStore.isStale(data)) {
            views.setTextViewText(R.id.widget_next, "点击刷新今日课表")
            views.setTextViewText(R.id.widget_next_time, weekTitle)
            views.setViewVisibility(R.id.widget_next_place, View.GONE)
            return views
        }

        val next = nextUpcomingCourse(data)
        if (next == null) {
            views.setTextViewText(R.id.widget_next, "今日课程已结束")
            views.setTextViewText(R.id.widget_next_time, "明天再来看看～")
            views.setViewVisibility(R.id.widget_next_place, View.GONE)
            return views
        }

        // 三行：课程名 / 时间 / 教室。
        // 倒计时开关打开时，第二行显示「还有 X 分钟上课（下课）」，
        // 没有教室时第三行留空并隐藏，不留一条空行。
        views.setTextViewText(R.id.widget_next, next.name)

        val now = nowMinute()
        val ongoing = now >= next.startMinute && now < next.endMinute
        val cd = if (prefs.countdown) countdownText(next, now, ongoing) else ""
        val line2 = when {
            cd.isNotEmpty() -> cd
            prefs.showTime && next.timeText.isNotBlank() -> next.timeText
            else -> weekTitle
        }
        views.setTextViewText(R.id.widget_next_time, line2)

        if (prefs.showClassroom && next.classroom.isNotBlank()) {
            views.setViewVisibility(R.id.widget_next_place, View.VISIBLE)
            views.setTextViewText(R.id.widget_next_place, next.classroom)
        } else {
            views.setViewVisibility(R.id.widget_next_place, View.GONE)
        }
        return views
    }

    /** 当前时间之后的「下一节」：进行中的课优先，其次最近未开始的课。 */
    private fun nextUpcomingCourse(data: WidgetTodayData): WidgetTodayCourse? {
        val now = nowMinute()
        val ongoing = data.courses.firstOrNull { c -> now >= c.startMinute && now < c.endMinute }
        if (ongoing != null) return ongoing
        return data.courses.firstOrNull { c -> c.startMinute > now }
    }

    // ---------------- MEDIUM：单列列表 ----------------

    private fun buildMedium(context: Context, data: WidgetTodayData?, heightDp: Int): RemoteViews {
        val prefs = prefsOf(data)
        val dark = prefs.useDark(context)
        val views = RemoteViews(context.packageName, R.layout.widget_medium)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpenApp(context))
        applySkin(views, dark)
        views.setTextColor(R.id.widget_title, ink(dark))
        views.setTextColor(R.id.widget_more, moreText(dark))
        views.setTextColor(R.id.widget_empty, subText(dark))
        setSize(views, R.id.widget_title, scaled(prefs, 13f))
        setSize(views, R.id.widget_more, scaled(prefs, 10f))
        setSize(views, R.id.widget_empty, scaled(prefs, 12f))
        // v1.6.8：中号标题也**不带教学周次**（与上一版的大号一致）
        views.setTextViewText(R.id.widget_title, titleNoWeek(data))

        if (data == null || !data.hasSchedule || data.courses.isEmpty()) {
            views.setViewVisibility(R.id.widget_courses_container, View.GONE)
            views.setViewVisibility(R.id.widget_more, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "今日无课，好好休息吧")
            return views
        }
        if (WidgetDataStore.isStale(data)) {
            views.setViewVisibility(R.id.widget_courses_container, View.GONE)
            views.setViewVisibility(R.id.widget_more, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "点击打开 App 刷新今日课表")
            return views
        }

        // 只放「还没上完」的课：上完一门就从列表消失，后面的顶上。
        val remaining = remainingCourses(data)
        if (remaining.isEmpty()) {
            views.setViewVisibility(R.id.widget_courses_container, View.GONE)
            views.setViewVisibility(R.id.widget_more, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "今日课程已结束")
            return views
        }

        views.setViewVisibility(R.id.widget_empty, View.GONE)
        views.setViewVisibility(R.id.widget_courses_container, View.VISIBLE)
        views.removeAllViews(R.id.widget_courses_container)

        // v1.6.4：中号固定 **2 门、平分**（用户要求）—— 每条占容器一半高度；
        // 超过 2 门仍然明确给「还有 N 门」，不裁半截。
        val shown = remaining.size.coerceAtMost(2)
        val extra = remaining.size - shown
        remaining.take(shown).forEach { course ->
            // v1.6.7：中号用三行条目（名 / 时间 / 教室）+ 中号自己的开关
            views.addView(
                R.id.widget_courses_container,
                buildCourseItem(context, course, prefs, dark,
                    size = Size.MEDIUM, style = TRIPLE),
            )
        }

        if (extra > 0) {
            views.setTextViewText(R.id.widget_more, "还有 $extra 门课")
            views.setViewVisibility(R.id.widget_more, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_more, View.GONE)
        }
        return views
    }

    // ---------------- LARGE：三列列表 ----------------

    private fun buildLarge(context: Context, data: WidgetTodayData?, heightDp: Int): RemoteViews {
        val prefs = prefsOf(data)
        val dark = prefs.useDark(context)
        val views = RemoteViews(context.packageName, R.layout.widget_large)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpenApp(context))
        applySkin(views, dark)
        views.setTextColor(R.id.widget_title, ink(dark))
        views.setTextColor(R.id.widget_more, moreText(dark))
        views.setTextColor(R.id.widget_empty, subText(dark))
        setSize(views, R.id.widget_title, scaled(prefs, 14f))
        setSize(views, R.id.widget_more, scaled(prefs, 10f))
        setSize(views, R.id.widget_empty, scaled(prefs, 12f))
        // v1.6.7：大号标题**不带教学周次**（用户要求去除）
        views.setTextViewText(R.id.widget_title, titleNoWeek(data))

        if (data == null || !data.hasSchedule || data.courses.isEmpty()) {
            views.setViewVisibility(R.id.widget_columns, View.GONE)
            views.setViewVisibility(R.id.widget_more, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "今日无课，好好休息吧")
            return views
        }
        if (WidgetDataStore.isStale(data)) {
            views.setViewVisibility(R.id.widget_columns, View.GONE)
            views.setViewVisibility(R.id.widget_more, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "点击打开 App 刷新今日课表")
            return views
        }

        val remaining = remainingCourses(data)
        if (remaining.isEmpty()) {
            views.setViewVisibility(R.id.widget_columns, View.GONE)
            views.setViewVisibility(R.id.widget_more, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "今日课程已结束")
            return views
        }

        views.setViewVisibility(R.id.widget_empty, View.GONE)
        views.setViewVisibility(R.id.widget_columns, View.VISIBLE)

        val columns = intArrayOf(
            R.id.widget_left_column,
            R.id.widget_right_column,
            R.id.widget_third_column,
            R.id.widget_fourth_column,
        )
        columns.forEach { views.removeAllViews(it) }

        // v1.6.4：大号改 **2×2 网格** —— 4 门课各占四分之一（用户要求"4 门平分"）。
        val shown = remaining.size.coerceAtMost(MAX_LARGE)
        remaining.take(shown).forEachIndexed { index, course ->
            // v1.6.7：大号同样三行条目，开关读大号自己那份（与中号互不影响）
            views.addView(
                columns[index],
                buildCourseItem(context, course, prefs, dark,
                    size = Size.LARGE, style = TRIPLE),
            )
        }

        // 剩余门数按「今天全部没上完的课」算 —— 被 MAX_LARGE 挡掉的也算，
        // 否则用户会以为今天只有 4 门课。
        val hidden = remaining.size - shown
        if (hidden > 0) {
            views.setTextViewText(R.id.widget_more, "还有 $hidden 门课，打开 App 查看全部")
            views.setViewVisibility(R.id.widget_more, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_more, View.GONE)
        }
        return views
    }

    // ---------------- 公共：条目 / 标题 / 计数 ----------------

    /// 构造一条课程（单行：色条 + 课程名 + 时间）。
    private fun buildCourseItem(
        context: Context,
        course: WidgetTodayCourse,
        prefs: WidgetPrefs,
        dark: Boolean,
        /// 目标尺寸（v1.6.7）：显示开关**按尺寸独立读取**，中号和大号互不影响。
        size: Size = Size.SMALL,
        style: ItemStyle = SLIM,
    ): RemoteViews {
        val item = RemoteViews(context.packageName, style.layoutId)
        item.setInt(R.id.item_root, "setBackgroundResource", itemBg(dark))
        item.setInt(R.id.item_color_bar, "setBackgroundColor", course.color)
        item.setTextColor(R.id.item_name, ink(dark))

        // v1.6.7：三个开关都按尺寸取各自的那一份
        val showTeacher = prefs.teacherFor(size)
        val showTime = prefs.timeFor(size)
        val showClassroom = prefs.classroomFor(size)

        val title = if (showTeacher && course.teacher.isNotBlank()) {
            "${course.name} · ${course.teacher}"
        } else {
            course.name
        }
        item.setTextViewText(R.id.item_name, title)

        if (style.isTriple) {
            // 三行：课程名 / 上课时间 / 教室（与小号的排版口径一致）
            item.setTextColor(R.id.item_time, subText(dark))
            item.setTextColor(R.id.item_room, subText(dark))
            setSize(item, R.id.item_name, scaled(prefs, 10.5f))
            setSize(item, R.id.item_time, scaled(prefs, 8.5f))
            setSize(item, R.id.item_room, scaled(prefs, 8.5f))
            toggleRow(item, R.id.item_time, showTime, course.timeText)
            toggleRow(item, R.id.item_room, showClassroom, course.classroom)
        } else {
            // 单行（小号）：时间 · 教室 拼在课程名右侧
            item.setTextColor(R.id.item_time, subText(dark))
            setSize(item, R.id.item_name, scaled(prefs, 11f))
            setSize(item, R.id.item_time, scaled(prefs, 9f))
            val detail = listOfNotNull(
                if (showTime) course.timeText.ifBlank { null } else null,
                if (showClassroom) course.classroom.ifBlank { null } else null,
            ).joinToString(" · ")
            toggleRow(item, R.id.item_time, true, detail)
        }
        return item
    }

    /// 副行（时间 / 教室）：开关关掉或内容为空时整行隐藏，不留空行。
    private fun toggleRow(item: RemoteViews, id: Int, show: Boolean, text: String) {
        if (show && text.isNotBlank()) {
            item.setViewVisibility(id, View.VISIBLE)
            item.setTextViewText(id, text)
        } else {
            item.setViewVisibility(id, View.GONE)
        }
    }

    /// 星期 · 第 N 周（周次开关关掉时只留星期）。
    private fun titleWithWeek(data: WidgetTodayData?, prefs: WidgetPrefs): String {
        if (data == null) return "今日课表"
        val weekNames = arrayOf("", "周一", "周二", "周三", "周四", "周五", "周六", "周日")
        val week = if (data.weekday in 1..7) weekNames[data.weekday] else ""
        val weekLabel =
            if (prefs.showWeek && data.semesterWeek > 0) "第 ${data.semesterWeek} 周" else ""
        val joined = listOfNotNull(
            week.ifBlank { null },
            weekLabel.ifBlank { null },
        ).joinToString(" · ")
        return joined.ifBlank { "今日课表" }
    }

    /// 只显示星期（**不带教学周次**）—— 大号专用（v1.6.7）。
    private fun titleNoWeek(data: WidgetTodayData?): String {
        if (data == null) return "今日课表"
        val weekNames = arrayOf("", "周一", "周二", "周三", "周四", "周五", "周六", "周日")
        val week = if (data.weekday in 1..7) weekNames[data.weekday] else ""
        return week.ifBlank { "今日课表" }
    }

    private fun buildTitle(data: WidgetTodayData?): String = titleWithWeek(data, WidgetPrefs())

    private fun nowMinute(): Int {
        val cal = java.util.Calendar.getInstance()
        return cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
    }

    /// 只保留**还没上完**的课：上完的从列表里消失，后面的自动顶上来。
    private fun remainingCourses(data: WidgetTodayData): List<WidgetTodayCourse> {
        val now = nowMinute()
        return data.courses.filter { it.endMinute > now }
    }

    /// 每列能放几条。reserveMore=true 时额外扣掉「还有 N 门」那一行。
    private fun perColumn(heightDp: Int, style: ItemStyle, reserveMore: Boolean): Int {
        var usable = heightDp - CARD_PAD_V - TITLE_BLOCK
        if (reserveMore) usable -= MORE_BLOCK
        if (usable < style.heightDp) return 0
        return (usable + style.gapDp) / (style.heightDp + style.gapDp)
    }

    /// 决定「显示几门 + 还剩几门」。
    ///
    /// 先按不显示「还有 N 门」算；如果课程更多就腾出那一行再算一次。
    private fun planCount(total: Int, heightDp: Int, columns: Int, style: ItemStyle): Pair<Int, Int> {
        if (total <= 0) return 0 to 0
        val capFull = perColumn(heightDp, style, false) * columns
        if (total <= capFull) return total to 0
        val capWithMore = perColumn(heightDp, style, true) * columns
        val shown = capWithMore.coerceAtLeast(1).coerceAtMost(total)
        return shown to (total - shown)
    }
}
