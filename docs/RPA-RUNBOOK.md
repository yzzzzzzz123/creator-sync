# 单条 RPA 实测与恢复

当前平台操作由 Codex 按原生 UIA 快照执行，尚不是无人值守批量适配器。浏览器保留本人登录会话，脚本不读取或导出 Cookie，不使用网页 JS 或浏览器调试协议。

1. `rpa/Bind-Browser.ps1` 从当前可见 Chrome 绑定窗口、PID、启动时间，保存本机 `data/browser-binding.json`。有多个匹配窗口时应使用现场读取的句柄明确绑定。
2. `rpa/Browser.ps1 -Action Inspect -Stage <name>` 输出 UIA 树和真实截图。导航仅允许目标平台官网；编辑控件按实时名称、控件类型、类名定位。有原生文件对话框时先处理对话框；网页控件中心被遮挡时停止。
3. 从本人 B 站空间核对账号与已有视频，在创作中心查看草稿和进行中稿件。准备本机 `data/bilibili-test.json`，通过台账 `prepare` 明确单条源笔记、素材哈希及目标账号。
4. 打开官网投稿页，点击“上传视频”，运行 `rpa/Choose-BilibiliAsset.ps1 -Purpose Video` 操作本机文件选择器。上传声明先以 CreateNew + Flush 持久化，恢复时查看现有上传，不重传。
5. 填写原标题、音乐分区、相关标签、简介；删除页面自动填入的无关标签。自定义封面上传采用同一文件选择器，分别检查 4:3 和 16:9。真实演奏视频的创作声明为“内容无需标注”。
6. 再次核对本人账号、公开可见、关闭定时/商业推广，记录封面与设置截图。`rpa/Submit-BilibiliOne.ps1` 核对源素材、选中标签与当前表单，持久化文件声明和 SQLite `submitting` 后只点击一次。
7. 出现“稿件投递成功”后到稿件管理读取同一标题、BVID、审核状态；用公开页面确认可播放。发布成功、审核中和提交结果未知分别记录，不能仅凭按钮点击认定发布。

## 抖音 RPA 取材与新平台编辑

完整路径见 [平台执行与恢复](../skill/references/platform-flow.md)。原生操作可见 Chrome DevTools Network / Media，核对正常播放资源的精确作品 ID，在新标签通过浏览器另存视频，再从本人作品卡另存原封面。不使用调试协议、Console、Cookie 或私有接口，不以提供原片目录为前提。

`tools/rpa_source.py bind` 绑定本人主页、Network 和媒体页三份快照；`rpa/Save-Media.ps1` 保存文件前按作品 ID 持久化声明；`tools/verify_media.py` 完整解码；`tools/rpa_source.py finish` 以实际哈希入库。需要兼容副本时 `tools/prepare_upload_video.py` 保留源、复制 AAC 音轨并核对一致性。下载地址含临时签名，只留在忽略目录，不打印或提交。

TikTok / Instagram 用 `rpa/Choose-SyncAsset.ps1` 绑定当前账号、源哈希和上传声明。草稿和未保存编辑现场记录在本机 `data/platform-preflight.json`，恢复时主入口给出 `reconcile_existing_draft`。本轮从同一稿件继续，`rpa/Submit-SyncOne.ps1 -Package <独立发布包>` 校验现场后先写文件声明与 SQLite claim，再仅点击一次 Post/Share。两个新平台均已发表并核对同一作品链接与实际演奏播放，随后暂停。不得因台账尚无 published 就重传。

`rpa/Inspect-Public.ps1` 可在没有现存无痕会话时打开本任务独立无痕窗口，读取已知官方作品链接并保存证据，不改原有浏览器绑定。若已有无痕会话，不能假定新窗口未登录，保留用户现场。`-Action Close` 仅关闭本任务创建且只有一个标签页的窗口。Instagram 的可关闭注册提示可用 `-Action DismissPrompt`；不尝试绕过登录限制。页面可访问、真实播放与后台投稿分别记录。

## 已发布稿件改封面

从稿件管理对应行进入编辑，地址栏与 UIA 文档都应包含 `type=edit&bvid=<既有编号>`。更新发布包的封面路径及哈希，上传时使用 `Choose-BilibiliAsset.ps1 -Purpose Cover -CoverRevision`；它为不同图片哈希建立独立上传声明，保留原发布声明。

两个比例确认后，`Save-BilibiliCoverRevision.ps1` 核对既有稿件编号、原标题和封面上传声明，保存带图片哈希的编辑声明，只提交一次修改。该操作不创建新的 delivery，也不增加视频数量。当前两项提交脚本绑定本机这次实测发布包，不应作为不经核对的批量入口。

## 页面等待与中断

- Chrome 地址栏更新早于文档/UIA 就绪；等官网文档路径和目标视频编号一致后再操作。
- 短视频可能播完自动跳到推荐视频；公开核验必须在同一编号实际播放后暂停，再保存证据。
- 人工切换标签页时先恢复目标标签，不在新当前页面重放业务动作。
- 已写 intent 而结果未知时，先查原稿。`data/STOP` 存在时任何后续浏览器修改或提交都停止。
- 登录、扫码、验证码交给本人完成。测试期间没有启动后台轮询或自动恢复服务。

## 下一阶段

把已验证的取材与单条平台步骤封装为完整适配器，再增加新增内容扫描、平台已有稿件映射、发布包生成、可见进度与有界重试。完成这些步骤后才启用持续自动同步。
