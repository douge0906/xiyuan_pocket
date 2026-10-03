package icu.wxxydouge.wxxy_pocket

import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 桌面小组件的数据桥已整体迁移到 home_widget 插件（v1.0.0）：
        //   Dart 侧 HomeWidget.saveWidgetData → HomeWidget.updateWidget
        //   原生侧 WidgetDataStore.read 读同一份存储 → TodayWidgetRenderer 渲染
        // 原先的 icu.wxxydouge.wxxy_pocket/widget MethodChannel 已整体移除。
        //
        // 已随功能下线移除的通道（Dart 侧零调用，删于 v2.4.9）：
        //   · .../gallery —— 保存图片到相册（九宫格切图时代；权限 WRITE_EXTERNAL_STORAGE 一并移除）
        //   · .../text    —— GBK 解码（已由 Dart 侧 TextDecodeService.decodeSmart 取代）

        // v2.3.6：Android 16 实时更新（Live Updates / OPPO 流体云）状态诊断与设置跳转
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "icu.wxxydouge.wxxy_pocket/live_update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(liveUpdateStatus())
                    "openSettings" -> result.success(openPromotedSettings())
                    else -> result.notImplemented()
                }
            }
    }

    /** Android 16 实时更新（胶囊/流体云）诊断：全部反射读取，缺 API 时返回 null 而非崩溃。 */
    private fun liveUpdateStatus(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        map["sdkInt"] = Build.VERSION.SDK_INT
        map["supported"] = Build.VERSION.SDK_INT >= 36
        // Manifest 是否声明且被授予 POST_PROMOTED_NOTIFICATIONS
        map["promoPermission"] = if (Build.VERSION.SDK_INT >= 33) {
            checkSelfPermission("android.permission.POST_PROMOTED_NOTIFICATIONS") ==
                PackageManager.PERMISSION_GRANTED
        } else true
        val nm = getSystemService(NotificationManager::class.java)
        if (nm == null) {
            map["canPost"] = null
            return map
        }
        // 系统是否允许本应用发布提升通知（用户在设置里可关闭）
        map["canPost"] = try {
            nm.javaClass.getMethod("canPostPromotedNotifications").invoke(nm) as? Boolean
        } catch (_: Throwable) {
            null
        }
        var active = 0
        var promoted = 0
        var promotable = 0
        var lastTitle: String? = null
        try {
            val acts = nm.activeNotifications
            active = acts.size
            val flagPromoted = try {
                Class.forName("android.app.Notification")
                    .getField("FLAG_PROMOTED_ONGOING").getInt(null)
            } catch (_: Throwable) {
                0
            }
            for (sbn in acts) {
                val n = sbn.notification
                if (flagPromoted != 0 && (n.flags and flagPromoted) != 0) promoted++
                try {
                    if (n.javaClass.getMethod("hasPromotableCharacteristics")
                            .invoke(n) as? Boolean == true
                    ) promotable++
                } catch (_: Throwable) {
                }
                lastTitle = n.extras?.getCharSequence("android.title")?.toString() ?: lastTitle
            }
        } catch (_: Throwable) {
        }
        map["activeCount"] = active
        map["promotedCount"] = promoted
        map["promotableCount"] = promotable
        map["lastTitle"] = lastTitle
        return map
    }

    /** 跳转系统「实时更新」设置页（Android 16；失败回退到本应用通知设置）。 */
    private fun openPromotedSettings(): Boolean {
        try {
            val intent = Intent("android.settings.MANAGE_APP_PROMOTED_NOTIFICATIONS")
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
            return true
        } catch (_: Throwable) {
        }
        return try {
            val intent = Intent("android.settings.APP_NOTIFICATION_SETTINGS")
            intent.putExtra("android.provider.extra.APP_PACKAGE", packageName)
            startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
