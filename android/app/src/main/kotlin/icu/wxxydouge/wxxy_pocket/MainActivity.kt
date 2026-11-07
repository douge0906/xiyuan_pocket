package icu.wxxydouge.wxxy_pocket

import android.app.NotificationManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.app.AlarmManager
import android.content.Context
import android.provider.Settings
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import icu.wxxydouge.wxxy_pocket.widget.CardWidgetProvider
import icu.wxxydouge.wxxy_pocket.widget.CountdownWidgetProvider
import icu.wxxydouge.wxxy_pocket.widget.ExamWidgetProvider
import icu.wxxydouge.wxxy_pocket.widget.LargeWidgetProvider
import icu.wxxydouge.wxxy_pocket.widget.MediumWidgetProvider
import icu.wxxydouge.wxxy_pocket.widget.SmallWidgetProvider

class MainActivity : FlutterActivity() {

    /// 小组件点击要跳转的目标（`course` / `exam` / `card`），由 Dart 侧拉取。
    ///
    /// 🔴 为什么要在原生侧存一份：home_widget 0.7.0 的
    ///   `HomeWidgetPlugin.onNewIntent` 只做 `receiver?.onReceive(...)`，
    ///   而 `receiver` 只有在 Dart 侧 `HomeWidget.widgetClicked.listen`
    ///   **已经订阅**时才非空。本 App 的订阅建在首帧之后
    ///   （`App._handleWidgetClick` 的 post-frame 回调），所以「App 已在
    ///   后台时点小组件」这条最常用的路径，点击事件会被插件静默吞掉。
    ///   冷启动那条虽然插件能读到 intent，但只要 Flutter 引擎重建过，
    ///   时序同样不可靠。
    ///   这里在原生侧无条件截存 intent，Dart 侧启动后 `getInitialRoute`
    ///   主动来取；消费一次即清空，避免下次冷启动重复跳转。
    private var pendingLaunchRoute: String? = null

    /// 与 Dart 侧约定的通道名（新增，不与既有 4 个通道冲突）。
    private var launchChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 首帧前先把「本次是点小组件进来的」记下来（onCreate 路径没有 onNewIntent）。
        captureLaunchRoute(intent)

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

