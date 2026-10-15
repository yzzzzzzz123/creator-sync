# 平台执行与恢复

本项目保留了小红书取材、YouTube/B站各 1 条真实发布的历史证据。当前主源改为抖音，只读取本人已发布内容；完整视频、标题及原封面 RPA 取材已验证。TikTok 和 Instagram 已各完成单次真实发表，准确作品链接与实际演奏播放均已核验。平台网页由当前 Codex 按实时 UIA 操作，历史 POC 的句柄、编号和路径不作新任务默认值。

## 站点与会话

`../sites.json` 存六站官网、角色、网络规则和主页模板。`scripts/main.py sites` 合并 `config.local.json` 绑定账号。`Session.ps1` 只读发现普通 Chrome，排除无痕和没有浏览器标签的辅助窗口；接管时校验进程启动时间。无普通 Chrome 时通过正常入口打开配置地址，不加调试参数或替代资料目录。

已有 Chrome 缺少平台标签时，启动流程在同一窗口通过原生新标签按钮和地址栏精确回读打开所需官网。接管不会重置登录。窗口中有原生对话框、桌面锁定或账号不确定时，保留现场处理。

Chrome 的网页自身也可包含 UIA TabItem；浏览器标签只统计原生 Class=Tab。打开新页使用 Chrome 原生“新标签页”控件，确认标签数增一、地址栏为空后才填官网。PowerShell 5.1 的 ConvertFrom-Json 结果直接 foreach，避免把整个 JSON 数组包成单个站点。

## 抖音只读取材

从 `/user/self` 核对本机绑定的昵称和抖音号，再保存 UIA 快照。`tools/import_douyin_snapshot.py` 校验本人身份后提取作品卡片标题和链接，保留置顶标记；不会把第一条卡片当最新，也不会凭元数据创建投稿。只覆盖已加载作品范围，禁止声称已遍历全部历史。

到候选作品页核对作者主页、发布时间、标题与视频 ID。先用页面已有下载功能；需要离线分析时，可用 `rpa/Save-Page.ps1 -ExpectedUrl <准确作品地址> -OutputPath <data下的html>` 另存当前页面。它验证绑定、文档和 Chrome 所属保存对话框；遇已有对话框先核对并用 `-ResumeDialog` 继续，不重开另存。Chrome 原生文件对话框可能由另一个 Chrome 进程承载，以 owner 窗口与进程名校验，不能强求相同 PID。返回 pending 时等同一文件稳定，不重复导出。

离线解析仅使用已保存页面已有的媒体资源，不构造私有接口。播放地址不可取得、权限受限或文件不完整时停在取材阶段；不能用推荐视频或其他作者内容替代。抖音不进行发布、删除、编辑、评论等运营动作。

HTML-only 另存文件可能只有应用配置且 aweme 为空。这只说明该 HTML 路径未取得视频，继续以下原生 RPA 路径，不要求本人提供原片目录：

1. 在本人主页为准确作品 ID 保存新 UIA 身份快照；到作品页核对作者、标题、发布时间和 ID。原生点击 Chrome 菜单 → 更多工具 → 开发者工具。`rpa/Chrome-Native.ps1` 只操作可见 Chrome 菜单及 DevTools GUI，不使用调试协议。
2. 进入 Network → Media，让同一作品正常加载；找到 Class=name-column、URL 参数 `__vid` 精确等于作品 ID 的媒体请求行。对该行原生右键 → Open in new tab。菜单打开与点击尽量放在同一次 shell 操作内，防止焦点变化使菜单关闭。不导出 HAR、请求头或 Cookie，不输入 Console。
3. 保存 Network 与独立媒体页快照，运行 `python -X utf8 tools/rpa_source.py bind --source-id <ID> --profile-snapshot <本人主页快照> --network-snapshot <Network快照> --media-snapshot <媒体页快照>`。它离线核对本人作品卡、同一绑定窗口、近期证据、源页面和精确媒体 ID，只把已有播放地址存到忽略目录，不打印签名地址。允许 douyinvod.com 及实际观察到的 `v数字-dy-….zjcdn.com`；未知域名先核实，不扩大到共享海外域名。
4. `tools/Set-PlatformDirect.ps1` 只为已验证的实际国内媒体主机补充精确直连项，保留海外代理。在独立媒体页 Ctrl+S 后，运行 `rpa/Save-Media.ps1 -OutputPath <data/assets/douyin-ID/video.mp4>`，以原生文件对话框保存。声明按作品 ID 分目录；有旧声明先检查已有下载，不能重放。
5. 回本人主页，对同一作品卡的 Image 原生右键 → 图片另存为。先保存 `artifacts/douyin-cover-identity.json` 证明当前账号及作品链接，再运行 `rpa/Save-Media.ps1 -Purpose Cover -OutputPath <data/assets/douyin-ID/source-cover.jpeg>`。保留实际图片扩展名。
6. 运行 `python -X utf8 tools/verify_media.py <video.mp4> --expected-seconds <页面时长>`，验证音视频轨、时长及全帧解码，并查看首/中/末帧。再运行 `tools/rpa_source.py finish --video <video.mp4> --cover <原封面>` 入库。网页版本质量如实记录，不能冒充上传母版。

