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

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        TodayWidgetRenderer.updateAll(context, widgetSize)
        // v2.2.14 精准切换：更新后排下一个闹钟（下一节课切换瞬间刷新）
        TodayWidgetRenderer.scheduleAlarmIfAny(context)
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        TodayWidgetRenderer.updateAll(context, widgetSize)
        TodayWidgetRenderer.scheduleAlarmIfAny(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        // 全部组件移除后取消闹钟，避免空转
        if (!TodayWidgetRenderer.isWidgetInstalled(context)) {
            WidgetAlarmScheduler.cancel(context)
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