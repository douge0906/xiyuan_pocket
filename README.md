<div align="center">

# 掌上锡院 · Pocket

**无锡学院非官方校园助手** · 纯客户端 · 无服务器 · 永久开源

Flutter 3.24.3 · Android arm64 · MIT License

</div>

---

## 这是什么

一个给无锡学院学生用的工具 App。**没有自建服务器**：账密只存你手机本地，
App 在设备上直接与学校系统通信（统一身份认证 CAS / 正方教务 / 融合门户），
不经过任何第三方服务器，也不上传任何个人数据。

> 包名 `icu.wxxydouge.wxxy_pocket`（App 显示名「掌上锡院」）。
> 这是一个**独立 App**，与作者的其它项目不共数据、不共包名。

## 功能

| 功能 | 说明 |
|---|---|
| 课程表 | 教务导入 / 手动添加 / 桌面小组件 |
| 成绩 / 考试 / 教材 | 按学期查询，本地缓存，拉取失败不覆盖旧数据 |
| 一卡通 / 电费余额 | 走融合门户，显示在服务页顶部 |
| 教务处公告 / 校园资讯 | 内置快照：首次打开即有内容，之后联网刷新 |
| 校历 / 校园地图 | 离线内置 |
| 上课提醒 | 本地通知，无推送服务 |

## 项目结构

```
lib/
├── main.dart / app.dart        # 入口与外壳（导航、主题）
├── version.dart                # 版本号（与 pubspec.yaml 保持同步）
├── pages/                      # 页面：首页 / 课表 / 消息 / 我的
│   ├── tools/                  #   成绩 · 考试 · 教材 · 校历 · 地图
│   ├── course/ home/ user/ message/   # 页面片段（卡片、表单）
│   └── ...
├── services/                   # 本地数据 / 通知 / 登录闸门 / 退出清数据
│   └── campus/                 # ★ 与学校系统交互的全部实现
│                               #   cas_client 登录 · captcha_solver 验证码
│                               #   jwgl_client 教务(成绩/考试/课表/教材)
│                               #   card_balance 一卡通 · 公告/资讯
├── models/ providers/ widgets/ theme/
└── version.dart
third_party/                    # flutter_local_notifications 源码副本（见下）
test/                           # 单元测试（flutter test）
```

## 构建

环境：Flutter **3.24.3**（Dart 3.5.3）· JDK 17+ · Android SDK 35 · AGP 8.7.0

```bash
flutter pub get
flutter run                                            # 真机调试
flutter test                                           # 单元测试
flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

> 也可以不本地构建：每次 push 后，GitHub Actions 会自动跑检查、测试并构建 APK
> （在 Actions 页面的 Artifacts 里下载）。

### 关于 release 签名

仓库**不含**签名文件（`android/key.properties` 与 `*.jks` 均被 .gitignore 排除）：

- 维护者本地有这两个文件 → release 包自动用正式签名；
- 贡献者 clone 后没有 → **自动回退 debug 签名**，`flutter build apk --release` 可直接构建成功。

### 关于 `third_party/`

`flutter_local_notifications` 以**源码副本**（path 依赖）锁在 19.5.0，
避免上游升级悄悄改变通知行为。升级前请完整回归「上课提醒」全链路。

## 登录测试

需要能访问 `jwgl.cwxu.edu.cn` 的网络（校园网内最稳），并用无锡学院统一认证账号（学号 + 密码）登录。
账号密码只存在本机 secure storage；退出登录时全部清除。

## 版本号（唯一真相源）

**只改一处：`pubspec.yaml` 的 `version:`**（形如 `1.0.0+1`，`+` 前是版本名、后是构建号）。

- Android 侧由 Gradle 自动取（`flutter.versionName` / `flutter.versionCode`），**无需手写**；
- App 内显示的版本号由 `package_info_plus` **运行时从编译产物读取**，因此不存在"手写副本与 pubspec 不一致"的问题。

## 获取安装包

开源版**不自建服务器/CDN 分发**，构建产物直接从 GitHub 拿：

1. 打开仓库的 **Actions** 页面 → 最近一次成功的 `CI` 运行；
2. 在 **Artifacts** 区下载 `xiyuan-pocket-release-apk`（保留 90 天）；
3. 或者自己 clone 后本地构建（见上）。

## 贡献

欢迎 Issue / PR。提交前请跑：

```bash
flutter analyze lib   # 期望 No issues found
flutter test          # 期望全部通过
```

> 注：与学校系统交互的功能（成绩/考试/教材/一卡通）需要在校园网环境下真机验证。

## 许可证

[MIT](LICENSE)
