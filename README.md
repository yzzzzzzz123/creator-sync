# Creator Sync

本人抖音发布内容 → 小红书 / Bilibili / YouTube / TikTok / Instagram 的本机同步项目。抖音由本人运营，程序只读取已发布作品。用 Windows 原生 RPA 操作已登录的 Chrome，账号登录与验证码由本人完成。

## 启动入口

以后直接对 Codex 说：**“调用 creator-sync 的 skill，把抖音最新 1 条同步到其他平台。”** 入口是 [skill/SKILL.md](skill/SKILL.md)，主流程程序在 [skill/scripts/main.py](skill/scripts/main.py)。

在项目根目录运行：

```powershell
& .\skill\Start.ps1                  # 启动本轮，接管 Chrome 并建立断点任务
& .\skill\Start.ps1 -Action attach   # 接管现有 Chrome；关闭时自动启动六站
& .\skill\Start.ps1 -Action status   # 查看发布状态
& .\skill\Start.ps1 -Action sites    # 查看六站地址、账号角色和分流
& .\skill\Start.ps1 -Action resume   # 继续同一轮
& .\skill\Start.ps1 -Targets @('tiktok','instagram') # 只同步指定目标
```

地址、源/目标角色和网络规则维护在 [skill/sites.json](skill/sites.json)，自动合并本机账号。没有 Chrome 时使用本人原有资料打开六站；已有 Chrome 时复用登录、补齐缺少的标签页。主程序管理会话、去重与断点，网页 RPA 由调用 Skill 的 Codex 继续执行。

已保留原小红书取材及 YouTube/B站真实发布回执。抖音通过原生 RPA 取得本人作品的标题、完整视频和原封面，保存文件后全帧解码验证。TikTok 和 Instagram 已各完成 1 条真实发表，核对准确作品链接与实际演奏播放，均使用英文文案、相关话题及居中曲名封面。TikTok 未登录页要求登录，播放在本人登录会话核验；Instagram 未登录也可访问同一公开页面。调度默认关闭。网页播放版本与原始上传母版分别记录。

## 数据流程

1. 在抖音本人主页核对账号，只读标题、作品 ID、发布时间和素材；用原生 UIA 快照及浏览器另存文件，不调用私有接口。`tools/import_douyin_snapshot.py` 可导入已加载标题链接；`tools/rpa_source.py` 绑定可见界面证据和登记另存素材，`tools/verify_media.py` 完整解码核验。默认 RPA 取材，不要求本人先提供原片目录。
2. 抖音内部源键使用 `douyin:<作品ID>`，小红书历史源键不变。第一次采集建立基线，不自动补发旧内容；素材齐全且核验后才准备投稿。
3. 五个目标分别生成发布包。国内使用中文；YouTube 保留英文设计风格，TikTok/Instagram 默认英文适配。标题忠实、标签相关；B站/小红书封面只放曲名，参考已接受的手写风格。
4. 核对目标账号已有稿件，按「目标平台 + 账号 + 源键」和「目标平台 + 账号 + 视频哈希」去重。跨平台重编码导致哈希不同时，仍须比对内容，不自动判断是新作品。
5. 发表前持久化一次提交声明；崩溃或结果未知先查原稿。审核中与公开可播放分别记录。

后续所有封面文字居中，按平台检查 4:3、16:9、9:16、1:1 的实际裁切。横向演奏不强裁双手与琴键。

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

一轮最多选择 1 条源视频，五个目标独立准备、去重和核验。未知提交先查原稿，禁止重放。已发布回执保留；尚未启用历史补发、轮询、计划任务或开机启动。只处理范围明确且素材齐全的本人视频；封面、账号或标题不确定时保留现场。

抖音、小红书、B站直连；YouTube、TikTok、Instagram 使用既有代理。启动会检查并补齐国内域名绕过列表，保留代理出口。`tools/Set-PlatformDirect.ps1 -Check` 可只读检查；配置正确和页面可访问分别验证。
