package icu.wxxydouge.wxxy_pocket.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.util.TypedValue
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import icu.wxxydouge.wxxy_pocket.R
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale

/**
 * 倒数日小组件（2026-11-04 新增，需求 #6「桌面倒数日」）。
 *
 * 与考试/校园卡组件的关键差异：**这里的天数由原生现算，不从 Dart 拿**。
 *
 * 为什么这样设计：
 *  · 考试组件存的是 `daysLeft`（Dart 写入时算好的数字）。跨零点后这个数字
 *    就是错的，而小组件不保证当天会被刷新 —— 于是「还有 5 天」会一直挂到
 *    用户打开 App 为止。这是同一类「隔天失效」问题的根源。
 *  · 倒数日只需要「绝对日期」，`还有几天` 是个纯函数。把它放到原生，
 *    任何时候渲染都不会过期，跨零点、关机重启、放几天再看都自动正确。
 *    连闹钟都不需要排（这一点和课表组件不同）。
 *
 * 数据由 Dart 侧 `WidgetSyncService.syncCountdownWidget()` 写入
 * home_widget 共享存储的 `widget_countdown_data`，结构：
 * ```json
 * { "items": [{"title","emoji","date":"2026-12-25","daysLeft":51,"note"}],
 *   "total": 4, "updatedDate": "2026-11-04",
 *   "prefs": { "theme": "system", "accent": "1F2937", "fontScale": 1.0 } }
 * ```
 * `daysLeft` 仅作兜底（解析不出 date 时用），正常路径一律现算。
 */
object CountdownWidgetRenderer {

    const val KEY = "widget_countdown_data"

    /** 单条渲染所需的全部信息，日期在构造时就截到当地零点。 */
    private data class Entry(
        val title: String,
        val emoji: String,
        val dateText: String,
        val daysLeft: Int,
    )

    fun updateAll(context: Context, slot: Int = 0) {
        val manager = AppWidgetManager.getInstance(context)
        val provider = if (slot == 1) CountdownWidget2Provider::class.java else CountdownWidgetProvider::class.java
        val ids = manager.getAppWidgetIds(ComponentName(context, provider))
        if (ids.isEmpty()) {
            WidgetDiagnostics.recordApplied(context, "COUNTDOWN" + (if (slot == 1) "2" else ""), 0, 0)
            return
        }
        val raw = HomeWidgetPlugin.getData(context).getString(KEY, null)
        val json = try {
            raw?.let { JSONObject(it) }
        } catch (_: Exception) {
            null
        }
        var applied = 0
        for (id in ids) {
            // 2026-11-05（用户 m24495 #3「两者都要」）：**每个实例单独构建**。
            // 原来四个实例共用同一份 RemoteViews —— 现在每个实例可能绑了不同的
            // 倒数日，必须按 id 各建各的。RemoteViews 本身也不能复用：
            // 它内部累积的是「要应用到布局上的动作序列」，复用会把上一个实例的
            // 动作再播一遍。
            val views = build(context, selectForInstance(context, json, id, slot), slot)
            try {
                manager.updateAppWidget(id, views)
                applied++
            } catch (t: Throwable) {
                // RemoteViews 在某些 Launcher 上会抛（组件被移除的瞬间等），
                // 逐个 try 保证一个 id 失败不影响其它 id。
                WidgetDiagnostics.recordError(context, "countdown.updateAppWidget(id=$id)", t)
            }
        }
        WidgetDiagnostics.recordApplied(context, "COUNTDOWN" + (if (slot == 1) "2" else ""), applied, ids.size)
    }

