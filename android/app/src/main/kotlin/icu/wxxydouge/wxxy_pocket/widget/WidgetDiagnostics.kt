package icu.wxxydouge.wxxy_pocket.widget

import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * 小组件自检：把「原生侧到底读到了什么、哪一步炸了」记下来。
 *
 * ## 为什么需要它（2026-11-03）
 *
 * 用户反馈「小组件获取不到数据」。排查时最大的障碍不是没 bug，而是
 * **所有失败都被静默吞掉了**：
 *
 *  · `TodayWidgetProvider.onUpdate` 外层是 `try/catch (_: Throwable) {}`；
 *  · `WidgetDataStore.read()` 解析失败 `catch (_: Exception) { null }`；
 *  · Dart 侧 `syncTodayCourses()` 外层也是 `catch (_) {}`。
 *
 * 三层静默叠起来的结果是：`build()` 里任何一行抛异常（RemoteViews 的
 * 反射方法是按 id 调用的，id 写错 / 视图类型不匹配都会抛），小组件就
 * **永远停在 XML 里的默认占位文字**，而且界面上看不出任何差别 ——
 * 用户只会说「没数据」，开发只能靠猜。
 *
 * 这个类把每次渲染的结果（成功 / 失败原因 / 读到的课程数 / 数据日期）
 * 落到 SharedPreferences，Dart 侧通过 MethodChannel 读出来显示在
 * 「桌面小组件」页的自检卡片里。**把不可见的失败变成可见的**，
 * 这是修「静默 bug」唯一可靠的路子。
 */
object WidgetDiagnostics {

    private const val PREFS = "xiyuan_widget_diagnostics"
    private const val KEY_LAST_ERROR = "last_error"
    private const val KEY_LAST_READ = "last_read_status"
    private const val KEY_LAST_RENDER = "last_render_at"
    private const val KEY_LAST_COUNT = "last_course_count"
    private const val KEY_LAST_TICK = "last_tick"
    private const val KEY_APPLIED = "applied_"