        // 2026-11-03：桌面小组件「已添加」状态桥 —— 替代 home_widget 的 getInstalledWidgets()。        //
        // 🔴 为什么不用插件那个方法：home_widget 0.7.0 的
        //   HomeWidgetPlugin.getInstalledWidgets() 里，对
        //   AppWidgetManager.getAppWidgetInfo(widgetId) 的返回值**不做判空**就传给
        //   非空形参 widgetInfoToMap(widgetId, widgetInfo)。该 API 文档允许返回 null
        //   （组件正被移除、Launcher 重建的瞬间都会），一旦为 null 就抛
        //   NullPointerException —— 而且抛在平台线程的 MethodChannel handler 里，
        //   Dart 侧 try/catch 根本拦不住，进程直接挂。
        //   症状完美对应「添加小组件后 App 打不开」：没装组件时循环体一次都不进，
        //   装了之后每次启动的页面预热都会走到。
        //
        // 我们其实只需要「三类组件各有没有被添加」，不需要 ProviderInfo，
        // 所以直接查 getAppWidgetIds 是否非空 —— 天然没有 null 风险。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wxxy/widget_status")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installed" -> result.success(installedWidgetKinds())
                    // 2026-11-05（用户 m24495 #3「两者都要」）：从 App 里直接把
                    // 倒数日组件 pin 到桌面，并把选中的条目绑到这个新实例上。
                    //
                    // 系统 8.0+ 才支持 requestPinAppWidget；低版本返回 false，
                    // Dart 侧据此提示「请长按桌面手动添加」。
                    //
                    // ⚠️ 绑定必须先写、再请求 pin：pin 的 success 回调里才拿得到
                    // appWidgetId，但那时系统可能已经开始第一次 onUpdate 了。
                    // 所以用 PendingIntent 的 extras 把 id 列表带给系统，
                    // 系统在 pin 成功后原样回传（这是官方推荐做法）。
                    "pinCountdown" -> {
                        if (android.os.Build.VERSION.SDK_INT < 26) {
                            result.success(false)
                        } else {
                            val mgr = AppWidgetManager.getInstance(this)
                            if (!mgr.isRequestPinAppWidgetSupported) {
                                result.success(false)
                            } else {
                                val slot = (call.argument<Int>("slot") ?: 0).coerceIn(0, 1)
                                val providerClass = if (slot == 1)
                                    icu.wxxydouge.wxxy_pocket.widget.CountdownWidget2Provider::class.java
                                else icu.wxxydouge.wxxy_pocket.widget.CountdownWidgetProvider::class.java
                                val provider = ComponentName(this, providerClass)
                                val ids = (call.argument<List<String>>("ids") ?: emptyList())
                                val callback = android.app.PendingIntent.getBroadcast(
                                    this, 2001 + slot,
                                    android.content.Intent(this, providerClass)
                                        .setAction("icu.wxxydouge.wxxy_pocket.COUNTDOWN_PINNED")
                                        .putExtra("countdownSlot", slot)
                                        .putStringArrayListExtra("bindIds", java.util.ArrayList(ids)),
                                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                                )
                                result.success(mgr.requestPinAppWidget(provider, null, callback))
                            }
                        }
                    }
                    // 2026-11-03：小组件自检。用户反馈「取不到数据」，但所有失败
                    // 都被静默吞掉（Provider.onUpdate 外层 catch(Throwable)、
                    // Dart 侧 catch(_)），界面上看不出任何区别。
                    // 这里把原生侧的真实读数 / 最后一次错误 / 各尺寸安装状态
                    // 一次性交出去，让「没数据」这件事可核对，而不是靠猜。
                    "diagnose" -> result.success(
                        icu.wxxydouge.wxxy_pocket.widget.WidgetDiagnostics
                            .snapshot(this),
                    )
                    // 2026-11-04：**同进程直接渲染**，不走广播。
                    //
                    // 之前唯一的渲染触发是 Dart -> home_widget.updateWidget
                    // -> sendBroadcast(ACTION_APPWIDGET_UPDATE)。广播这一环
                    // 是不可靠的：组件被系统归档 / ROM 拦截隐式广播 / 广播时
                    // 组件 owner 还在恢复，都会让 onUpdate 根本不来。那时桌面
                    // 上显示的就是 initialLayout 的 XML 占位文字 —— 既没有数据，
                    // 也没有 onUpdate 里 setOnClickPendingIntent 打上去的点击
                    // 响应（所以「点又点不了」和「不显示数据」是同一个原因）。
                    //
                    // 这里直接调渲染器 + AppWidgetManager.updateAppWidget，
                    // 并把「每个尺寸真实更新了几个实例」交回去：0 就说明桌面
                    // 上根本没有该尺寸的实例，问题不在渲染。
                    // 🔴 2026-11-05：渲染挪到主线程队列，不在 channel handler 里同步跑。
                    //
                    // 整学期 allCourses 反序列化 + 三尺寸 × N 实例的 RemoteViews 构建
                    // + updateAppWidget 全部同步执行轻松超过 100ms，而它在 App 启动的
                    // `finally` 里被调 —— 首帧必卡，低端机有 ANR 风险。
                    //
                    // 但实例数必须**同步**返回：Dart 侧 `WidgetSyncStatus` 靠它判断
                    // 「App 内自检正常、桌面上却没反应」到底是谁的责任。所以这里
                    // 先查实例数（纯查询，微秒级），再把渲染排进队列。
                    "renderNow" -> {
                        val counts = widgetInstanceCounts()
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            renderAllNow()
                        }
                        result.success(counts)
                    }
                    "clearDiagnostics" -> {
                        icu.wxxydouge.wxxy_pocket.widget.WidgetDiagnostics
                            .clear(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 2026-11-03：小组件点击 → 跳转目标的可靠通道（见 pendingLaunchRoute 注释）。
        //   getInitialRoute  取走并清空（消费一次）
        //   peekRoute        只看不清（热路径二次确认用）
        launchChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wxxy/launch_route")
                .also { channel ->
                    channel.setMethodCallHandler { call, result ->
                        when (call.method) {
                            "getInitialRoute" -> {
                                val r = pendingLaunchRoute
                                pendingLaunchRoute = null
                                result.success(r)
                            }
                            "peekRoute" -> result.success(pendingLaunchRoute)
                            else -> result.notImplemented()
                        }
                    }
                }

        // 2026-11-03：全局点击振动桥。
        //
        // 🔴 为什么不用 Flutter 的 HapticFeedback：它最终落到
        //   `View.performHapticFeedback(HapticFeedbackConstants.*)`，
        //   强度由**系统常量**决定（LONG_PRESS 在多数 ROM 上就是一次极短的
        //   弱震），且受「系统触感反馈」总开关支配 —— 用户在设置里选了
        //   「极强」也只会得到系统那一下。要真正拉开四档，必须自己拿
        //   Vibrator 指定时长与 amplitude。
        //   amplitude 只在 Android 8.0+ 生效，低版本退化成 durationOnly。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xiyuan/haptics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "tap" -> {
                        val level = (call.argument<Int>("level") ?: 0).coerceIn(0, 3)
                        result.success(performHaptic(level))
                    }
                    else -> result.notImplemented()
                }
            }

        // 2026-11-03：省电 / 后台限制诊断桥（任务六「查为什么关闭后台后不提醒」）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xiyuan/power")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(powerStatus())
                    "openBatterySettings" -> result.success(openBatterySettings())
                    "openDndSettings" -> result.success(openDndSettings())
                    "openNotificationSettings" -> result.success(openNotificationSettings())
                    "channelVibration" -> result.success(channelVibration())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // FlutterActivity 只把 intent 交给引擎，插件那条 onNewIntent 又会因为
        // receiver 未订阅而丢掉点击 —— 这里自己兜住，不依赖插件。
        setIntent(intent)
        captureLaunchRoute(intent)
        // 引擎已就绪时主动通知 Dart 侧（冷启动时 Dart 会用 getInitialRoute 取）。
        launchChannel?.invokeMethod("routeChanged", pendingLaunchRoute)
    }

    /**
     * 立刻把三种课表尺寸 + 考试 + 校园卡 + 倒数日全部重画一遍（同进程直调）。
     *
     * 返回每个尺寸**真实更新到的实例数**。0 = 桌面上没有这个尺寸的组件，
     * 这时无论 Dart 写多少数据、无论 onUpdate 有没有被调，桌面都不会变 ——
     * 这是「App 内自检正常、桌面上却没反应」最常见的现场。
     */
    /// 六类组件的桌面实例数。纯查询、微秒级，可以留在 channel handler 里。
    private fun widgetInstanceCounts(): Map<String, Int> {
        val out = mutableMapOf<String, Int>()
        val manager = android.appwidget.AppWidgetManager.getInstance(this)
        fun count(cls: Class<*>): Int = try {
            manager.getAppWidgetIds(android.content.ComponentName(this, cls)).size
        } catch (_: Throwable) {
            0
        }
        out["scheduleSmall"] = count(
            icu.wxxydouge.wxxy_pocket.widget.SmallWidgetProvider::class.java)
        out["scheduleMedium"] = count(
            icu.wxxydouge.wxxy_pocket.widget.MediumWidgetProvider::class.java)
        out["scheduleLarge"] = count(
            icu.wxxydouge.wxxy_pocket.widget.LargeWidgetProvider::class.java)
        out["exam"] = count(
            icu.wxxydouge.wxxy_pocket.widget.ExamWidgetProvider::class.java)
        out["card"] = count(
            icu.wxxydouge.wxxy_pocket.widget.CardWidgetProvider::class.java)
        out["countdown"] = count(
            icu.wxxydouge.wxxy_pocket.widget.CountdownWidgetProvider::class.java)
        out["countdown2"] = count(
            icu.wxxydouge.wxxy_pocket.widget.CountdownWidget2Provider::class.java)
        return out
    }

    private fun renderAllNow(): Map<String, Any> {        val out = mutableMapOf<String, Any>()
        out.putAll(widgetInstanceCounts())
        // 2026-11-04 晚：这四次渲染原来是**一个** try 里的四行 ——
        // 第一个抛异常，后三个直接不执行。四个组件「同时」停在 XML 默认
        // 文字上正是这个形状。现在逐段兜底，并把每一段的结果也回报出去。
        val okMap = mutableMapOf<String, Boolean>()
        fun step(name: String, block: () -> Unit) {
            okMap[name] = try {
                block()
                true
            } catch (t: Throwable) {
                icu.wxxydouge.wxxy_pocket.widget.WidgetDiagnostics
                    .recordError(this, "renderNow.$name", t)
                false
            }
        }
        step("schedule") {
            icu.wxxydouge.wxxy_pocket.widget.TodayWidgetRenderer.updateAll(this)
        }
        step("exam") {
            icu.wxxydouge.wxxy_pocket.widget.InfoWidgetRenderer.updateAll(
                this, icu.wxxydouge.wxxy_pocket.widget.InfoWidgetRenderer.Kind.EXAM)
        }
        step("card") {
            icu.wxxydouge.wxxy_pocket.widget.InfoWidgetRenderer.updateAll(
                this, icu.wxxydouge.wxxy_pocket.widget.InfoWidgetRenderer.Kind.CARD)
        }
        step("countdown") {
            icu.wxxydouge.wxxy_pocket.widget.CountdownWidgetRenderer.updateAll(this, 0)
        }
        step("countdown2") {
            icu.wxxydouge.wxxy_pocket.widget.CountdownWidgetRenderer.updateAll(this, 1)
        }
        out["steps"] = okMap.filterValues { !it }.keys.joinToString(",")
        out["ok"] = okMap.values.all { it }
        out["lastError"] = icu.wxxydouge.wxxy_pocket.widget.WidgetDiagnostics
            .snapshot(this)["lastError"] ?: ""
        return out
    }

    /** 从 intent 里解析小组件点击的目标；不是小组件启动就什么都不做。 */
    private fun captureLaunchRoute(intent: Intent?) {
        if (intent == null) return
        if (intent.action != "es.antonborri.home_widget.action.LAUNCH") return
        val host = intent.data?.host ?: return
        pendingLaunchRoute = when (host) {
            "course" -> "course"
            "exam" -> "exam"
            "card" -> "card"
            // 2026-11-04：倒数日组件的点击目标。之前漏了这一支，
            // `homewidget://countdown` 会落到 else -> null，
            // 于是「点倒数日组件没反应」。
            "countdown" -> "countdown"
            else -> null
        }
    }

    /**
     * 按档位振动一次。
     *
     * 0 = 关闭（不震）、1 = 轻 15ms/80、2 = 强 25ms/160、3 = 极强 40ms/255。
     * amplitude 必须是 1..255，255 是马达上限 —— 「极强」要能明显压过系统
     * 那一下，就必须给满幅 + 最长时长。
     */
    private fun performHaptic(level: Int): Boolean {
        if (level <= 0) return false
        val ms: Long
        val amp: Int
        when (level) {
            1 -> {
                ms = 15L; amp = 80
            }
            2 -> {
                ms = 25L; amp = 160
            }
            else -> {
                ms = 40L; amp = 255
            }
        }
        return try {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                    ?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vibrator == null || !vibrator.hasVibrator()) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createOneShot(ms, amp.coerceIn(1, 255))
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(ms)
            }
            true
        } catch (_: Throwable) {
            // 振动是锦上添花：没有马达 / 被系统禁用都不能影响点击本身。
            false
        }
    }

    /**
     * 省电与后台限制诊断（2026-11-03）。
     *
     * 三件事分别查，任一项抛异常只让它自己为 null，绝不整块失败：
     *  · `ignoringBatteryOptimizations` —— 是否已加入「不受限制」白名单。
     *    被优化时 Doze 会推迟甚至掐掉 AlarmManager 的闹钟，表现就是
     *    「App 在前台提醒正常，锁屏放着就一条都不响」。
     *  · `standbyBucket` —— Android 9+ 的应用待机分桶（10=active / 20=working
     *    set / 30=frequent / 40=rare / 45=restricted）。落到 40/45 时后台
     *    广播与闹钟都会被大幅限制。
     *  · `backgroundRestricted` —— Android 10+ 的「限制后台运行」总闸，
     *    开了之后专门吞后台广播（小组件刷新、提醒都受影响）。
     *
     * 跳转能力单独给：不同 ROM 的电池优化页 action 不一样，这里给一个
     * 有优先级的候选列表，Dart 侧按顺序试，全部失败再退回应用详情页。
     */
    private fun powerStatus(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        val pm = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
        map["ignoringBatteryOptimizations"] = try {
            pm?.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Throwable) {
            null
        }
        map["standbyBucket"] = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // 注意：查自己的待机分桶是 UsageStatsManager.getAppStandbyBucket()，
                // 不在 PowerManager 上（曾经写成 pm.getStandbyBucket() 编译不过）。
                // 查自己不需要任何权限。
                val usm = getSystemService(Context.USAGE_STATS_SERVICE)
                    as? android.app.usage.UsageStatsManager
                usm?.getAppStandbyBucket()
            } else null
        } catch (_: Throwable) {
            null
        }
        map["backgroundRestricted"] = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val am = getSystemService(Context.ACTIVITY_SERVICE)
                    as? android.app.ActivityManager
                am?.isBackgroundRestricted
            } else null
        } catch (_: Throwable) {
            null
        }
        // 勿扰模式（DND）：返回「本应用是否拿到了通知策略访问权」。
        // 拿到了才能读写 DND；没拿到时只能引导用户去系统里开。
        // Android 6.0（API 23）以下没有这个 API，返回 null 表示「读不到」。
        map["dndAccess"] = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                    as? android.app.NotificationManager
                nm?.isNotificationPolicyAccessGranted
            } else null
        } catch (_: Throwable) {
            null
        }
        return map
    }

    /**
     * 打开「电池优化」相关页面。
     *
     * 顺序很讲究：`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 是**能直接弹系统
     * 对话框**的那个（用户点一下「允许」就完成），必须排第一；后面几个是
     * 各家 ROM 的设置页，只能跳过去让用户自己找。全部失败才退到应用详情。
     */
    private fun openBatterySettings(): Boolean {
        val candidates = mutableListOf<Intent>()
        try {
            candidates.add(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                )
            )
        } catch (_: Throwable) {
        }
        candidates.add(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        )
        try {
            candidates.add(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                )
            )
        } catch (_: Throwable) {
        }
        for (intent in candidates) {
            try {
                startActivity(intent)
                return true
            } catch (_: Throwable) {
            }
        }
        return false
    }

    /** 三类桌面小组件是否已添加到桌面（课表 / 考试 / 校园卡）。 */

    /**
     * 读取「上课提醒」渠道当前是否开启振动（2026-11-06）。
     *
     * 为什么需要：Android 8.0+ 的振动开关**在通知渠道里**，用户在本 App
     * 内翻遍设置也找不到「振动」两个字，只会觉得「提醒不震」。这里把渠道
     * 的真实状态读出来，配一行「通知振动 · 已关闭 → 点我去开」。
     *
     * 返回 null = 渠道还没建 / 系统读不到（不当作「已关闭」）。
     */
    private fun channelVibration(): Boolean? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = getSystemService(NotificationManager::class.java)
                nm?.getNotificationChannel("course_reminder_channel_v2")?.shouldVibrate()
            } else null
        } catch (_: Throwable) {
            null
        }
    }

    /** 打开本应用的「通知」系统设置页（里面能看到各渠道的振动开关）。 */
    private fun openNotificationSettings(): Boolean {
        val candidates = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                candidates.add(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    }
                )
            } catch (_: Throwable) {
            }
        }
        try {
            candidates.add(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"))
            )
        } catch (_: Throwable) {
        }
        for (intent in candidates) {
            try {
                startActivity(intent)
                return true
            } catch (_: Throwable) {
            }
        }
        return false
    }

    /**
     * 打开系统的「勿扰模式访问权」页。
     *
     * Android 不允许直接弹授权框拿这个权限，只能跳到
     * ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS 让用户自己开。
     */
    private fun openDndSettings(): Boolean {
        val candidates = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                candidates.add(
                    Intent(
                        android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS
                    )
                )
            } catch (_: Throwable) {
            }
        }
        try {
            candidates.add(
                Intent(
                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                )
            )
        } catch (_: Throwable) {
        }
        for (intent in candidates) {
            try {
                startActivity(intent)
                return true
            } catch (_: Throwable) {
            }
        }
        return false
    }

    private fun installedWidgetKinds(): Map<String, Boolean> {
        val out =
            mutableMapOf("schedule" to false, "exam" to false, "card" to false, "countdown" to false)
        try {
            val manager = AppWidgetManager.getInstance(applicationContext)
            fun has(cls: Class<*>): Boolean = try {
                manager.getAppWidgetIds(ComponentName(this, cls)).isNotEmpty()
            } catch (_: Throwable) {
                false
            }
            out["schedule"] = has(SmallWidgetProvider::class.java) ||
                has(MediumWidgetProvider::class.java) ||
                has(LargeWidgetProvider::class.java)
            out["exam"] = has(ExamWidgetProvider::class.java)
            out["card"] = has(CardWidgetProvider::class.java)
            out["countdown"] = has(CountdownWidgetProvider::class.java)
        } catch (_: Throwable) {
            // 查不到就当作「没添加」，绝不因为一次查询失败把 App 带崩。
        }
        return out
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
