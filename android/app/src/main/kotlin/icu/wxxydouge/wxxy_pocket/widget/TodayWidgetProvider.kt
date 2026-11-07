package icu.wxxydouge.wxxy_pocket.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/** 今日课表小组件基类（v2.2.14 三独立版）。
 *
 * 三个固定尺寸的小部件共用本基类，各自渲染专属布局：
 *  - SmallWidgetProvider  2×1：下一节课
 *  - MediumWidgetProvider 2×2：今日课程单列
 *  - LargeWidgetProvider  4×2：今日课程双列
 * 数据由 Flutter 侧写入 SharedPreferences 后统一刷新。
 */
abstract class BaseScheduleWidgetProvider : AppWidgetProvider() {

    protected abstract val widgetSize: TodayWidgetRenderer.Size

    // 2026-11-04（用户 m20455 #7「小组件闪退」）：
    // 这三个回调跑在**宿主 App 进程**里（AppWidgetProvider 由系统在本应用进程
    // 中实例化），任何未捕获异常都会让整个 App 闪退，而桌面组件只是不刷新 ——
    // 用户看到的现象就是「点一下小组件 App 就崩」。
    // 之前这里一行 try 都没有（v1.0.8 原样），本类改成每个回调独立兜底，
    // 并把异常写进 WidgetDiagnostics，用户进「组件自检」能看到最后错误。
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        // 2026-11-04 晚：原来只有 WidgetBootReceiver 记 tick，Provider 一处都没有，
        // 于是自检页永远显示「从未被系统唤起」，分不清是系统没调过来还是渲染失败。
        WidgetDiagnostics.recordTick(context, "onUpdate($widgetSize)")
        try {
            TodayWidgetRenderer.updateAll(context, widgetSize)
            // v2.2.14 精准切换：更新后排下一个闹钟（下一节课切换瞬间刷新）
            TodayWidgetRenderer.scheduleAlarmIfAny(context)
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "onUpdate($widgetSize)", t)
        }
    }

    override fun onEnabled(context: Context) {
        WidgetDiagnostics.recordTick(context, "onEnabled($widgetSize)")
        try {
            super.onEnabled(context)
            TodayWidgetRenderer.updateAll(context, widgetSize)
            TodayWidgetRenderer.scheduleAlarmIfAny(context)
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "onEnabled($widgetSize)", t)
        }
    }

    override fun onDisabled(context: Context) {
        try {
            super.onDisabled(context)
            // 全部组件移除后取消闹钟，避免空转
            if (!TodayWidgetRenderer.isWidgetInstalled(context)) {
                WidgetAlarmScheduler.cancel(context)
            }
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "onDisabled($widgetSize)", t)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        // 拖动改尺寸后立刻按新高度重排 —— 不加这个，改完格子大小
        // 要等下一次 onUpdate 才变内容（常被 ROM 拖到半小时后）。
        WidgetDiagnostics.recordTick(context, "onOptionsChanged($widgetSize)")
        try {
            TodayWidgetRenderer.updateAll(context, widgetSize)
        } catch (t: Throwable) {
            WidgetDiagnostics.recordError(context, "onOptionsChanged($widgetSize)", t)
        }
    }
}

/** 小号（2×1）：下一节课。 */
class SmallWidgetProvider : BaseScheduleWidgetProvider() {
    override val widgetSize = TodayWidgetRenderer.Size.SMALL
}

/** 中号（2×2）：今日课程单列。 */
class MediumWidgetProvider : BaseScheduleWidgetProvider() {
    override val widgetSize = TodayWidgetRenderer.Size.MEDIUM
}

/** 大号（4×2）：今日课程双列。 */
class LargeWidgetProvider : BaseScheduleWidgetProvider() {
    override val widgetSize = TodayWidgetRenderer.Size.LARGE
}