    fun isInstalled(context: Context, slot: Int = 0): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        val provider = if (slot == 1) CountdownWidget2Provider::class.java else CountdownWidgetProvider::class.java
        return try {
            manager.getAppWidgetIds(ComponentName(context, provider)).isNotEmpty()
        } catch (_: Throwable) {
            false
        }
    }

    // ── 颜色工具（与 TodayWidgetRenderer 同逻辑，但不能跨对象引用 private）──

    /** 深色模式下正文颜色：近白但保留一点灰度，不像纯白那么刺眼。 */
    private fun ink(dark: Boolean): Int =
        if (dark) 0xFFE5E7EB.toInt() else 0xFF1F2937.toInt()

    /** 次要文字：比正文淡一档，用于日期 / 说明行。 */
    private fun subText(dark: Boolean): Int =
        if (dark) 0xFF9CA3AF.toInt() else 0xFF667085.toInt()

    /** 卡片背景资源 id：深色 / 浅色各一份 drawable。 */
    private fun cardBg(dark: Boolean): Int =
        if (dark) R.drawable.widget_card_bg_dark else R.drawable.widget_card_bg_light

    /** 绑定记录键：与 Dart `WidgetSyncService._bindKey` 必须逐字一致。 */
    private fun bindKey(appWidgetId: Int): String = "cd_binding_$appWidgetId"

    /**
     * 按实例的绑定记录挑出要显示的那份数据。
     *
     * 绑定存在时：返回一个**新的** JSONObject，items 只含被绑定的条目
     * （顺序按绑定列表，不按日期），total 也改成绑定条数 ——
     * 「还有 N 个」指的是这个组件里没显示出来的，而不是全库的。
     * 没有绑定 / 绑定为空 / 绑定的条目都被删了 → 原样返回，走默认「最近 3 条」。
     */
    private fun selectForInstance(
        context: Context, root: JSONObject?, appWidgetId: Int, slot: Int
    ): JSONObject? {
        if (root == null) return null
        // 没有 pin 绑定（用户 m26008 #1 一页式）：按 slot 取页面下发的固定条目。
        // 倒数日 1 -> slot0，倒数日 2 -> slot1，两个系统组件天然各自显示自己那条。
        fun bySlot(): JSONObject {
            val slotObj = root.optJSONObject("slot$slot")
            return JSONObject(root.toString()).apply {
                val arr = org.json.JSONArray()
                if (slotObj != null && slotObj.optString("title", "").isNotEmpty()) arr.put(slotObj)
                put("items", arr)
                put("total", arr.length())
            }
        }
        val raw = HomeWidgetPlugin.getData(context).getString(bindKey(appWidgetId), null)
        if (raw.isNullOrBlank()) return bySlot()
        val ids = try {
            org.json.JSONArray(raw)
        } catch (_: Exception) {
            return bySlot()
        }
        if (ids.length() == 0) return bySlot()
        val pool = root.optJSONArray("itemsAll") ?: root.optJSONArray("items") ?: return bySlot()
        val byId = HashMap<String, JSONObject>()
        for (i in 0 until pool.length()) {
            val o = pool.optJSONObject(i) ?: continue
            val id = o.optString("id", "")
            if (id.isNotEmpty()) byId[id] = o
        }
        val picked = org.json.JSONArray()
        for (i in 0 until minOf(ids.length(), 1)) {
            val o = byId[ids.optString(i, "")] ?: continue
            picked.put(o)
        }
        if (picked.length() == 0) return bySlot()
        return JSONObject(root.toString()).apply {
            put("items", picked)
            put("total", picked.length())
        }
    }

    /// 单条渲染（2026-11-05 重构）：标题 + 日期 + 大数字天数。
    ///
    /// 数据来源：[entries] 是**本条**要显示的倒数日（已按绑定/默认规则挑好，
    /// 见 `readEntriesFor`）。空 = 渲染「点这里添加」占位。
    private fun build(context: Context, data: JSONObject?, slot: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_countdown)
        val dark = useDark(context, data)

        val accent = accentColor(data, dark)
        val titleColor = ink(dark)
        val subColor = subText(dark)

        views.setTextColor(R.id.cd_title, subColor)
        views.setTextColor(R.id.cd_item_title, titleColor)
        views.setTextColor(R.id.cd_item_value, accent)
        views.setTextColor(R.id.cd_item_sub, subColor)

        val scale = try {
            (data?.optJSONObject("prefs")?.optDouble("fontScale", 1.0) ?: 1.0)
                .toFloat().coerceIn(0.8f, 1.2f)
        } catch (_: Exception) { 1.0f }
        views.setTextViewTextSize(R.id.cd_title, TypedValue.COMPLEX_UNIT_SP, 11.5f * scale)
        views.setTextViewTextSize(R.id.cd_item_title, TypedValue.COMPLEX_UNIT_SP, 14f * scale)
        views.setTextViewTextSize(R.id.cd_item_value, TypedValue.COMPLEX_UNIT_SP, 30f * scale)
        views.setTextViewTextSize(R.id.cd_item_sub, TypedValue.COMPLEX_UNIT_SP, 10f * scale)

        // 点击 → 倒数日组件页（widget_hub → WidgetInfoPage）。
        // 空态与有数据态走同一个 PendingIntent，系统不需要区分。
        try {
            views.setOnClickPendingIntent(R.id.cd_root, LaunchIntents.countdownSlot(context, slot))
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "countdown.build.click", t)
        }

        // 皮肤/背景
        try {
            views.setInt(R.id.cd_root, "setBackgroundResource", cardBg(dark))
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "countdown.build.skin", t)
        }

        val arr = data?.optJSONArray("items")
        val item = arr?.optJSONObject(0)
        if (item == null) {
            views.setTextViewText(R.id.cd_title, "倒数日 ${slot + 1}")
            views.setTextViewText(R.id.cd_more, "")
            views.setTextViewText(R.id.cd_item_title, "还没有倒数日")
            views.setTextViewText(R.id.cd_item_value, "--")
            views.setTextViewText(R.id.cd_item_sub, "点这里添加")
            return views
        }

        val title = item.optString("title", "").trim()
        val rawDate = item.optString("date", "").trim()
        val daysLeft = daysFromToday(rawDate) ?: item.optInt("daysLeft", 0)
        val dateLabel = beautify(rawDate).ifEmpty { rawDate }

        views.setTextViewText(R.id.cd_title, "倒数日 ${slot + 1}")
        views.setTextViewText(R.id.cd_more, "")
        views.setTextViewText(R.id.cd_item_title, title.ifEmpty { "倒数日" })
        views.setTextViewText(R.id.cd_item_value, if (daysLeft <= 0) "今天" else "$daysLeft")
        views.setTextViewText(
            R.id.cd_item_sub,
            if (daysLeft <= 0) dateLabel else "$dateLabel · 还有 $daysLeft 天"
        )
        return views
    }

    /** 日期在原生侧现算，键 `date` 是 `yyyy-MM-dd`。 */
    private fun Entry.daysLeftText(): String = when {
        daysLeft == 0 -> "今天"
        daysLeft == 1 -> "明天"
        daysLeft > 0 -> "还有 $daysLeft 天"
        else -> "已过 ${-daysLeft} 天"
    }

    private fun parseEntries(root: JSONObject?): List<Entry> {
        val arr = root?.optJSONArray("items") ?: return emptyList()
        val out = mutableListOf<Entry>()
        for (i in 0 until minOf(arr.length(), 1)) {
            val o = arr.optJSONObject(i) ?: continue
            val title = o.optString("title", "").trim()
            if (title.isEmpty()) continue
            val dateText = o.optString("date", "").trim()
            val computed = daysFromToday(dateText)
            out.add(
                Entry(
                    title = title,
                    emoji = o.optString("emoji", ""),
                    dateText = beautify(dateText),
                    // date 解析不出来时退回 Dart 下发的数字（宁可显示一个可能过期的
                    // 数字，也不要显示「还有 0 天」这种凭空的错误值）。
                    daysLeft = computed ?: o.optInt("daysLeft", 0),
                )
            )
        }
        return out
    }

    /** `yyyy-MM-dd` → 距今天的天数（今天 = 0）。解析失败返回 null。 */
    private fun daysFromToday(text: String): Int? {
        if (text.length < 8) return null
        val parts = text.split('-')
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null
        // 🔴 2026-11-06（用户 m26371）：这里原来是
        //    `Calendar.getInstance().apply { clear(); set(get(YEAR), get(MONTH), get(DAY_OF_MONTH)) }`
        //    —— `clear()` 会把字段全清成 1970 纪元，再 `get(YEAR)` 拿到的是 1970 而不是今天，
        //    于是 `target(2026) - today(1970) ≈ 20787` 这种怪数字。
        //    先把「今天」的年月日取出来，再截零点。
        val now = Calendar.getInstance()
        val y0 = now.get(Calendar.YEAR)
        val m0 = now.get(Calendar.MONTH)
        val d0 = now.get(Calendar.DAY_OF_MONTH)
        val target = Calendar.getInstance().apply {
            clear()
            set(y, m - 1, d)
        }
        val today = Calendar.getInstance().apply {
            clear()
            set(y0, m0, d0)
        }
        val diff = target.timeInMillis - today.timeInMillis
        // 用 Calendar 的毫秒差除以一天再四舍五入：跨夏令时那天可能是 23/25 小时，
        // 直接整除会在边界丢一天。
        return Math.round(diff.toDouble() / 86_400_000.0).toInt()
    }

    /** `2026-12-25` → `12月25日`（今年则省掉年份，减少一行宽度压力）。 */
    private fun beautify(text: String): String {
        val parts = text.split('-')
        if (parts.size != 3) return text
        val y = parts[0].toIntOrNull() ?: return text
        val m = parts[1].toIntOrNull() ?: return text
        val d = parts[2].toIntOrNull() ?: return text
        val thisYear = Calendar.getInstance().get(Calendar.YEAR)
        return if (y == thisYear) {
            String.format(Locale.CHINA, "%d月%d日", m, d)
        } else {
            String.format(Locale.CHINA, "%d年%d月%d日", y, m, d)
        }
    }

    private fun useDark(context: Context, root: JSONObject?): Boolean {
        val theme = root?.optJSONObject("prefs")?.optString("theme", "system") ?: "system"
        return when (theme) {
            "dark" -> true
            "light" -> false
            else -> (context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
    }

    private fun accentColor(root: JSONObject?, dark: Boolean): Int {
        val hex = root?.optJSONObject("prefs")?.optString("accent", "1F2937")
            ?.trim()?.removePrefix("#") ?: "1F2937"
        val c = try {
            if (hex.length == 6) (0xFF000000 or hex.toLong(16)).toInt() else 0xFF1F2937.toInt()
        } catch (_: Exception) {
            0xFF1F2937.toInt()
        }
        if (!dark) return c
        val r = (c shr 16) and 0xFF
        val g = (c shr 8) and 0xFF
        val b = c and 0xFF
        val lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        return if (lum < 0.5) 0xFFE5E7EB.toInt() else c
    }
}

/**
 * 倒数日组件 Provider。
 *
 * 不排闹钟：天数由 [CountdownWidgetRenderer] 每次渲染时现算，而系统会在
 * `updatePeriodMillis`（30 分钟）与桌面重绘时调 `onUpdate`，跨零点后
 * 第一次被调起就自动正确。这是刻意做的简化 —— 多一个闹钟就多一条
 * 会被国产 ROM 冻结的链路。
 */
class CountdownWidgetProvider : android.appwidget.AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        try {
            CountdownWidgetRenderer.updateAll(context, 0)
        } catch (_: Throwable) {
            // 理由同 TodayWidgetProvider.onUpdate：本回调跑在本 App 进程，
            // 未捕获异常会被算成「本进程崩溃」。
        }
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        try {
            CountdownWidgetRenderer.updateAll(context, 0)
        } catch (_: Throwable) {
        }
    }

    /**
     * 2026-11-05（用户 m24495 #3「两者都要」）：接收 pin 成功的回调。
     *
     * `MainActivity` 的 `pinCountdown` 把 id 列表塞进 PendingIntent extras，
     * 系统在用户确认「添加」后连同 `AppWidgetManager.EXTRA_APPWIDGET_ID`
     * 一起回传。这里把绑定写进共享存储，再立刻渲染一次。
     *
     * 用户点了「取消」时这个广播不会来 —— 组件没建成就没有绑定，无残留。
     */
    override fun onReceive(context: Context, intent: android.content.Intent) {
        super.onReceive(context, intent)
        if (intent.action != "icu.wxxydouge.wxxy_pocket.COUNTDOWN_PINNED") return
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        val ids = intent.getStringArrayListExtra("bindIds") ?: arrayListOf()
        try {
            HomeWidgetPlugin.getData(context).edit()
                .putString("cd_binding_$id", org.json.JSONArray(ids).toString())
                .apply()
            CountdownWidgetRenderer.updateAll(context, 0)
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "countdown.onPinned", t)
        }
    }

    /** 组件被用户从桌面删掉时清掉绑定，避免 id 被系统复用后串数据。 */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        try {
            val e = HomeWidgetPlugin.getData(context).edit()
            for (id in appWidgetIds) e.remove("cd_binding_$id")
            e.apply()
        } catch (_: Throwable) {
        }
    }
}

/** 第二个系统倒数日组件：与组件 1 独立绑定、独立渲染。 */
class CountdownWidget2Provider : android.appwidget.AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        try { CountdownWidgetRenderer.updateAll(context, 1) } catch (_: Throwable) {}
    }
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        try { CountdownWidgetRenderer.updateAll(context, 1) } catch (_: Throwable) {}
    }
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        try {
            val e = HomeWidgetPlugin.getData(context).edit()
            for (id in appWidgetIds) e.remove("cd_binding_$id")
            e.apply()
        } catch (_: Throwable) {}
    }
}
