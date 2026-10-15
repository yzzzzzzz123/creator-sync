# Creator Sync

- 本项目以本人小红书内容为源，分别同步到 Bilibili 和 YouTube。素材、账号绑定、发布记录均保存在本机忽略目录，不提交认证资料。
- 使用 Windows 原生 UI Automation / SendInput RPA；不使用 CDP、Playwright、网页 JS 注入、私有接口或导出 Cookie。离线解析用户通过浏览器另存的页面可以使用。
- PowerShell 5.1 脚本保存为 UTF-8 BOM。后台 shell 使用 tty:true，子进程 CREATE_NO_WINDOW；交互浏览器保留。
- 发布前核对窗口 PID/启动时间、官网文档、账号、标题、素材哈希、封面、标签、分区和已有稿件。单次提交先持久化 intent；结果未知时核验原稿，禁止重放提交。
- 小红书中文标题用于 B 站；B 站封面参考本人小红书风格：白色手写曲名、浅蓝下划线，只保留曲名，不加“钢琴演奏”等副标题。YouTube 保留现有英文设计风格、忠实英文标题及相关标签。不得用无关热词。
- 本轮授权 B 站单条验证；不得自动补发历史 30 条，不启动定时任务。停止文件 data/STOP 存在时禁止界面修改和提交。
- 用 python -m unittest discover -s tests 验证队列与去重。不要改变用户其他项目或浏览器资料目录。
