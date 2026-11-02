package icu.wxxydouge.wxxy_pocket

import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.app.AlarmManager
import android.content.Context
import android.provider.Settings
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

        // 2026-10-26：小组件「精确倒计时」权限桥 ——
        // Android 12+ 的 SCHEDULE_EXACT_ALARM 在 14+ 默认不授予，
        // 倒计时每分钟刷新依赖它；这里给 Flutter 一个「查状态 + 跳系统设置」的入口。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wxxy/widget_alarm")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canScheduleExact" -> {
                        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                                am.canScheduleExactAlarms()
                            else true
                        )
                    }
                    "requestExact" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            try {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                        Uri.parse("package:$packageName")
                                    )
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 2026-11-01：稳定的设备标识桥 —— 只给「重装后还是同一台设备」用。
        //
        // 背景：安装标识原先由 Dart 侧纯随机生成、只存在本机安全存储，卸载即清空，
        //     于是用户每重装一次，控制台就多出一台「新设备」，还会累积多设备风控。
        // ANDROID_ID（Settings.Secure.ANDROID_ID）从 Android 8 起是
        //     「应用签名 + 设备 + 用户」三元组的哈希，免权限、重装不变，
        //     正好只解决「同一台机器」的问题，不涉及任何个人信息。
        // 取不到（极少数 ROM）时返回 null，Dart 侧会退回原来的随机方案。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xiyuan/device_id")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidId" -> result.success(
                        try {
                            Settings.Secure.getString(
                                contentResolver, Settings.Secure.ANDROID_ID
                            )
                        } catch (_: Throwable) {
                            null
                        }
                    )
                    else -> result.notImplemented()
                }
            }

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
