package icu.wxxydouge.wxxy_pocket

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/// 开机/应用重装/系统改时间后重建待办提醒的定时任务。
/// Android 在重启后会清除 AlarmManager 的定时通知，因此需要在 BOOT_COMPLETED
/// （以及应用被覆盖安装 MY_PACKAGE_REPLACED）时，启动一个无界面 Flutter 引擎，
/// 调用 Dart 侧 notificationRescheduleEntrypoint 重新排程所有未来提醒。
///
/// 🔴 2026-11-04 审查 P1：`TIME_SET` / `TIMEZONE_CHANGED` 也必须接。
///    `AlarmManager.setExact(RTC_WAKEUP, ...)` 里存的是**绝对 epoch**，
///    用户手动改时间、飞行模式自动对时、跨时区落地，系统都不会重算
///    「目标本地墙钟」，已排的闹钟相对用户想上课的时刻整体偏移。
///    这两个 action 在 Android 8.0 的隐式广播豁免清单内，静态注册可用。
///
/// 🔴 2026-11-04 审查 P0：这里的 catch 曾经是**完全空的**。
///    Dart 侧入口一度不在 AOT 产物里（lib/main.dart 没有 import 那个库），
///    `executeDartEntrypoint` 抛 argumentError 被吞掉，开机补排 100% 静默失败，
///    用户重启后所有提醒永久消失却查不到任何线索。现在必须落日志。
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "XiyuanBootReceiver"

        // 持有引擎引用，避免 onReceive 返回后引擎被 GC 导致排程中断
        @Volatile
        private var engine: FlutterEngine? = null

        private val HANDLED_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
        )
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action !in HANDLED_ACTIONS) return

        try {
            val flutterEngine = engine ?: FlutterEngine(context).also {
                engine = it
                GeneratedPluginRegistrant.registerWith(it)
            }
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint("main.dart", "notificationRescheduleEntrypoint")
            )
            Log.i(TAG, "reschedule entrypoint dispatched for $action")
        } catch (e: Throwable) {
            // 不再静默：这条链路已经静默失败过一轮，必须留下可查的线索。
            Log.e(TAG, "reschedule failed for $action", e)
        }
    }
}
