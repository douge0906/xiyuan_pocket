package icu.wxxydouge.wxxy_pocket.widget

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import icu.wxxydouge.wxxy_pocket.MainActivity

/**
 * 小组件点击 → 打开 App 的 PendingIntent（2026-11-03）。
 *
 * 🔴 **为什么不用 `HomeWidgetLaunchIntent.getActivity()`**：
 * home_widget 0.7.0 的实现里 `requestCode` 恒为 `0`，且 flags 带
 * `FLAG_UPDATE_CURRENT`。Android 对 `PendingIntent` 的同一性判定是
 * `(requestCode, Intent 的 action/data/component)` —— 但 `FLAG_UPDATE_CURRENT`
 * 会把已存在的 pi 的 extras 覆盖掉。本 App 有 5 个小组件（小/中/大课表、
 * 考试、校园卡），它们共用同一 action、同一组件、同一 requestCode，
 * 于是**最后被创建的那个会覆盖前面所有**：点考试组件也可能落到课表页。
 *
 * 这里给每类组件分配独立 `requestCode`，各自持有自己的 `data` URI，
 * 互不覆盖。action 仍沿用 home_widget 的
 * `es.antonborri.home_widget.action.LAUNCH`，保证 Dart 侧
 * `HomeWidget.initiallyLaunchedFromHomeWidget()` / `widgetClicked` 照常收到。
 */
object LaunchIntents {

    private const val ACTION_LAUNCH = "es.antonborri.home_widget.action.LAUNCH"

    /** 每类组件一个独立 requestCode，避免 PendingIntent 互相覆盖。 */
    private const val RC_SCHEDULE = 1001
    private const val RC_EXAM = 1002
    private const val RC_CARD = 1003
    private const val RC_COUNTDOWN = 1004

    fun schedule(context: Context): PendingIntent =
        build(context, Uri.parse("homewidget://course"), RC_SCHEDULE)

    fun exam(context: Context): PendingIntent =
        build(context, Uri.parse("homewidget://exam"), RC_EXAM)

    fun card(context: Context): PendingIntent =
        build(context, Uri.parse("homewidget://card"), RC_CARD)

    /** 倒数日组件（2026-11-04 新增）：点开直达倒数日管理页。 */
    fun countdown(context: Context): PendingIntent =
        build(context, Uri.parse("homewidget://countdown"), RC_COUNTDOWN)

    /**
     * 倒数日组件的**某一格**（2026-11-05，用户 m24495 #3）。
     *
     * 🔴 requestCode 必须随 slot 变化：PendingIntent 的同一性判定只看
     * `(requestCode, action, data, component)`，而 `FLAG_UPDATE_CURRENT`
     * 会把已存在的 pi 覆盖掉。三格共用 RC_COUNTDOWN 的话，
     * 最后创建的那格会吃掉另外两格 —— 点哪一格都进同一个槽位。
     */
    fun countdownSlot(context: Context, slot: Int): PendingIntent =
        build(
            context,
            Uri.parse("homewidget://countdown?slot=$slot"),
            RC_COUNTDOWN + 10 + slot.coerceIn(0, 1),
        )

    private fun build(context: Context, uri: Uri, requestCode: Int): PendingIntent {
        // 🔴 2026-11-03 修「小组件点击后进不去 App」：必须显式建 task + 清空
        //   单例栈的回退。只给 action/data 而让系统按 launchMode 猜，
        //   在 launcher 已把 App 留在后台时会出现「复用了旧 task，但
        //   surface 是空的」——用户看到的就是点了没反应 / 白屏。
        //   NEW_TASK 保证从桌面（非 Activity 上下文）能起 Activity，
        //   CLEAR_TOP + SINGLE_TOP 让已启动时走 onNewIntent 而不是再开一份。
        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_LAUNCH
            data = uri
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return PendingIntent.getActivity(context, requestCode, intent, flags)
        }
        // 🔴 2026-11-05：这段曾经把四个组件同时打挂，别再改回去。
        //
        // 真机报错（组件自检页原文）：
        //   IllegalArgumentException:
        //   pendingIntentBackgroundActivityStartMode must not be set when
        //   creating a PendingIntent
        //
        // 根因：`setPendingIntentBackgroundActivityStartMode` 是**启动方**
        // （sender）语义，只有 launcher 这种「去启动别人的 PendingIntent」
        // 的一方才能设。我们是**创建方**（creator），在创建时就设它会被
        // 系统直接拒绝。两个 setter 名字只差一个词，抄错不报错、编译照过，
        // 到运行时才炸，而且炸在「构造 PendingIntent」这一步 —— 于是点击
        // 没挂上、RemoteViews 整份被丢、桌面停在组件自带的默认文字上。
        //
        // 这也是 home_widget 0.7.0 的上游 bug（ABausG/home_widget#328），
        // 2025-02-06 由 PR #330 修复、进 0.8.0；本仓锁的还是 0.7.0，
        // 所以插件那条路径同样会炸，不能靠「换回插件」躲开。
        //
        // 正确写法（与上游修复一致）：
        //   SDK >= 35 → creator 语义
        //   SDK 34    → sender 语义（那一版系统还接受）
        val options = ActivityOptions.makeBasic()
        if (Build.VERSION.SDK_INT >= 35) {
            options.setPendingIntentCreatorBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
            )
        } else {
            @Suppress("DEPRECATION")
            options.pendingIntentBackgroundActivityStartMode =
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
        }
        return PendingIntent.getActivity(context, requestCode, intent, flags, options.toBundle())
    }
}
