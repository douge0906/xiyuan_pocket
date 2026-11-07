package icu.wxxydouge.wxxy_pocket.widget

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 桌面小组件的「开机 / 覆盖安装后」自愈接收器（2026-11-04 新增）。
 *
 * 🔴 为什么需要它：
 *
 *   `WidgetAlarmScheduler` 把「下一节课切换时刻」排进 `AlarmManager`，
 *   而 **`AlarmManager` 里的一切在设备重启后都被系统清空**。原有链路里
 *   唯一的补排入口是 `AppWidgetProvider.onUpdate` —— 但那是系统按
 *   `updatePeriodMillis` 调的，最小只按 30 分钟算，且在 Doze / 国产 ROM
 *   的省电策略下会被大幅推迟（实测常常一整天都不来）。
 *
 *   于是重启之后：闹钟没了、onUpdate 不来 → 小组件永久停在重启前那一刻的
 *   内容上。用户看到的就是「小组件失效了 / 数据不更新了」，直到手动打开
 *   一次 App（App 启动时 Dart 会 syncTodayCourses，顺带重排闹钟）。
 *
 *   本接收器在开机/覆盖安装时**自己**把组件重绘一遍并重排闹钟，不依赖
 *   Flutter 引擎 —— 因为这时候拉一个 FlutterEngine 起来只为排个闹钟太重，
 *   而且 `BootReceiver`（补排通知提醒）已经在做那件事，两件事互不干扰。
 *
 *   纯 Kotlin，无需引擎，失败也不影响系统启动。
 */
class WidgetBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "XiyuanWidgetBoot"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val handled = action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED
        if (!handled) return

        // 逐段 try：这里是广播接收器，任何未捕获异常都会被算到「本 App 进程
        // 崩溃」头上（详见 TodayWidgetProvider.onUpdate 的注释）。
        try {
            WidgetDiagnostics.recordTick(context, "boot($action)")
        } catch (_: Throwable) {
        }

        // 1) 三个课表尺寸：重绘 + 由 updateAll 内部重排闹钟
        try {
            TodayWidgetRenderer.updateAll(context)
        } catch (e: Throwable) {
            Log.e(TAG, "schedule widgets reschedule failed", e)
        }

        // 2) 考试 / 校园卡：这两类不排闹钟，只需要重绘一次
        try {
            InfoWidgetRenderer.updateAll(context, InfoWidgetRenderer.Kind.EXAM)
        } catch (_: Throwable) {
        }
        try {
            InfoWidgetRenderer.updateAll(context, InfoWidgetRenderer.Kind.CARD)
        } catch (_: Throwable) {
        }

        // 3) 倒数日：纯日期计算，重绘一次即可
        try {
            CountdownWidgetRenderer.updateAll(context)
        } catch (e: Throwable) {
            Log.e(TAG, "countdown widget update failed", e)
        }

        // 4) 兜底：桌面上还有任意课表组件就再明确排一次闹钟。
        //    updateAll(context) 内部已经排过，但那条路径在
        //    「所有尺寸都没实例」时会提前返回，这里保证只有真的有实例才排。
        try {
            if (hasAnyWidget(context)) {
                WidgetAlarmScheduler.scheduleNext(context)
            }
        } catch (_: Throwable) {
        }

        Log.i(TAG, "widgets rescheduled for $action")
    }

    private fun hasAnyWidget(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        val classes = listOf(
            SmallWidgetProvider::class.java,
            MediumWidgetProvider::class.java,
            LargeWidgetProvider::class.java,
            ExamWidgetProvider::class.java,
            CardWidgetProvider::class.java,
            CountdownWidgetProvider::class.java,
        )
        return classes.any { c ->
            try {
                manager.getAppWidgetIds(ComponentName(context, c)).isNotEmpty()
            } catch (_: Throwable) {
                false
            }
        }
    }
}
