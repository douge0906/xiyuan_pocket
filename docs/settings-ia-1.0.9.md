# 设置页信息架构（v1.0.9）

> 依据：`lib/pages/settings_page.dart`（801 行，5 个顶层区块）、
> `lib/pages/display_settings_page.dart`（650 行）、`lib/pages/service_settings_page.dart`（236 行）、
> `lib/services/ui_prefs.dart`（145 行）、`lib/services/app_locale.dart`（200 行）。
> 本次只做「任务四 / 任务五」：界面与显示总入口 + 交互形态纠正 + 振动 + 语言。

## 0. 三条口径（先定，后面照做）

1. **「通用设置」是容器，不是平铺开关。** 字体、字号、振动强度放在它内部，由一个入口进去。
2. **「折叠」= 就地下拉，不是弹窗、不是胶囊换行。** 点最右侧当前值 → 行下方直接向下延伸出竖直候选列表 → 选中即收。
3. **「动效强度」其实是振动强度。** 右侧只留一个按钮，点一下切下一档，档位自带试震。

## 1. 信息架构树

```
设置
├─ 通知与提醒                         （保留，不动）
│   ├─ 通知提醒            › 子页面   值：已开启 / 未开启
│   ├─ 课程提醒            › 子页面   值：—
│   └─ 消息设置            › 子页面   值：—
│
├─ 界面与显示                         ★ 新顶层项（吸收旧「通用设置」+「外观与个性化」两个区块）
│   ├─ 外观与个性化        › 子页面   值：跟随系统
│   │   ├─ 明暗模式          分段选择器（3 项：浅色 / 深色 / 跟随系统）
│   │   ├─ 主题色            色板行（7 预设 + 自定义取色盘）
│   │   ├─ 背景色            色板行（浅色 / 深色两套预设 + 自定义）
│   │   ├─ 圆角              滑杆（直角 ↔ 圆润，28 档）
│   │   ├─ 底部导航        › 子页面
│   │   ├─ 首页板块        › 子页面
│   │   ├─ 课表个性化      › 子页面（跳课表 Tab）
│   │   └─ 恢复默认外观      行内按钮（危险色 + 二次确认，作用域仅本页 4 项）
│   ├─ 通用设置            › 子页面   值：18 号 · 系统默认
│   │   ├─ 字体              就地展开选择（系统默认 / 衬线（宋体）/ 等宽）
│   │   ├─ 字号              步进器 − 18 +（14–24，页脚保留实时预览块）
│   │   └─ 振动强度          单按钮循环档（关闭 → 轻 → 强 → 极强 → 关闭）
│   ├─ 语言                  就地展开选择  值：中文 / English
│   └─ 服务管理            › 子页面   值：已显示 N / 总数 M
│
├─ 数据与存储                         （原「数据与服务」改名；服务管理已移出）
│   ├─ 清理缓存             行内动作   值：12.3 MB
│   └─ 清除所有数据与登录状态  行内动作（危险色）
│
├─ 帮助与关于                         （保留，不动）
│   ├─ 意见反馈             行内动作（弹窗）
│   ├─ 隐私政策            › 子页面
│   ├─ 用户协议            › 子页面
│   ├─ 联系 / 投诉邮箱      行内动作（mailto）
│   └─ 检查更新            › 动作     值：v1.0.9
│
├─ 退出登录                          整宽按钮（卡片外壳 + 危险色）
└─ ICP 备案号
```

### 1.1 交互形态 → 组件对照

| 形态 | 用在哪 | 落地 |
| --- | --- | --- |
| 就地展开选择 | 字体、语言 | 改造现有 `_expander`：`Wrap` 胶囊 → 竖直 `Column`；chevron `›` → `⌄`（展开时旋转 180°） |
| 滑杆 | 圆角 | 现有 `_slider` 原样搬 |
| 步进器 | 字号 | 现有 `_stepper` 原样搬 |
| 子页面 | 外观与个性化 / 通用设置 / 服务管理 / 底部导航 / 首页板块 / 课表个性化 / 通知三页 / 法务两页 | `MaterialPageRoute` push |
| 开关 | 服务管理每行（整行点击切换） | 现有 `_toggle` |
| 分段选择器 | 明暗模式 | 现有 `_modePill` 三连，唯一不对齐「下拉」规则的一项：3 个带图标选项一屏读得完，下拉反而多一步 |
| 色板行 | 主题色、背景色 | 现有 `colorDot` + 自定义点 |

