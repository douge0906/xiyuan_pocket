package icu.wxxydouge.wxxy_pocket.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.net.Uri
import android.util.TypedValue
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import icu.wxxydouge.wxxy_pocket.MainActivity
import icu.wxxydouge.wxxy_pocket.R
import org.json.JSONObject
import java.util.Locale

/**
 * 信息型小组件：考试倒计时 / 校园卡余额。
 *
 * 数据由 Flutter 侧写入 home_widget 的共享存储，key 分别为
 * `widget_exam_data` / `widget_card_data`。均为本地缓存，不在小组件里发网络请求。
 */
object InfoWidgetRenderer {

    enum class Kind { EXAM, CARD }

    private const val EXAM_KEY = "widget_exam_data"
    private const val CARD_KEY = "widget_card_data"

    fun updateAll(context: Context, kind: Kind) {
        val manager = AppWidgetManager.getInstance(context)
        val cls = when (kind) {
            Kind.EXAM -> ExamWidgetProvider::class.java
            Kind.CARD -> CardWidgetProvider::class.java
        }
        val ids = manager.getAppWidgetIds(ComponentName(context, cls))
        if (ids.isEmpty()) return
        val key = if (kind == Kind.EXAM) EXAM_KEY else CARD_KEY
        val raw = HomeWidgetPlugin.getData(context).getString(key, null)
        val json = try {
            raw?.let { JSONObject(it) }
        } catch (_: Exception) {
            null
        }
        for (id in ids) {
            manager.updateAppWidget(id, build(context, json, kind))
        }
    }

    fun isInstalled(context: Context, kind: Kind): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        val cls = if (kind == Kind.EXAM) {
            ExamWidgetProvider::class.java
        } else {
            CardWidgetProvider::class.java
        }
        return manager.getAppWidgetIds(ComponentName(context, cls)).isNotEmpty()
    }

    private fun build(context: Context, root: JSONObject?, kind: Kind): RemoteViews {
        val layout = if (kind == Kind.EXAM) R.layout.widget_exam else R.layout.widget_card
        val views = RemoteViews(context.packageName, layout)
        val dark = useDark(context, root)
        views.setInt(
            R.id.info_root,
            "setBackgroundResource",
            if (dark) R.drawable.widget_card_bg_dark else R.drawable.widget_card_bg_light
        )
        val primary = if (dark) 0xFFF3F4F6.toInt() else 0xFF1F2937.toInt()
        val secondary = if (dark) 0xFF9CA3AF.toInt() else 0xFF667085.toInt()
        val accent = accentColor(root, dark)
        val scale = (root?.optJSONObject("prefs")?.optDouble("fontScale", 1.0) ?: 1.0)
            .toFloat().coerceIn(0.8f, 1.2f)

        views.setTextViewText(R.id.info_title, if (kind == Kind.EXAM) "考试倒计时" else "校园卡")
        views.setTextColor(R.id.info_title, accent)
        views.setTextViewTextSize(
            R.id.info_title, TypedValue.COMPLEX_UNIT_SP, 12f * scale
        )

        if (kind == Kind.EXAM) {
            val hasExam = root?.optBoolean("hasExam", false) == true
            val days = root?.optInt("daysLeft", 0) ?: 0
            val name = root?.optString("name", "").orEmpty()
            val meta = root?.optString("meta", "").orEmpty()
            views.setTextViewText(
                R.id.info_headline,
                if (hasExam && name.isNotEmpty()) name else "暂无考试安排"
            )
            views.setTextColor(R.id.info_headline, primary)
            views.setTextViewTextSize(
                R.id.info_headline, TypedValue.COMPLEX_UNIT_SP, 14f * scale
            )
            views.setTextViewText(
                R.id.info_value,
                if (hasExam) {
                    if (days <= 0) "今天" else "$days 天"
                } else {
                    ""
                }
            )
            views.setTextColor(R.id.info_value, primary)
            views.setTextViewTextSize(
                R.id.info_value, TypedValue.COMPLEX_UNIT_SP, 30f * scale
            )
            views.setTextViewText(
                R.id.info_meta,
                if (hasExam) meta else "打开 App 同步考试安排"
            )
            views.setTextColor(R.id.info_meta, secondary)
        } else {
            val hasBalance = root?.optBoolean("hasBalance", false) == true
            val balance = root?.optDouble("balance", 0.0) ?: 0.0
            val updated = root?.optString("updatedText", "").orEmpty()
            views.setTextViewText(
                R.id.info_value,
                if (hasBalance) String.format(Locale.CHINA, "¥ %.2f", balance) else "¥ --"
            )
            views.setTextColor(R.id.info_value, primary)
            views.setTextViewTextSize(
                R.id.info_value, TypedValue.COMPLEX_UNIT_SP, 26f * scale
            )
            views.setTextViewText(
                R.id.info_meta,
                if (hasBalance) {
                    "更新于 $updated"
                } else {
                    "打开 App 刷新余额"
                }
            )
            views.setTextColor(R.id.info_meta, secondary)
        }

        val uri = if (kind == Kind.EXAM) {
            Uri.parse("homewidget://exam")
        } else {
            Uri.parse("homewidget://card")
        }
        val pending = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            uri
        )
        views.setOnClickPendingIntent(R.id.info_root, pending)
        return views
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

abstract class BaseInfoWidgetProvider : android.appwidget.AppWidgetProvider() {
    protected abstract val kind: InfoWidgetRenderer.Kind

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        InfoWidgetRenderer.updateAll(context, kind)
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        InfoWidgetRenderer.updateAll(context, kind)
    }
}

class ExamWidgetProvider : BaseInfoWidgetProvider() {
    override val kind = InfoWidgetRenderer.Kind.EXAM
}

class CardWidgetProvider : BaseInfoWidgetProvider() {
    override val kind = InfoWidgetRenderer.Kind.CARD
}