上述步骤已实测取得完整 34.5 秒视频及原封面。此时长仅为本次结果，不是下一条素材的默认值。若需浏览器兼容副本，可运行 `tools/prepare_upload_video.py <video.mp4>`：保留源文件，转 H.264，复制原 AAC 音轨并比较音频码流哈希，完整解码副本；台账仍按原视频哈希去重。需要 ffmpeg 时可在项目忽略目录安装 `python -m pip install --target artifacts/vendor --only-binary=:all: --no-deps imageio-ffmpeg`，不创建可见后台窗口。

## 小红书取材

原生浏览器操作统一使用项目 `rpa/Browser.ps1`；`data/legacy-poc/xhs-own-content-poc/` 保留此前离线解析与文件保存的实测代码供核对，其示例固定笔记不能直接作为本轮素材。

完整网页中 note-item 卡片可提供笔记 ID、标题、封面文件；在本人笔记另存页面中，`window.__INITIAL_STATE__` 的 noteDetailMap 记录作者与已有视频播放链接。离线解析可把字符串外的 `undefined`、`new Map([])` 标记规范化为 JSON，禁止 eval。先核对作者是本人，再用浏览器下载记录中的播放地址，不从私有接口构造地址。

## B站

投稿前在本人空间读取已有视频列表，在后台检查草稿和进行中稿件。上传后核对“上传完成”，填写原标题、音乐分区、相关标签与简介。真实演奏视频使用实际对应的创作声明。

封面有首页 4:3 和个人空间 16:9 两套效果。上传后确认双比例同步或分别修改；文字必须居中，保存封面编辑器后仍需提交外层稿件编辑。后台同一 BVID 的封面已变化才算保存核验完成。

`rpa/Choose-BilibiliAsset.ps1`、`Submit-BilibiliOne.ps1` 和 `Save-BilibiliCoverRevision.ps1` 是已经实测的原生实现。它们当前仍读取本机单条 POC 发布包与 intent；新任务应在本轮独立目录绑定发布包和声明，复用校验逻辑，不覆盖历史回执或用旧包直接投稿。代码入口收口不代表这些固定 POC 已成为无人值守批量适配器。

## YouTube

`data/legacy-poc/youtube-publish-poc-20261015/` 保留已验证的上传、缩略图和单次公开发表实现，参考时使用当前绑定窗口与本轮发布包。频道必须与本机绑定一致；实际标题、简介、标签、封面和公开选项逐项回读。

若本人刚完成手机号验证，但旧上传弹窗仍提示无权限，先确认视频已保存为私享，再刷新并打开同一视频草稿，继续上传自定义封面；不重新上传视频。

标签输入的逗号不一定立即提交标签，按 Enter 后核对实际标签芯片。横向 16:9 的短时长视频按平台实际类型处理，不强称 Shorts。

## 小红书作为目标

本人原账号转为投稿目标，历史小红书来源数据仍保留。从小红书创作中心核对本人账号和内容管理，再进入视频发布。中文标题沿用抖音语义，封面按本人小红书曲名风格居中。查重需对比已有视频，不能把同一演奏在不同平台重新编码后的文件当作新内容。

## TikTok

使用 `https://www.tiktok.com/tiktokstudio/upload`；未登录会跳转官方登录页，登录后回到上传入口。顶部头像菜单的 Profile 链接用于核对真实账号。已实测上传视频、英文文案、自定义封面、保存并恢复同一 draft_id。单次 Post 后后台出现同一文案与作品编号，草稿数减一，先显示审核中，随后 Posts 数增一。公开页曾短暂空白，等待后正常加载；核对准确作品编号、真实演奏画面和进度变化后才记录 published。未登录页要求登录，不能声称未登录播放已验证。

