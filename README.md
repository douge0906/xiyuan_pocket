<div align="center">

# 掌上锡院

**无锡学院非官方校园助手** · 纯客户端 · 无服务器 · 永久开源

Flutter 3.24.3 · Android arm64 · MIT License

</div>

---

## 这是什么

给无锡学院学生用的工具 App。**没有自建服务器**：账密只存你手机本地，
App 在设备上直接与学校系统通信（统一身份认证 CAS / 正方教务 / 融合门户），
不经过任何第三方服务器，也不上传任何个人数据。

- 包名 `icu.wxxydouge.wxxy_pocket`，App 显示名「掌上锡院」
- 仓库地址：<https://github.com/douge0906/xiyuan_pocket>

## 功能

| 功能 | 说明 |
|---|---|
| 课程表 | 教务导入 / 手动添加 / 桌面小组件 |
| 成绩 · 考试 · 教材 | 按学期查询，本地缓存，拉取失败不覆盖旧数据 |
| 一卡通 · 电费余额 | 走融合门户，显示在服务页顶部 |
| 教务处公告 · 校园资讯 | 内置快照：首次打开即有内容，之后联网刷新 |
| 校历 · 校园地图 | 离线内置 |
| 上课提醒 | 本地通知，无推送服务 |

## 项目的组织方式

```
lib/
├── main.dart / app.dart      入口与外壳（导航、主题）
├── pages/                    页面（首页 / 课表 / 消息 / 服务 / 我的 + tools/）
├── services/campus/          ★ 与学校系统交互的全部实现
│                             （CAS 登录 · 验证码 · 教务 · 一卡通 · 公告）
├── services/                 本地存储、通知、登录闸门、退出清数据
├── models/ providers/ widgets/ theme/
third_party/                  flutter_local_notifications 源码副本（锁版本用）
test/                         单元测试
```

## 构建

环境：Flutter **3.24.3** · JDK 17+ · Android SDK 35

```bash
flutter pub get
flutter run                                            # 真机调试
flutter test                                           # 单元测试
flutter build apk --release --target-platform android-arm64
```

- 不本地构建也行：push 后 GitHub Actions 自动跑检查、测试并构建 APK（Actions → Artifacts 下载）。
- 仓库不含签名文件：维护者本地有则用正式签名，贡献者 clone 后自动回退 debug 签名，可直接构建 release。

## 登录说明

需要能访问 `jwgl.cwxu.edu.cn` 的网络（校园网内最稳），用统一认证账号（学号 + 密码）登录。
账号密码只存本机 secure storage，退出登录时全部清除。

## 贡献

欢迎 Issue / PR。提交前请跑：

```bash
flutter analyze lib   # 期望 No issues found
flutter test          # 期望全部通过
```

> 与学校系统交互的功能（成绩/考试/教材/一卡通）需在校园网环境下真机验证。

更详细的架构与改动指引见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 许可证

[MIT](LICENSE)
