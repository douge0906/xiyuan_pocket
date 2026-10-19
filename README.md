<div align="center">

# 掌上锡院

**无锡学院校园助手**（非官方）

开源的校园工具：课表、成绩、待办、日历装在一起。

Android · Flutter · MIT License

</div>

---

## 简介

给无锡学院同学用的校园工具。把每天要看的几件事——今天上什么课、哪些作业要交、
考试还有几天——放在一个地方，打开就能看到。

## 功能

| 板块 | 内容 |
|---|---|
| **课程表** | 教务导入、手动添加、桌面小组件、上课提醒、多套配色与布局 |
| **待办** | 快速添加、今天 / 之后 / 逾期分组、重复任务（每天、每周几）、到期倒计时 |
| **待办日历** | 月视图按待办数量显示深浅，点日期直接看当天清单 |
| **成绩 · 考试 · 教材** | 按学期查询，本地缓存，换网络也不丢 |
| **一卡通 · 电费** | 融合门户余额，显示在服务页顶部 |
| **校历 · 校园地图** | 内置，离线可用 |
| **外观** | 深色模式、主题色、字体大小、首页板块自由组合 |

## 安装

下载 APK 直接安装（arm64，Android 8 及以上）。

## 构建

环境：Flutter **3.24.3** · JDK 17+ · Android SDK 35

```bash
flutter pub get
flutter run
flutter test
flutter build apk --release --target-platform android-arm64
```

推送代码后 GitHub Actions 会自动跑检查和测试，产物在 Actions → Artifacts。

## 开发

提交前请跑：

```bash
flutter analyze lib
flutter test
```

更细的架构说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 登录

使用学校统一认证账号（学号 + 密码）登录。账号密码保存在手机本地安全存储，
退出登录时一并清除。

## 许可证

[MIT](LICENSE)