    /**
     * 记录一次「系统真的叫到我了」。
     *
     * 为什么必须记这个：`onUpdate` / `onEnabled` / 闹钟 `RefreshReceiver`
     * 只要有一个环节没被触发，小组件就会**永远停在 XML 默认文字**，
     * 而现场看起来和「渲染失败」一模一样。有了这个时间戳，就能一眼分出：
     *   · `上次渲染` 为空    → 系统根本没调过来（Provider 没注册 / 组件被删 / 广播没到）
     *   · 有值但 `数据字节`=0 → 调到了，但 Dart 侧没写数据
     *   · 都有值但内容是默认文字 → 渲染抛异常（看 `上次错误`）
     */
    fun recordTick(context: Context, where: String) {
        try {
            prefs(context).edit()
                .putString(KEY_LAST_TICK, "$where @ ${System.currentTimeMillis()}")
                .apply()
        } catch (_: Throwable) {
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 记录一次渲染失败。[where] 用来区分是哪个尺寸 / 哪个 id 挂了。 */
    fun recordError(context: Context, where: String, error: Throwable) {
        try {
            val msg = "${error.javaClass.simpleName}: ${error.message}"
            prefs(context).edit()
                .putString(KEY_LAST_ERROR, "$where → $msg")
                .putLong(KEY_LAST_RENDER, System.currentTimeMillis())
                .apply()
        } catch (_: Throwable) {
            // 自检本身失败不能反过来影响渲染
        }
    }

    /** 记录某一类组件「成功调了几次 updateAppWidget / 共几个实例」。 */
    fun recordApplied(context: Context, size: String, applied: Int, total: Int) {
        try {
            prefs(context).edit()
                .putString(KEY_APPLIED + size, "$applied/$total")
                .apply()
        } catch (_: Throwable) {
        }
    }

    /** 记录一次成功的读取。 */
    fun recordRead(context: Context, hasData: Boolean, date: String, count: Int) {
        try {
            val status = if (hasData) "读到数据" else "没有数据（或解析失败）"
            prefs(context).edit()
                .putString(KEY_LAST_READ, "$status · date=$date · courses=$count")
                .putInt(KEY_LAST_COUNT, count)
                .apply()
        } catch (_: Throwable) {
        }
    }

    /**
     * 导出当前自检信息，供 Dart 侧展示。
     *
     * 这里**顺带做一次真实读取**（而不是只回放上次记录），这样用户点
     * 「自检」时拿到的就是此刻的真实状态。
     */
    fun snapshot(context: Context): Map<String, Any?> {
        val p = prefs(context)
        var hasData = false
        var date = ""
        var count = 0
        var readError: String? = null
        try {
            val data = WidgetDataStore.read(context)
            if (data != null) {
                hasData = true
                date = data.date
                count = data.courses.size
            }
        } catch (t: Throwable) {
            readError = "${t.javaClass.simpleName}: ${t.message}"
        }

        val raw = try {
            HomeWidgetPlugin.getData(context)
                .getString("widget_today_courses", null)
        } catch (_: Throwable) {
            null
        }

        return mapOf(
            "hasData" to hasData,
            "date" to date,
            "courseCount" to count,
            // 原始字符串长度：0 / null 说明 Dart 侧根本没写进来
            "rawLength" to (raw?.length ?: 0),
            "rawHead" to (raw?.take(160) ?: ""),
            "readError" to readError,
            "lastError" to p.getString(KEY_LAST_ERROR, ""),
            "lastRead" to p.getString(KEY_LAST_READ, ""),
            "lastTick" to p.getString(KEY_LAST_TICK, ""),
            "lastRenderAt" to p.getLong(KEY_LAST_RENDER, 0L),
            // 2026-11-04（用户 m20128 #4）：小组件逻辑整份回退到 v1.0.8，
            // 那两个辅助方法也一并消失 —— 这里改成自给自足，不再借渲染层的手。
            "smallInstalled" to hasInstances(context, SmallWidgetProvider::class.java),
            "mediumInstalled" to hasInstances(context, MediumWidgetProvider::class.java),
            "largeInstalled" to hasInstances(context, LargeWidgetProvider::class.java),
            "exactAlarm" to canScheduleExact(context),
            // 2026-11-04 晚：「有实例」和「updateAppWidget 调通了」是两件事。
            // 空串 = 还没跑过任何一次渲染；"N/M" = M 个实例里有 N 个调通。
            "appliedSmall" to p.getString(KEY_APPLIED + "SMALL", ""),
            "appliedMedium" to p.getString(KEY_APPLIED + "MEDIUM", ""),
            "appliedLarge" to p.getString(KEY_APPLIED + "LARGE", ""),
            "appliedExam" to p.getString(KEY_APPLIED + "EXAM", ""),
            "appliedCard" to p.getString(KEY_APPLIED + "CARD", ""),
            "appliedCountdown" to p.getString(KEY_APPLIED + "COUNTDOWN", ""),
        )
    }

    /** 该 Provider 是否还有实例在桌面上（回退 v1.0.8 后自带，不依赖渲染层）。 */
    private fun hasInstances(context: Context, cls: Class<*>): Boolean {
        return try {
            val manager = android.appwidget.AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(android.content.ComponentName(context, cls)).isNotEmpty()
        } catch (_: Throwable) {
            false
        }
    }

    /** 精确闹钟是否可用（同上，自带一份）。 */
    private fun canScheduleExact(context: Context): Boolean {
        return try {
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return true
            val am = context.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            am.canScheduleExactAlarms()
        } catch (_: Throwable) {
            false
        }
    }

    /** 清空历史错误（用户点「重置自检」时用）。 */
    fun clear(context: Context) {
        try {
            prefs(context).edit().clear().apply()
        } catch (_: Throwable) {
        }
    }
}