### 1.2 就地下拉的硬规格（这是上一轮理解错的地方）

- 触发热区 = **整行**（图标 + 标题 + 当前值 + 箭头），不是只有「中文」两个字。
- 展开体缩进 48，竖直列表，每项高 44，左文案右 `check_rounded`；**不是** `Wrap` 换行胶囊。
- 选中一项 → 写入 + 立即收起（不要用户再点一次行；这是他明确说的「直接向下延伸出来」）。
- **同时只允许一个下拉展开**：`_fontOpen` / `_langOpen` 两个 bool 合成一个 `_openSelector` 枚举，开新的自动收旧的。
- 过渡仍用 `AnimatedSize`（`AppTheme.durBase` + `curveStandard`），收起态保持 `SizedBox(width: double.infinity)` 撑宽。

## 2. 合并 / 删除 / 保留

### 2.1 合并

| # | 合并 | 理由 |
| --- | --- | --- |
| M1 | 旧顶层区块「外观与个性化」（4 个入口）+ 旧二级页「界面与显示」（8 项外观）→ 一页「外观与个性化」 | 同一批视觉设置被拆在两个地方，改一套外观要跑两处 |
| M2 | 旧顶层区块「通用设置」(字体/字号/语言/动效/清理缓存) → 「通用设置」子页，只留字体 / 字号 / 振动强度 | 它本来就是容器；缓存不属于「通用」 |
| M3 | 「服务管理」：数据与服务 → 界面与显示 | 用户明确要求并入 |
| M4 | 「清理缓存」+「清除所有数据与登录状态」→ 同一张「数据与存储」卡片 | 一强一弱两个清理动作放一起才看得懂区别 |
| M5 | 「语言」：通用设置内部 → 界面与显示直属行 | 语言失效是 1.0.9 头号问题；它必须在自己那一层可见，而不是点进通用设置才找得到 |
| M6 | 命名统一：「首页个性化」（display_page）与「首页板块」（settings_page）是同一页 → 统一叫「首页板块」 | 同一个页面两个名字 |

### 2.2 删除

| 位置 | 删什么 | 为什么 |
| --- | --- | --- |
| `display_settings_page.dart:97-113` | `_applyTextScale` / `_applyMotion` / `_applyHaptics` | 与 settings_page 重复，同一设置两个真源 |
| `display_settings_page.dart:363-431` | 「字体大小（含实时预览）」/「语言」/「动效强度」/「振动反馈」四行 | 冗余项，用户点名要删 |
| `display_settings_page.dart:29-32, 47-55` | `_textScale` / `_motion` / `_haptics` 三个本地 state + initState 三次 load | 双源，退出页面就失配 |
| `display_settings_page.dart:149-160` | `_resetAppearance()` 里 textScale / motion / haptics 三项复位 | 已不归本页管，作用域缩到 4 项 |
| `settings_page.dart:395-412` | `_motionSegments()` 四胶囊 | 换成单按钮循环档 |
| `settings_page.dart:82-84` | `_fontOpen` / `_langOpen` | 合成单值 `_openSelector` |
| `settings_page.dart:519-525, 580-600` | 「通用设置」里的「清理缓存」行 + 「数据与服务」区块外壳 | 内容分别迁到「数据与存储」和「界面与显示」 |
| `app_locale.dart` | `display_font` / `display_motion` / `display_haptic` 三键 | 对应行已删（`display_lang` 保留给语言行） |

### 2.3 保留（一行不改）

- `service_settings_page.dart` 整页：`ReorderableListView` 拖动排序 + 整行开关 + 底部计数，只换入口不改内容。
- 字号步进器：14–24 区间、18 号锚点、`UiPrefs.scaleForFontSize` 反推。
- 圆角滑杆（28 档）、主题色/背景色色板、自定义取色盘。
- 底部导航 / 首页板块 / 课表个性化 三个子页面。
- 通知提醒 / 课程提醒 / 消息设置 三页与入口。
- 帮助与关于 5 项、退出登录按钮外壳（`Ink` + `cardColor` + 圆角阴影）、ICP 备案号与 `SafeArea`。

## 3. 非 IA 但必须同批修的（任务四的两条）

