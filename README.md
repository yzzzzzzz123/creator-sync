# Creator Sync

本人小红书发布内容 → Bilibili / YouTube 的本机同步项目。用 Windows 原生 RPA 读取和操作已登录的 Chrome，账号登录与验证码由本人完成。

已迁移小红书取材、YouTube 单条发布记录，并跑通 B 站单条投稿及已发布稿件的封面替换。定时扫描、自动生成任意视频英文文案和无人值守批量发布尚未交付；调度默认关闭。网页播放版本不能当作原始上传母版。

## 数据流程

1. 在本人小红书主页取标题、笔记 ID、封面；通过浏览器另存页面离线解析本人视频已有播放链接，再用浏览器下载。
2. 以笔记 ID 建素材库，记录视频 SHA-256。第一次采集建立历史基线，不自动补发全部旧内容。
3. 分平台生成发布包。B 站沿用中文标题，使用音乐分区和相关音乐标签；封面参考本人小红书的白色手写曲名与浅蓝下划线，只放曲名。YouTube 忠实翻译为英文，保留现有英文设计封面风格和相关标签。
4. 核对目标账号已有稿件，按「平台 + 账号 + 源笔记」及「平台 + 账号 + 视频哈希」去重。
5. 发表前持久化一次提交声明；崩溃或结果未知先查原稿。审核中与公开可播放分别记录。

## 本地使用

Python 3.12+，Windows PowerShell 5.1 / Chrome。

```powershell
python sync.py status
python sync.py plan
python -m unittest discover -s tests
```

`sync.py` 管理本地 SQLite 台账，不会发网络请求或自行投稿。`rpa/Browser.ps1` 负责当前浏览器原生控件操作；平台试验结果见 `docs/STATUS.md`。原始 POC 脚本归档在本机 `data/legacy-poc`，不是通用批量适配器。

第一次迁移既有本机 POC：

```powershell
python tools/import_poc.py ../windows-rpa-github/artifacts/work
```

RPA 需先运行 `rpa/Bind-Browser.ps1` 绑定当次 Chrome 窗口；旧 PID 或窗口句柄不作为配置默认值。完整实测步骤与断点见 [RPA 操作记录](docs/RPA-RUNBOOK.md)。

`data/` 存素材、账号绑定、发布台账和本机证据，`artifacts/` 存 UIA 快照与截图，均被 Git 忽略。不要提交浏览器另存页面、会话凭据或 Cookie。创建 `data/STOP` 即停止后续 RPA 修改操作。

## 自动化边界

一次最多发 1 条，本轮只测试 B 站；YouTube 已成功的视频只迁移回执。尚未启用历史补发、轮询服务、计划任务或开机启动。后续自动同步应只处理基线之后新增且素材齐全的本人视频，两个平台独立重试、独立核验；封面/账号/标题不确定时保留现场等待处理。

按用户要求，小红书和 B 站相关域名加入系统代理绕过列表，YouTube 保留已有代理。`tools/Set-PlatformDirect.ps1` 保存本机修改前备份，不修改 Clash 全局出口。
