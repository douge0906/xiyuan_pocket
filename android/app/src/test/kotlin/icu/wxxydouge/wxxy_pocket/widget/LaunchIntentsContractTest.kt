package icu.wxxydouge.wxxy_pocket.widget

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 2026-11-05：把「PendingIntent 的 ActivityOptions 语义」钉成一条源码级契约。
 *
 * 背景（真机报错，组件自检页原文）：
 *   IllegalArgumentException:
 *   pendingIntentBackgroundActivityStartMode must not be set when creating a PendingIntent
 *
 * 两个 setter 名字只差一个词（sender vs creator），**编译都过、运行时才炸**，
 * 所以 analyze / 编译 / 常规单测全都发现不了。这条测试直接读源码文本，
 * 是这类「API 语义误用」在没有真机时唯一可行的护栏。
 *
 * 上游同坑：ABausG/home_widget#328，2025-02-06 由 PR #330 修复（进 0.8.0）。
 */
class LaunchIntentsContractTest {

    private fun source(): String {
        // 从模块根（app/）定位源文件；Gradle 的 working dir 是 app/。
        val f = File("src/main/kotlin/icu/wxxydouge/wxxy_pocket/widget/LaunchIntents.kt")
        assertTrue("读不到 LaunchIntents.kt：${f.absolutePath}", f.exists())
        return f.readText()
    }

    /** 去掉注释，避免「注释里提到旧写法」被误判为又写错了。 */
    private fun codeOnly(src: String): String =
        // 先整块去掉 /* ... */ 与 KDoc /** ... */（行首是 ` *` 不是 `//`），
        // 再去行内 // 注释。否则文档里提到 API 名就会被当成又写错了。
        Regex("""/\*[\s\S]*?\*/""").replace(src, "")
            .lineSequence()
            .map { line ->
                val i = line.indexOf("//")
                if (i >= 0) line.substring(0, i) else line
            }
            .joinToString("\n")

    @Test
    fun `SDK35 分支必须用 creator 语义`() {
        val src = codeOnly(source())
        assertTrue(
            "SDK>=35 必须走 setPendingIntentCreatorBackgroundActivityStartMode",
            src.contains("setPendingIntentCreatorBackgroundActivityStartMode"),
        )
    }

    @Test
    fun `sender 语义只能出现在 SDK34 分支，且必须带版本闸门`() {
        val lines = codeOnly(source()).lines()
        val hits = lines.filter {
            it.contains("pendingIntentBackgroundActivityStartMode") &&
                !it.contains("setPendingIntentCreatorBackgroundActivityStartMode")
        }
        // 只允许剩下一处：SDK34 的赋值语句。
        assertTrue(
            "sender 写法出现了 ${hits.size} 次，应只有 SDK34 分支那一处：$hits",
            hits.size == 1,
        )
        // 那一处的上面必须有 else（即 SDK<35 的分支）。
        val idx = lines.indexOfFirst { it.contains(hits.first().trim()) }
        val above = lines.subList((idx - 6).coerceAtLeast(0), idx).joinToString("\n")
        assertTrue("sender 分支必须由 SDK 版本闸门挡住：\n$above", above.contains("else"))
    }

    @Test
    fun `四类组件的 requestCode 必须互不相同`() {
        val src = source()
        val codes = Regex("""private const val (RC_\w+) = (\d+)""")
            .findAll(src)
            .associate { it.groupValues[1] to it.groupValues[2].toInt() }
        assertTrue("应当至少有 4 个组件 requestCode，实际：$codes", codes.size >= 4)
        org.junit.Assert.assertEquals(
            "requestCode 不能重复，否则 PendingIntent 会互相覆盖",
            codes.size,
            codes.values.toSet().size,
        )
    }

    @Test
    fun `不能再退回插件的 HomeWidgetLaunchIntent`() {
        // 插件 0.7.0 的实现里 requestCode 恒为 0 + FLAG_UPDATE_CURRENT，
        // 五个组件共用一个 PendingIntent；且它自己也有这条 SDK35 的雷。
        val dir = File("src/main/kotlin/icu/wxxydouge/wxxy_pocket")
        val offenders = dir.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            // 剥掉注释再判：LaunchIntents.kt 的文档注释里本来就要提到这个 API 名。
            .filter { codeOnly(it.readText()).contains("HomeWidgetLaunchIntent.getActivity") }
            .map { it.name }
            .toList()
        assertTrue("这些文件又退回了插件的共享 PendingIntent：$offenders", offenders.isEmpty())
    }

    @Test
    fun `点击不能包在 safe 里静默吞掉`() {
        val src = codeOnly(source())
        assertFalse("LaunchIntents 不该自己吞异常", src.contains("catch (_: Throwable) { }"))
    }
}

