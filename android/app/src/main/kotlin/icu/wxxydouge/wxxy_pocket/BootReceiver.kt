package icu.wxxydouge.wxxy_pocket

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/// 开机/应用重装后重建待办提醒的定时任务。
/// Android 在重启后会清除 AlarmManager 的定时通知，因此需要在 BOOT_COMPLETED
/// （以及应用被覆盖安装 MY_PACKAGE_REPLACED）时，启动一个无界面 Flutter 引擎，
/// 调用 Dart 侧 notificationRescheduleEntrypoint 重新排程所有未来提醒。
class BootReceiver : BroadcastReceiver() {
    companion object {
        // 持有引擎引用，避免 onReceive 返回后引擎被 GC 导致排程中断
        @Volatile
        private var engine: FlutterEngine? = null
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        try {
            val flutterEngine = FlutterEngine(context)
            engine = flutterEngine
            GeneratedPluginRegistrant.registerWith(flutterEngine)
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint("main.dart", "notificationRescheduleEntrypoint")
            )
        } catch (e: Exception) {
            // 静默失败：开机补排是「尽力而为」，应用打开时仍会再次补排
        }
    }
}
