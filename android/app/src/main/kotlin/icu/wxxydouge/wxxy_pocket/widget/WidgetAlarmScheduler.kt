package icu.wxxydouge.wxxy_pocket.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * 小组件「下一节课」精准切换排程器（v2.2.14）。
 *
 * 为每个已添加的小部件排一个「下一整点」闹钟：在下一堂课开始/结束的时刻
 * （提前 1 秒）触发刷新，让「下一节课」组件在切换瞬间立即更新，不依赖系统
 * 每 60 分钟一次的粗粒度刷新。
 *
 * 数据来自 Flutter 侧写入的 SharedPreferences（含 startMinute/endMinute）。
 */
object WidgetAlarmScheduler {

    const val ACTION_REFRESH = "icu.wxxydouge.wxxy_pocket.WIDGET_REFRESH"

    class RefreshReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            try {
                // 闹钟到点：重渲染全部组件（内部会排下一轮闹钟）
                TodayWidgetRenderer.updateAll(context)
            } catch (_: Exception) {
                // 极端异常不崩溃，静默
            }
        }
    }

    /** 计算下次需要刷新的时刻：找「还没结束的下一堂课的 开始时刻」与「当前进行中课程的 结束时刻」中更早者。 */
    fun computeNextRefreshMillis(context: Context): Long? {
        val data = WidgetDataStore.read(context) ?: return null
        if (WidgetDataStore.isStale(data) || data.courses.isEmpty()) return null

        val now = System.currentTimeMillis()
        val calendar = java.util.Calendar.getInstance()
        val nowMinute = calendar.get(java.util.Calendar.HOUR_OF_DAY) * 60 +
            calendar.get(java.util.Calendar.MINUTE)

        var next = Long.MAX_VALUE
        for (course in data.courses) {
            // 未开始的课：在开始时刻刷新（切到「下一节」）
            if (course.startMinute > nowMinute) {
                next = minOf(next, startOfMinute(now, course.startMinute))
            }
            // 进行中的课：在结束时刻刷新（切走当前课）
            if (nowMinute in course.startMinute until course.endMinute) {
                next = minOf(next, startOfMinute(now, course.endMinute))
            }
        }
        return if (next == Long.MAX_VALUE) null else next
    }

    private fun startOfMinute(now: Long, minuteOfDay: Int): Long {
        val c = java.util.Calendar.getInstance()
        c.timeInMillis = now
        c.set(java.util.Calendar.HOUR_OF_DAY, minuteOfDay / 60)
        c.set(java.util.Calendar.MINUTE, minuteOfDay % 60)
        c.set(java.util.Calendar.SECOND, 0)
        c.set(java.util.Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }

    /** 对每个已添加的小部件排下一个刷新闹钟（去重：同时刻只排一个）。 */
    fun scheduleNext(context: Context) {
        val target = computeNextRefreshMillis(context) ?: return
        // 已在过去则 +1ms 兜底，避免立即触发
        val trigger = if (target <= System.currentTimeMillis()) {
            System.currentTimeMillis() + 1000
        } else target

        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, RefreshReceiver::class.java).setAction(ACTION_REFRESH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, trigger, pi)
        }
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, RefreshReceiver::class.java).setAction(ACTION_REFRESH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        am.cancel(pi)
    }
}