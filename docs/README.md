# docs 目录索引

这个目录只放**给开发者看的东西**：结构说明、改造依据、界面截图。
面向用户的安装与功能说明在仓库根目录的 [README](../README.md)。

## 有什么

| 文件 | 是什么 | 什么时候看 |
|---|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 一页纸架构：分层、改 X 要动 Y、7 条会出 bug 的约定、已知债务、构建发布链路 | **动手改代码前先看这个** |
| [settings-ia-1.0.9.md](settings-ia-1.0.9.md) | 设置页信息架构的设计依据（已落地，留档查「为什么这么排」） | 要再动设置页时 |
| `shots/` | 7 张界面截图，540×1101，2026-10-08 版本 | 改 UI 前对一眼现状 |

## 截图

| 文件 | 界面 |
|---|---|
| [01-schedule.jpg](shots/01-schedule.jpg) | 课表（全屏背景 + 多配色） |
| [02-today.jpg](shots/02-today.jpg) | 首页（待办优先工作台） |
| [03-message.jpg](shots/03-message.jpg) | 消息（公告 + 校本资讯） |
| [04-grade.jpg](shots/04-grade.jpg) | 成绩查询 |
| [05-textbook.jpg](shots/05-textbook.jpg) | 教材中心 |
| [06-service.jpg](shots/06-service.jpg) | 服务页 |
| [07-login.jpg](shots/07-login.jpg) | 登录 |

## 不在这里的东西

- **规则源**（R1–R16、每轮三件事、发版流程）：在本机 `xiyuan_ops` 仓库的 `AGENTS.md`，
  那是唯一真相，本仓库**不复制**一份（复制出去就会漂）。
- **现状快照 / 流水账**：`xiyuan_ops` 的 `STATE.md`、`LOG.md`、`CHANGELOG.md`。
- **接口文档**：`lib/services/api_service.dart` 与 `lib/constants/control_config.dart`
  就是唯一真相，本目录不再另记一份。