后续上传使用 `rpa/Choose-SyncAsset.ps1 -Platform tiktok -AccountEvidence <新账号快照>`，以原生文件选择器选择已验证素材并先写独立上传 intent；`-Purpose Cover` 选择同源自定义封面。文案控件为 ComboBox / `notranslate public-DraftEditor-content`，用 TextPattern 全文回读，不能拿第一个文本子节点与整段含话题文案比较。Edit cover → Upload cover image 后检查实际裁切，保存封面与 Save draft 分别先写一次声明。重启后已有草稿先核验，不再次上传。新手提示 Got it 可遮挡操作，先原生关闭提示。最终 Post 使用下述单次提交实现；不得通过通用 Browser.ps1 绕过最终提交保护。

## Instagram

从左侧本人头像链接核对账号，New post → Create new post → Select from computer，使用 `rpa/Choose-SyncAsset.ps1 -Platform instagram -AccountEvidence <新账号快照>` 上传。已实测完整视频、16:9、居中曲名封面、英文说明及单次 Share，平台显示成功，取得同一作品公开链接。登录播放页核对真实连续画面，主页核对居中封面；独立未登录窗口也可访问同一公开页面。Share 前的编辑现场不能假定是持久草稿，恢复时先保留标签页。

按实时编辑器逐步检查裁切、完整时长、封面和英文说明，保留琴键及双手。`Browser.ps1 -Within Crop|Edit|'Create new post'` 按实际模态窗口名限定操作，避免命中背景信息流。Select crop 菜单应点击实时 UIA 中的内层按钮；选择 `16:9 Crop landscape icon`，不使用默认正方形强裁演奏。Edit 的 Select from computer 用于自定义封面；Next 后在 Add a caption... 填英文并全文回读。UIA 中“无法播放媒体。”标签本身不足以证明编码失败，应同时检查真实预览、时间变化及声音。目标主页裁切与视频播放画幅分别检查；最终 Share 使用单次提交实现。兼容副本替换只针对已确认废弃的本次未发表编辑稿，使用 `-ReplaceVideo` 留存原声明，不删除用户既有作品。

## 新平台单次提交

本轮独立目录准备 JSON 发布包：`Platform`、`MaxPosts=1`、`SourceKey`、`AccountId`、`SourceSha256`、`Caption`、准确 `EditorUrl`、近期 `AccountEvidence` 和 `ExistingPostsEvidence`、实际 `Video/Cover`（各含 `Path/Sha256/UploadIntent`），以及人工核验后的 `CoverAndSettingsVerified=true`。TikTok 使用原草稿带 draft_id 的地址，Instagram 使用当前官网编辑文档地址。先检查目标所有已加载稿件，标题/时长不能仅凭歌曲相同作去重结论。

运行 `rpa/Submit-SyncOne.ps1 -Package <发布包>`：核对账号、源与上传文件哈希、完整文案、当前编辑文档、按钮遮挡，TikTok 还核对 Now / Everyone，Instagram 核对模态窗口内账号。写入 CreateNew + Flush 文件声明后，`tools/claim_sync_submit.py` 在 SQLite 中 claim，最后仅点击一次。Sharing 等待期间保留现场，不重放；从后台或本人主页读取准确作品编号，再用 `Ledger.record` 分别记 submitted/processing/published。公开播放未验证不能记 published。对应声明都保留在本轮独立目录。

## 回执与断点

每个平台分别使用 `sync.Ledger.prepare/claim_submit/record`。`submitting/submitted/processing` 或已存在 intent 的同一次投递只允许核对原稿，不能当作新任务重试。`published/existing` 跳过重复发布；一边成功不阻止另一边继续。

本轮状态位于 `data/skill/active-run.json`；`select` 绑定现场采集的唯一源笔记，`resume` 根据台账重新计算下一步。浏览器截图和网页证据置于 `artifacts/` 或本轮目录，不提交 Git。

`data/platform-preflight.json` 将草稿/未保存编辑现场与源键、源视频哈希、目标账号绑定。主入口返回 `reconcile_existing_draft` 时继续同一稿件；只有网页核验后才能更新状态，丢失现场不等于允许重新投稿。草稿证明与公开回执分别记录。