### 3.1 振动：为什么「极强也太弱」，怎么做到「所有点击」

**证据**
- 全仓只有 3 处 `Pressable(haptic: true)`：`lib/app.dart:609`、`lib/pages/home/home_widgets.dart:47`、`:128`。
- 其余约 200 个 `InkWell` / `TextButton` / `GestureDetector` 没有自建触感。
- 但 `InkWell` 默认 `enableFeedback: true`，点击会走 `Feedback.forTap` → Android 上是 `HapticFeedback.vibrate()` = 系统 `LONG_PRESS` 常量。多数 ROM 把它实现成极轻一下，且受系统「触摸振动」总开关支配。**这就是「所有点击都弱」的真实来源，和我们自己的档位无关。**
- `HapticFeedback.heavyImpact()` 同样只映射系统 haptic 常量，拿不到「强」的幅度。

**修法**
1. `android/app/src/main/kotlin/icu/wxxydouge/wxxy_pocket/MainActivity.kt` 新增 `xiyuan/haptics` channel：`tap(level)` → `Vibrator.vibrate(VibrationEffect.createOneShot(ms, amplitude))`。档位：轻 15ms/80、强 25ms/160、极强 40ms/255（API < 26 退回 `vibrate(ms)`）。`VIBRATE` 权限已声明（`AndroidManifest.xml:13`），无需新增。
2. 新增 `lib/services/haptics.dart`：`Haptics.tap()` 读 `UiPrefs.hapticLevel`，Android 走 channel，其它平台 fallback `HapticFeedback`。
3. 全局入口：新建 `AppInkWell`（`InkWell(enableFeedback: false)` + tap 前调 `Haptics.tap()`），替换设置链路各页的 `InkWell`；`pressable.dart:42` 改为调 `Haptics.tap()` 且去掉 `haptic` 布尔开关。
4. `ui_prefs.dart`：新增 `static int hapticLevel = 3`（默认极强）+ `setHapticLevel(int)` + 持久化；`setMotionLevel()` 不再兼职震动，`motionChoices[i].$3` 那一列废弃。

### 3.2 语言：为什么切英文不全局

**证据**
- `AppLocale.setLanguage` 只做 `notifier.value++`；监听者只有 `lib/app.dart:136`（底栏）和 `lib/pages/home_page.dart:106`（首页）。
- 全仓 `S.t(` 只有 34 处、集中在 5 个文件；中文字面量 **1888 条**。设置页 / 界面与显示之外的服务管理、首页板块、底部导航、消息设置、课程提醒 全部 0 处 `S.t()`。

**修法（两刀，可分批交付）**
1. 立即生效：`lib/main.dart:211` 的 `builder` 里给 `child` 包 `KeyedSubtree(key: ValueKey(AppLocale.current.code))`，换语言强制整树重建 —— 已翻译部分立刻生效，不再依赖各页自己监听。
2. 覆盖面：`app_locale.dart` 的 strings 表补到「设置页 + 外观与个性化 + 通用设置 + 服务管理 + 我的页 + 底栏 + 通知三页」，键名按 `set_*` / `display_*` 成组。
3. 英文下未覆盖的页面继续显示中文（不做半句中英混排），语言行右侧值显示 `English (Beta)`。若 1.0.9 不做第 2 步，就只做第 1 步并把 English 从候选里摘掉（Enum 保留，UI 不列）。

## 4. 验收清单

1. 设置页首屏只有 4 个区块，`界面与显示` 之下能直接看到 外观与个性化 / 通用设置 / 语言 / 服务管理 四行，语言行右侧就是「中文」。
2. 点「字体设置」行 → 下方**竖直**出现 3 个候选、带勾选、缩进 48；选中即收；此时点「语言」行，字体下拉自动收起。
3. 振动强度行只有一个按钮，连点 4 次回到「关闭」，每档都有可分辨的强弱；「极强」在真机上明显重于「轻」。
4. 任意页面点任意可点元素（tab、卡片、列表行、按钮）都有同强度触感。
5. 切 English 后：设置页、界面与显示、通用设置、服务管理、我的页、底栏 全部英文；来回切 3 次不残留中文标题，也不出现空白页。
6. 明暗模式 / 主题色 / 背景色 / 圆角 只在「外观与个性化」一页，设置页与其它页不再有第二份。
