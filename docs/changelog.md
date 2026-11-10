# 更新日志 · Changelog

每个版本先中文、后英文。发版时把对应版本的正文（不含版本标题）作为 Release 正文，见 `docs/release.md`。

## 1.0.0 · 2026-10-30

### 中文

DSH Go 1.0.0 来了，这是第一个公开版本。它让你在 Android 手机上运行 DeepSeek Harness（DSH），也能连上电脑或服务器上的 DSH，走到哪儿都能接着聊、接着干活。DSH Go 以 AGPL-3.0 开源，欢迎来 GitHub 看看。感谢测试期间每一位反馈问题、提出建议的朋友；已经在用 0.9.10 的，这一版功能不变，只是正式换上 1.0.0 的版本号。

现在的 DSH Go 可以：

- **本机运行**：在 App 里装好 Ubuntu、Node.js 和 DSH 运行环境，不用 Root，也不用另装 Termux。
- **远程主机**：通过 SSH 或 DSH Remote 使用电脑、服务器上的 DSH；只连远程时，手机上不必安装运行环境。
- **对话**：切换模型、发图片，回复中途也能插话；工具审批和提问在对话里直接处理，原生界面和网页版一键切换。
- **插件**：从插件市场安装；适配 DSH Go 的插件以原生的工具卡、表单和面板呈现，设置页也是原生的。仓库附带 SDK、教程和示例。
- **手机操控**：开启权限后，让本机引擎看屏幕、点按和输入，随时可以暂停或停止。确认方式可选「关键步骤先问我」或「全程自动」；可选的「解除限制」默认全部关闭，开启前会先说明风险。Android 14 及以上还能用不打扰模式，在看不见的屏幕上操作，不耽误你用手机。
- **离线语音输入**：语音模型（约 241 MB）下载到手机上，在本地识别。
- **宠物**：Deepy 小鲸鱼和鲸娘陪你干活，打开「App 外显示」还能跟你到桌面。
- **分享**：把一条回复、选中的消息或整段对话分享成链接、图片、文件或文字；链接端到端加密，对方可以在浏览器里回放，或在 DSH Go 里接着聊。
- **外观**：六套配色，也可以跟随壁纸或自选颜色；换桌面图标，用自己的壁纸和启动画面；界面支持中文和英文。
- **匿名使用统计**：只发送每天的使用次数和 App、系统版本等基本信息，不含对话、文件和账号；默认开启，在 设置 › 隐私与分享 随时关闭。
- **图像与视频生成即将上线**：App 这边已经就绪，生成插件发布后即可在对话里使用。

此前 0.9.x 各版本的详细改动见[更新日志](https://github.com/ccch1mneyyy/dsh-go/blob/HEAD/docs/changelog.md)。

### English

DSH Go 1.0.0 is here, our first public release. It runs DeepSeek Harness (DSH) on your Android phone or connects to DSH on your computer or server, so you can pick up a chat or a task wherever you are. DSH Go is open source under AGPL-3.0; come take a look on GitHub. Thank you to everyone who reported problems and shared ideas during testing. If you're already on 0.9.10, nothing changes but the version number: it's the same app, now 1.0.0.

What DSH Go does today:

- **On your phone:** install the Ubuntu, Node.js and DSH runtime from the app, without Root or a separate Termux.
- **Remote hosts:** use DSH on a computer or server over SSH or DSH Remote; if you only connect remotely, the phone doesn't need the runtime.
- **Chat:** switch models, send images and step in while a reply is still coming; handle tool approvals and questions right in the chat, and switch between the native and web interfaces in one tap.
- **Plugins:** install from the plugin market; plugins adapted for DSH Go show up as native tool cards, forms and panels, with native settings pages too. The repository includes an SDK, guides and examples.
- **Phone control:** once you grant the permissions, the local engine can read the screen, tap and type, and you can pause or stop it at any time. Choose "Ask me at key steps" or "Fully automatic"; the optional Lift limits switches are all off by default and explain the risks before they turn on. On Android 14 and later, non-disruptive mode works on a hidden screen while you keep using your phone.
- **Offline voice input:** the voice model (about 241 MB) downloads to the phone and recognises speech on the device.
- **Pets:** Deepy and Whale girl keep you company while DSH works, and with "Show outside the app" they come along to the home screen.
- **Sharing:** share one reply, selected messages or a whole chat as a link, an image, a file or text. Links are end-to-end encrypted, and the recipient can replay the chat in a browser or continue it in DSH Go.
- **Appearance:** six colour palettes, or follow your wallpaper or pick your own colour; change the app icon and use your own wallpaper and launch screen. The app is available in Chinese and English.
- **Anonymous usage stats:** only daily usage counts and basics like the app and Android version, never chats, files or accounts. On by default; turn it off any time in Settings › Privacy and sharing.
- **Image and video generation is on its way:** the app side is ready, and it opens up in chats once the generation plugin is released.

For the detailed history of the 0.9.x releases, see the [changelog](https://github.com/ccch1mneyyy/dsh-go/blob/HEAD/docs/changelog.md).

## 0.9.10 · 2026-10-30

### 中文

- 手机操控：不打扰模式下输入文字，总是写进 AI 指定的那个输入框，并整体替换原来的内容；页面上有密码或验证码输入框、或者页面没能读全时，只给文字不附截图；英文界面的验证码、口令输入框也能认出来。「关键步骤先问我」在英文界面的发送、删除、付款、购买等按钮前也会先确认。
- 停止引擎时，正在进行的手机操作一起停下，排在后面的也不再执行。
- 语音模型下载完成后，已经打开的对话里马上出现麦克风，不用退出重进。
- 登录 DSH Remote：取消后不会再打开浏览器，也不会过一会儿变成已登录；退出登录后，各登录方式的按钮照常显示。
- 自己的启动动图：最后一帧按原本的时长显示完再进入 App，不再一闪而过。
- 选文件时超过大小或数量上限会马上提示，不再先把整个文件读完。
- 连接远程主机时，对话里图片的缩略图和预览同时下载，预览不再报读取失败。
- 应用内更新：下载时手机存储满了，会提示存储可能已满、清理后重试，不再一直卡在下载中。
- 首次安装后第一次运行期间导入的配置，不会被安全模式的「恢复上次正常的配置」当成正常配置。
- 使用说明：插件设置显示「未保存」时要点底部「保存」并等到「已生效」；DSH Remote 登录选和主机上相同的登录方式；停止分享后，4 秒撤销期过去、删除成功时链接才失效。

### English

- Phone control: in non-disruptive mode, typing always goes into the field AI asked for and replaces what was there. A page with a password or code field, or one that couldn't be read in full, comes back as text only, without a screenshot, and English code and passcode fields are recognised too. "Ask me at key steps" also asks before Send, Delete, Pay, Buy and similar buttons in English apps.
- Stopping the engine also stops the phone action in progress, and the ones queued behind it no longer run.
- When the voice model finishes downloading, the microphone appears in a chat that's already open, without leaving and coming back.
- Signing in to DSH Remote: after you cancel, the browser no longer opens later and you don't end up signed in anyway; after signing out, each provider's button shows again.
- Your own launch animation holds its last frame for its full time before the app takes over, instead of flashing past.
- Picking files stops at the size and count limits right away, instead of reading the whole file first.
- On a remote host, an image's thumbnail and its preview can download at the same time without the preview failing to load.
- In-app updates: running out of storage during the download now says storage may be full, so you can free up space and retry, instead of waiting forever.
- A config imported during the very first run after install is no longer taken as the last working configuration by Safe mode's "Restore the last working configuration".
- User guide: when plugin settings show Unsaved, tap Save at the bottom and wait for Applied; DSH Remote sign-in uses the same provider as on the host; after Stop sharing, the link stops working once it's deleted after the 4 s Undo window.

## 0.9.9 · 2026-10-30

### 中文

- 手机操控可以全程自动：首次启动选「手机操控」时，可以选「关键步骤先问我」或「全程自动」，之后在 设置 › 手机操控 › 确认方式 随时改，那里也列出了哪些事仍由你来操作。
- 解除限制（可选）：设置 › 手机操控 › 解除限制 有三个开关——系统设置、密码和验证码、DSH Go 自身，默认全部关闭。打开前会说明 AI 能做什么、可能出什么问题以及免责声明，需要按住「我了解风险，开启」约 1.5 秒，后果由你自行承担；任务进行中不能打开，关闭只要点一下。开着时悬浮条和手机操控页显示「已解除限制」。AI 输入的密码和验证码在操作记录、悬浮条和确认卡里只显示为 ••••，也不会出现在返回给模型的结果里。
- 自定义壁纸：设置 › 主题 › 壁纸 可以把自己的图片铺在首页、对话和抽屉后面，可以调模糊，浅色模式下提亮、深色模式下压暗；文字和背景的对比度始终保持在 4.5:1 以上。
- 启动画面：自己的启动画面不再限制 3 秒，图片和动图 8 MB 以内、视频 30 MB 以内，冷启动时完整播放，点一下就能跳过。换了桌面图标后，启动时只会出现你选的那个图标，不会先闪一下默认的蓝色图标。
- 直接启动本机引擎（设置 › 诊断 › 开发者选项）仍是实验功能，默认关闭。打开后，从旧版本升级的会先把插件文件整理一次，手机空间不够时先用兼容启动；某台手机上直接启动起不来（例如 Android 16 会拦截）时，会自动改用兼容启动，不进安全模式，也不会反复重试。
- 插件更新后提示重启引擎：正在运行的引擎要重启才会用上新版本，更新完成后直接给出重启的选项（连接远程主机时提示到那台电脑上重启）。
- 匿名使用统计：每天的使用次数（发消息、语音输入、手机操控、生成、分享各几次，装了几个插件），连同 App 和系统版本、CPU 架构、手机品牌（不含型号）、界面语言和本机引擎的启动方式，当天过后匿名发送一次；设备之间只用一个每 90 天更换的随机编号区分，不含对话、文件和账号。首次启动的欢迎页上就有开关，之后在 设置 › 隐私与分享 一键关闭，关闭后本机记下的次数和编号立即删除。从旧版本升级的会在首页提示一次。
- App 外的桌宠：拿起来、开心、醒来和打字时不再被裁掉；气泡放在桌宠画面的上方，不挡住动画，换动作时平滑跟着移动。
- 归档对话和卸载插件先等 4 秒，期间点「撤销」就原样保留，归档时进行中的一轮也不会停；切出 App 或接着归档、卸载别的时会立即执行。
- 陪你满半小时后，鲸娘会请你去 GitHub 给 DSH Go 点个 Star：一键打开仓库，点「已经点过啦」就不再出现；选「下次再说」的，累计再用 5 小时会再问一次，最多两次。只在首页或对话里、没有其他弹窗、当前对话也没有进行中的任务时出现。
- 远程主机登录 DSH Remote：服务器提供的每种登录方式都有自己的按钮，GitHub 排在最前（感谢 @HuanLinOTO）。
- 以前把新对话的默认权限设成「Auto」的，升级后本机引擎会清掉这个已失效的设置并重启一次，「本对话」和设置里的权限选项恢复正常。
- 其他：对话里 DSH 自己写进收件箱的提示不再显示成你发的消息；插件市场连不上时显示网络错误和重试，不再说「目录格式有误」；首次启动选了「桌宠与悬浮窗」而还没选桌宠时，会顺带选好默认桌宠；换了主机后，删除文件夹的「撤销」和批量置顶不会落到另一台主机上；语音「重新下载」时旧模型保留到新模型下载完；首次启动总结页的「继续」失败后可以再试；远程主机页的服务说明改为「服务由 liguobao/ds-harness-remote 提供」，点项目名可以打开它。

### English

- Phone control can run fully automatic: when you pick Phone control on first run, choose "Ask me at key steps" or "Fully automatic"; change it any time in Settings › Phone control › Confirmation, which also lists what still stays with you.
- Lift limits (optional): Settings › Phone control › Lift limits has three switches — system settings, passwords and codes, and DSH Go itself — all off by default. Turning one on first shows what AI can then do, what can go wrong and the disclaimer, and takes holding "I understand the risks, turn on" for about 1.5 s; you bear the risk. It can't be turned on while a task runs, and one tap turns it off. While any is on, the floating bar and the Phone control page say "Limits lifted". Passwords and codes AI types show only as •••• in the action log, the floating bar and confirmation cards, and never come back in the results sent to the model.
- Your own wallpaper: Settings › Theme › Wallpaper puts a picture of yours behind home, chats and the drawer, with Blur, plus Lighten in light mode and Dim in dark mode; text always keeps a contrast of 4.5:1 or more.
- Launch screen: your own launch screen is no longer capped at 3 s. Pictures and animations up to 8 MB and videos up to 30 MB play in full on a cold start, and a tap skips. After you change the app icon, launch only ever shows the icon you chose, never a flash of the default blue one first.
- Direct local engine launch (Settings › Diagnostics › Developer options) stays experimental and off by default. Turned on, an install upgraded from an earlier version first tidies its plugin files once, using compatible launch while the phone is short of space; on a phone where a direct start fails (Android 16 blocks it, for one), the app goes back to compatible launch on its own, without Safe mode or repeated retries.
- Plugin updates ask for an engine restart: the running engine keeps the old version until it restarts, so finishing an update offers the restart right there (on a remote host, it tells you to restart DSH on that computer).
- Anonymous usage stats: each day's counts (messages, voice inputs, phone control tasks, generations and shares, and installed plugins), with the app and Android version, CPU architecture, phone maker (not the model), app language and how the local engine started, go out anonymously once after the day ends. Devices are told apart only by a random ID that changes every 90 days; never chats, files or accounts. The switch is on the welcome screen on first run, and one tap in Settings › Privacy and sharing turns it off and deletes the counts and the ID on the phone at once. Installs updated from an earlier version are told once on the home screen.
- Pet outside the app: picked up, happy, waking or typing, it's no longer cut off; its bubble sits above the pet's picture instead of over it and glides along when the pose changes.
- Archiving a chat or uninstalling a plugin waits 4 s first: Undo keeps it as it was, a running turn included. Leaving the app, or archiving or uninstalling something else, carries it out at once.
- After half an hour together, the whale asks you to give DSH Go a Star on GitHub: one tap opens the repository, "Already starred" ends it for good, and "Maybe later" asks once more after another 5 hours of use — twice at most. It only appears on the home screen or in a chat, with no other dialog open and no task running in the current chat.
- Signing in to DSH Remote on the remote host page: each sign-in method the server offers gets its own button, GitHub first (thanks @HuanLinOTO).
- If the default permission for new chats was once set to Auto, the local engine clears that no-longer-valid setting after the update and restarts once, so the permission options in This chat and Settings load again.
- Other fixes: notes DSH writes into the inbox itself no longer look like your messages; when the plugin market can't connect it shows a network error with Retry instead of "Invalid directory format"; picking Pet over other apps on first run also picks the default pet if none was chosen; after switching hosts, a deleted folder's Undo and bulk pinning never land on the other host; Re-download in Voice input keeps the old model until the new one is in; a failed Continue on the first-run summary can be tried again; the remote host page now credits liguobao/ds-harness-remote, and tapping the project name opens it.

## 0.9.8 · 2026-10-29

### 中文

- 改名 DSH Go：桌面图标、最近任务、通知和系统设置里都叫 DSH Go。保存的图片在相册「DSH Go」，下载的文件在「下载/DSH-Go」；之前存的文件留在原处，旧对话里的文件卡片照常打开。
- 启动动画：系统启动画面无缝交接到 App 的第一帧，图标轻轻上移，DSH Go 字样随之浮现；冷启动完整播一遍，热启动可用即进。
- 自己的启动画面和桌面入口：设置 › 主题 › 启动画面 可以换成自己的图片、动图或 3 秒内的视频，选适配方式和背景色，预览一遍再用。桌面图标下新增「图片快捷方式」，用自己的图片在桌面另放一个打开 DSH Go 的入口。换桌面图标后会提示几秒后生效。
- 首次启动按功能开权限：新增一步「想让 DSH Go 帮你做哪些事」，在读写手机文件、桌宠与悬浮窗、手机操控、后台持续运行、语音输入里挑选，再逐项带你到对应的系统页面或品牌设置页，回到 App 自动确认是否已开启。无障碍遇到「受限制的设置」时有分步指引。之后在 设置 › 通用 › 系统权限 随时查看、补开。
- 离线语音输入：语音模型（约 241 MB）下载到手机上本地识别，不再依赖系统语音服务。设置 › 语音输入 可以下载、取消、重试和删除；国内网络直接可下，中断后接着下，用移动数据时先确认。首次启动选了语音输入的，引擎就绪后自动下载。
- 插件设置页：每个有设置项的插件都打开原生设置页，字段多时可以搜索，常用项在前，其余收进「高级」，离开前有未保存的改动会先确认。设置 › 引擎参数 › 插件 只列你装的插件，引擎自身的核心配置不在其中。
- 插件界面更丰富：对话里的 genui 卡片直接画成原生卡片，不再显示原始 JSON 和「让它重发」；插件视图新增空状态、图片墙、环形进度和指标趋势，可以跟随你选的配色，图标扩充到 162 个。输入框上方新增「插件」胶囊，打开本对话的插件面板；对话详情 › 插件 能打开插件提供的对话视图，打开前核对是不是你点的那一个；插件详情列出 App 里还没有位置的网页界面，一点直达网页版。
- 加号新增「本对话」：直接改这个对话的权限、开关计划模式，手机操控开着时还能改确认方式。选择模型弹层底部可以直达「管理模型」。
- 网页模式的返回键：先关掉网页里打开的弹窗、菜单、侧栏和子页面，一次一层，都关完才离开 App。
- SSH 连接的电脑上，用桌面版、终端或其他方式产生的对话，在列表里直接显示标题，不再是「未命名」；断线重连后也照常补上。
- 内置引擎升级到 DSH 0.2.1-rc.4：用 API Key 时模型列表跟随 DeepSeek 官方。所选模型需要新版引擎或当前不可用时，对话里直接说明并给出出路，不再只是「本轮出错了」。
- 图像与视频生成即将上线：App 这边已经就绪，生成插件发布后即可在对话里使用。
- 应用内更新更稳妥：屏幕上显示的版本、下载的文件和它的校验和绑定在一起，安装的一定是你看到的那个版本；安装前再次核对，不符的安装包直接丢弃，重试时按屏幕上的版本重新下载；放弃的安装不会影响下一次。
- 切换更稳：换主机后，旧主机的审批卡和提问卡随之收起，不再挡住新主机的请求；在选模型弹层打开期间换了对话，选中的模型不会落到别的对话；重连后计划、目标和团队信息会重新读取。
- 报错更清楚：订阅页的模型读不到时显示「没能读取模型」并可重试，不再误报「暂无模型」；团队消息读取失败不再显示成空收件箱；论坛通知翻页失败可重试；直接打开的 Bot 或群聊页会分别说明离线、经中转连接或 Bot 已不在。
- 其他：App 进入后台后，计时、动画和终端长按按键都会停下；进行中的提示语相邻两条不再重复；设置 › 诊断 显示引擎实际是直接启动还是兼容启动，直接启动失败后可以一键切回兼容启动，App 自身的异常也会记进诊断包；插件不能再通过界面操作改动权限模式；开源许可信息补全。

### English

- Now called DSH Go: the launcher, Recents, notifications and system settings all say DSH Go. Saved pictures go to the DSH Go album and downloads to Download/DSH-Go; files saved earlier stay where they are, and older chats still open their file cards.
- Launch animation: the system splash hands over seamlessly to the app’s first frame, where the icon rises and DSH Go fades in beneath it. A cold start plays it through; a warm start goes the moment the app is ready.
- Your own launch screen and home-screen picture: Settings › Theme › Launch screen takes a picture, an animation or a clip up to 3 s, with a fit and background colour and a preview first. Under App icon, Picture shortcut puts a separate shortcut to DSH Go on the home screen with a picture of your own. After switching the app icon, the app says the home screen takes a few seconds.
- Permissions by feature on first run: a new step, "What should DSH Go help with?", lets you pick from phone files, pet and floating window, phone control, running in the background and voice input. The app then takes you to each system or phone-maker page in turn and checks whether it's on when you come back. Accessibility gets step-by-step help when Android shows Restricted settings. Review or finish any of it later in Settings › General › System permissions.
- Offline voice input: the voice model (about 241 MB) downloads to the phone and recognises speech on the device, without relying on the system's speech service. Settings › Voice input downloads, cancels, retries and deletes it; it downloads from mainland China, resumes after an interruption and asks before using mobile data. If you picked voice input on first run, it downloads once the engine is ready.
- Plugin settings: every plugin with settings opens a native page. Long forms can be searched, the common fields come first and the rest fold under Advanced, and leaving with unsaved changes asks first. Settings › Engine parameters › Plugins lists only the plugins you installed, never the engine's own core settings.
- Richer plugin UI: genui cards in a chat draw as native cards instead of raw JSON and "Ask to resend". Plugin views gain empty states, galleries, ring progress and metric trends, can follow your colour palette, and have 162 icons to choose from. A Plugins capsule above the composer opens the chat's plugin sheet; Chat details › Plugins opens a plugin's view of the chat, checking it is the one you tapped; and plugin details list the web parts the app has no place for yet, each one tap from DSH Web.
- This chat, in the + panel: change this chat's permissions, turn plan mode on or off and, with phone control on, its confirmation style. The model sheet links straight to Manage models.
- Back in web mode closes what DSH Web has open, one layer per press (dialogs, menus, side panels, sub-pages), and only then leaves the app.
- On a computer reached over SSH, chats started in the desktop app, the terminal or anywhere else show their titles in the list instead of "Untitled chat", and keep getting them after a reconnect.
- The built-in engine is now DSH 0.2.1-rc.4: with an API key, the model list follows DeepSeek's official one. When the chosen model needs a newer engine or isn't available, the chat says so and offers a way forward instead of a bare "Something went wrong this turn".
- Image and video generation is on its way: the app side is ready, and it opens up in chats once the generation plugin is released.
- Safer in-app updates: the version on screen, the file downloaded and its checksum are bound together, so what gets installed is always the release you see. They're checked again right before installing; a package that doesn't match is discarded and Retry downloads the release on screen again; and an abandoned install can't affect the next one.
- Steadier switching: after a host change, the old host's approval and question cards close instead of covering the new host's requests; picking a model after switching chats never lands on the wrong chat; and a reconnect reads plans, goals and team details again.
- Clearer errors: a subscription whose models can't be read says "Couldn’t load models" with Retry instead of "No models"; team messages that fail to load no longer look like an empty inbox; a forum notification page that fails to load more can be retried; and a Bot or group page opened directly tells offline, relay and a Bot that's gone apart.
- Other fixes: timers, animations and held terminal keys stop when the app goes to the background; neighbouring progress lines no longer repeat; Settings › Diagnostics shows whether the engine started directly or in compatible mode, offers a one-tap switch back after a failed direct start, and the app's own errors go into the diagnostics bundle; plugins can no longer change the permission mode from their UI; and the open-source notices are complete.

## 0.9.7 · 2026-10-28

### 中文

- 设置重新整理：首页按 AI、能力、外观、通用、主机、帮助与关于分组，每一行直接显示当前状态。顶部新增搜索，旧名字、同义词都能搜到，点结果会直接跳到那一项；在抽屉里按住 ⚙ 也能进入搜索。新增「个性化」「界面」「隐私与分享」「关于 dsh-go」几页。
- 几处改名：模型渠道 → 模型，引擎 → 本机引擎，引擎设置 → 引擎参数，后台保活 → 后台运行，语音识别 → 语音输入；「自动执行命令」并入权限里的「完全权限」。抽屉身份栏的圆键改为「全部功能」，全部功能也重新分组。
- 分享卡片的二维码中间加上了 dsh-go 图标，并略微放大，截图压缩后也更好扫。链接太长、印出来扫不出的卡片不再放二维码。
- DS Bot：视图卡里的选择题和简单表单可以直接在 App 里作答提交；群聊断线或补读失败后会自动接上；全文弹层的字数加上千分位。
- 插件设置里 App 编辑不了的部分，统一显示一行「在网页版编辑此项」。插件卸载、更新、允许构建脚本时如果已经切换了主机，会提示「主机已切换，未执行」。
- 切换主机后，斜杠命令的结果、「本对话都允许」和用量统计都只作用于原来的主机和对话。

### English

- Settings, reorganised: the home page groups everything under AI, Capabilities, Appearance, General, Hosts, and Help and about, and each row shows its current state. Search at the top finds old names and synonyms and takes you straight to the setting; you can also hold ⚙ in the drawer to search. New pages: Personalization, Interface, Privacy and sharing, and About dsh-go.
- A few renames: Model providers → Models, Engine → Local engine, Engine settings → Engine parameters, Keep alive → Background running, Speech recognition → Voice input; "Run commands automatically" is now Full access under Permissions. The drawer's round button opens All features, which is regrouped too.
- Share cards carry the dsh-go icon in the middle of the QR code, a little larger so it still scans from a compressed screenshot. A card whose link is too long to scan no longer prints a code.
- DS Bot: answer choice questions and simple forms in view cards right in the app; group chats pick up again after a dropped feed or a failed catch-up read; and the full-text sheet groups its character count.
- Plugin settings the app can't edit show one "Edit this item on the web" row. Uninstalling, updating or allowing a plugin's build scripts after you've switched hosts now says "Host changed — nothing was done".
- After switching hosts, a slash command's result, "allow all in this conversation" and usage figures stay with the host and conversation they came from.

## 0.9.6 · 2026-10-28

### 中文

- 手机操控：在别的 App 里遇到需要你确认的操作，也会弹出 dsh-go 的确认卡；任务完成后回到发起它的那个对话，系统不允许自动切回时改用一条通知。手机操控 › 进阶 › 后台确认与返回，可以查看各品牌手机的设置方法。
- 插件设置原生化：多选、列表、日期、颜色、链接、滑块、折叠分组等都能直接在 App 里编辑，只有个别不支持的项会显示「在网页版编辑此项」。字段说明完整显示；保存要等主机确认，失败时保留你的输入。语音输入类插件有了自己的「语音设置」。
- 列表不再等引擎：模型、渠道、插件和对话列表在引擎启动或重连时先显示上次的结果，后台更新完成后替换；读取大列表时界面照常滑动。
- DS Bot：主机上的 DS Bot 还不支持手机端时会直接说明，并提供网页版入口；群聊达到转发上限后可以一键继续；可以为 Bot 或群聊选择工作目录、从详情页复制一个 Bot；主机还在统计用量时显示「—」而不是 0；刷新记忆时内容保留在屏幕上。
- 切换更稳：换对话或换主机后，迟到的结果不会落到别处，包括附件、撤回、分叉、重新回答、Bot 的回答与审批，以及插件的安装、卸载和更新。断线重连后，先同步完对话再允许发送。
- 输入：外接键盘在输入法上屏后按 Ctrl+Enter 即可发送，连按两次 Esc 停止；模型渠道的 Base URL 和联网搜索地址使用普通网址键盘。
- 其他：后台任务的通知显示为一行安静的状态，不再像你发出的消息；SSH 导入私钥限制在 64 KiB；定时任务读取系统时区更可靠；诊断包里记录网络（DNS）设置，便于排查连不上的问题。

### English

- Phone control: when an action needs your OK while you're in another app, dsh-go's confirmation card now appears there too. When a task ends you're taken back to the chat that started it, or, where the system doesn't allow that, you get a notification. Phone control › Advanced › Confirmations and return shows how to set this up on each phone brand.
- Native plugin settings: multi-select, lists, dates, colours, links, sliders and collapsible groups can all be edited in the app; only the odd unsupported field shows "Edit this item on the web". Field descriptions show in full, saves wait for the host to confirm, and a failed save keeps what you typed. Voice input plugins get their own Voice settings.
- Lists don't wait for the engine: models, providers, plugins and chats show their last result while the engine starts or reconnects, then update in place, and large lists load without stalling the screen.
- DS Bot: when the host's DS Bot isn't on mobile yet, the app says so and offers DSH Web. A group that hits its relay limit can carry on in one tap; Bots and groups can have a working folder; you can duplicate a Bot from its details; usage shows "—" rather than 0 while the host is still counting; and refreshing memory keeps it on screen.
- Steadier switching: after you change chats or hosts, late results never land somewhere else. That covers attachments, withdrawals, forks, regenerated replies, Bot answers and approvals, and plugin installs, uninstalls and updates. After a reconnect, the chat syncs before you can send.
- Typing: with a hardware keyboard, Ctrl+Enter sends after an IME commit and pressing Esc twice stops; a provider's Base URL and web search addresses get a normal URL keyboard.
- Other fixes: background task notices show as a quiet status line instead of looking like your own message; SSH private key imports are capped at 64 KiB; schedules read the phone's time zone more reliably; and the diagnostics bundle records network (DNS) settings to help track down connection problems.

## 0.9.5 · 2026-10-27

### 中文

- 分享重新设计：消息下方的「分享」打开同一个面板，选好范围（这条回复、选中的消息、整段对话），再选链接、图片、文件或文字。是否包含思考过程、工具调用和图片只设一次，对每种方式都生效。「我的分享链接」随时可以管理和停止分享。点赞和点踩已移除。
- 首次启动更快上手：选择在本机运行后，运行环境在后台准备，同时就能挑外观、连接 DeepSeek；进度一直显示在底部，完成后自动进入。
- 设置 › 界面新增「性能」：自动、完整、轻量。配置较低或手机发热时自动减少模糊与动效，降温后恢复。
- 语音输入更可靠：系统语音识别出错时自动改用引擎转写；可以在设置 › 对话 › 语音识别里选择方式，出错时提示具体原因。
- 对话页：内容不满一屏时从顶部开始，往上翻不再有大片空白；一轮结束时过程收起不再跳动。
- 宠物悬浮窗不会再出现两只；停止和发送只作用于当前连接，重连后也能正常停止。
- 弹出面板只保留一种关闭方式：能下拉的只有顶部把手，编辑类保留 ×；有未保存的输入时，下拉会先确认。
- 插件：原生界面支持更丰富的文字样式与配色，以及输入框、滑块、开关、下拉、日期、评分、表单、页签、折叠等控件；插件可以请你选择文件或图片；插件详情显示加载状态与原因；本地插件可以一键重载；会话页签里能直接打开插件的网页面板。
- 其他：大字号下恢复选项完整显示；本机运行环境无法启动时直接说明原因；空工作区会提示旧对话在「全部对话」里。

### English

- Sharing, redesigned: Share under a message opens one panel. Pick what to share (this reply, selected messages or the whole chat), then a link, an image, a file or text. Whether to include thinking, tool calls and images is set once and applies to every option. My shared links lets you manage or stop sharing at any time. Like and dislike are gone.
- A faster first run: after you choose to run on this phone, the runtime gets ready in the background while you pick a look and connect DeepSeek. Progress stays at the bottom, and the app opens by itself when it's done.
- Settings › Interface › Performance: Auto, Full or Light. On lower-end or hot phones, blur and motion ease off automatically and come back when it cools down.
- More dependable voice input: when the system recognizer fails, the app switches to engine transcription. Choose the method in Settings › Chat › Voice recognition; errors now say what went wrong.
- Chats: a short chat starts at the top, with no empty space when you scroll up, and a finished turn folds away without a jump.
- The pet overlay no longer shows up twice, and Stop and Send act on the current connection, so stopping still works after a reconnect.
- Sheets close one way: draggable sheets have just the handle, editing sheets keep ×, and dragging away unsaved input asks first.
- Plugins: native views get richer text styles and colours plus text fields, sliders, switches, dropdowns, dates, ratings, forms, tabs and collapsible sections; plugins can ask you to pick a file or photo; plugin details show load status and why; local plugins reload in one tap; and a session's tab can open a plugin's web panel.
- Other fixes: recovery options show in full at large text sizes; a local runtime that can't start says why; and an empty workspace points to All chats for earlier chats.

## 0.9.4 · 2026-10-27

### 中文

- 网页模式更跟手：弹出键盘不再卡顿，侧栏开合更快。
- 打开 App 更快，引擎和界面同时启动。
- 远程主机连接更可靠：兼容新版 DSH Remote 服务端，用加密私钥连接 SSH 时界面不再卡住，版本不匹配时直接提示更新；远程主机页可以关闭「连接上次使用的主机」。
- 工具读取的图片和手机截图，展开卡片就能看到缩略图。
- 在手机共享存储里新建文件不再失败；手机操控不会因为别的对话结束而提前收起或跳回 App。
- 对话里：提问卡可以选「不回答」，斜杠命令只显示一行，被插件接走的消息不再一直显示发送中，回到底部的按钮不再闪烁，横屏打字时总留着一段对话。
- 插件与模型：插件开关在列表重排后不再错位，部分插件的设置页不再空白，自定义渠道里的同名模型不再被误认成已选中。
- 其他修复：代码里的 <=、-> 不再连成一个符号；看图时顶栏不再出现灰块；新对话的默认权限不再存成只对当前对话有效的「自动」；消息里的文件链接和图片打开的是正确的文件；引擎启动卡住时会停下并说明原因。

### English

- Web mode feels snappier: the keyboard no longer stutters, and the sidebar opens and closes faster.
- The app opens faster: the engine starts alongside the interface.
- More reliable remote hosts: works with newer DSH Remote servers, SSH with an encrypted private key no longer freezes the app, and a version mismatch tells you what to update. You can turn off Connect to the last host on the remote hosts page.
- Images read by tools and phone screenshots show as thumbnails when you expand the card.
- Creating files in the phone's shared storage no longer fails, and phone control no longer wraps up or jumps back to the app when a different chat finishes.
- In chats: question cards can be skipped, a slash command shows as one row, a message a plugin picked up no longer stays "sending", the jump-to-bottom button no longer flickers, and typing on a phone on its side always leaves a strip of chat.
- Plugins and models: plugin switches stay with their plugin when the list reorders, some plugin settings pages are no longer blank, and a model with the same name in a custom provider no longer looks selected.
- Other fixes: <= and -> in code no longer merge into one symbol; the image viewer's top bar no longer shows a grey block; the new-chat default permission can no longer be saved as the current-chat-only Auto; file links and images in messages open the right file; and an engine stuck while starting stops and tells you why.

## 0.9.3 · 2026-10-26

### 中文

- 插件可以直接朗读回复，你一开口就停下，还能显示字幕。
- 内置使用说明：直接问 App 里的 AI 怎么用，回答里一点就跳到对应页面。
- 静止时更省电：历史命令不再一直转圈，宠物隐藏时不再走帧。
- 手机操控暂停后不再自动恢复，等你点「继续」。
- 消息里的文件链接可以点开；写成 example.com 的网址在浏览器打开。
- 其他修复：分叉后的提示不再挡住输入框，切换语言后插件文字立即更新。

### English

- Plugins can read replies aloud, stop the moment you start talking, and show captions.
- A built-in guide: ask the AI in the app how anything works, then tap straight to the right page.
- Less battery drain at rest: the command history no longer spins forever, and a hidden pet no longer draws frames.
- Paused phone control no longer resumes on its own; it waits for you to tap Continue.
- File links in messages now open, and addresses written like example.com open in your browser.
- Other fixes: the notice after branching a chat no longer covers the composer, and plugin text follows a language change right away.

## 0.9.2 · 2026-10-26

### 中文

- 插件可以直接用原生界面呈现：工具结果卡片、输入框上方的快捷按钮和状态条、消息长按菜单里的插件操作，以及对话详情和全部功能里的插件面板。
- 手机操控的悬浮条默认常驻，闲置时自动变淡，也可以手动收起；自动收成小球改为可选。
- 「已复制」「已保存」这类提示更短，看一眼就走。
- 在 App 里直接检查并安装内测更新。
- 其他打磨：宠物站在输入框上方最上面那一条；让 AI 装好的插件，回复一结束就能用。

### English

- Plugins can now show up natively: tool result cards, quick buttons and a status line above the composer, actions in a message's long-press menu, and plugin panels in chat details and All features.
- The phone-control floating bar now stays put by default, fades when idle and can be tucked away by hand; folding into a small ball is now optional.
- Confirmations like "Copied" and "Saved" are shorter and get out of the way.
- Check for and install beta updates right in the app.
- More polish: your pet stands on the topmost bar above the composer, and a plugin the agent installs is ready as soon as the reply ends.

## 0.9.1 · 2026-10-25

### 中文

- 「模型渠道」里自己添加的模型，可以逐个设置上下文长度、最大输出、输入类型和思考档位。
- 手机操控时，悬浮条闲置一会儿就缩成小球，不挡屏幕；任务完成后自动回到对话，悬浮条一并收起。
- 首次使用可以只连远程主机，手机上不必安装运行环境；本机运行环境随时可以在设置里安装或卸载。
- 其他细节修复与打磨。

### English

- Models you add under Model providers can each have their own context length, max output, input types and thinking levels.
- During phone control, the floating bar shrinks to a small ball when idle, out of your way. When a task is done, you're back in the chat and the bar tucks away.
- On first launch you can connect to a remote host alone, with nothing to install on the phone. Install or remove the on-device runtime any time in Settings.
- Smaller fixes and polish.

## 0.9.0 · 2026-10-25

### 中文

**宠物**

- Deepy 小鲸鱼和鲸娘住进 App，趴在输入框和思考条上，干活、等你确认、完成时各有动作和气泡。
- 打开「App 外显示」，宠物跟着你到桌面；有事冒个气泡，点一下直达那段对话。

**网页模式**

- 原生界面和网页版一键切换，下次打开停在你上次用的那个。
- 网页版里也有 App 的按键，通知、分享、切换主机都落在同一段对话上。

**横屏与平板**

- 横屏手机和平板重新排版：内容居中限宽，弹窗和分享预览按屏宽排布，横屏弹出键盘也不挤。
- 网页版横屏用官方桌面布局，避开刘海和手势条。

**English**

- 全部界面支持英文，在设置里切换，默认跟随系统。

**主题与图标**

- 全新 App 图标，界面图标整套重绘。
- 六套主题色：雾蓝、黛青、暮紫、松石、琥珀、石墨，也可以跟随壁纸或自选颜色。
- 四款桌面图标：雾蓝、夜幕、霜白、墨。
- 功能磁贴三种风格：扁平双色、极简几何、玻璃渐变。

**对话**

- 回复中途也能插话：消息先排队，点「立即发送」就打断当前回复。
- 停下时，排队的消息马上发出；没送达的标为「未发送」，可以再发或撤回。
- 过程自动折叠，插过话的回合也分段收好；长对话的过程不再缺失。

**分享**

- 分享卡片带上消息里的图片，五种模板：浅色、深色、卡片、纸张、玻璃；多轮对话可以拼成一张长图。
- 整段对话可以分享成文件或链接，对方在浏览器里回放，或在 dsh-go 里接着聊。链接端到端加密，在「我的分享链接」里管理。

**更稳**

- 系统省电拦住后台时，App 会提醒，并直达对应的放行设置，vivo、小米、华为、荣耀、OPPO 都有。
- 重置引擎默认保留界面配置和技能，已装插件和设置也可以一并保留。
- 插件的网页界面可以直接嵌在 App 里打开。
- 本机网页版只接受 App 自己的访问。

### English

**Pets**

- Deepy and Whale girl now live in the app. They perch on the composer and the thinking bar, and react when DSH is working, needs you, or is done.
- Turn on "Show outside the app" and your pet comes along to the home screen. It pops a bubble when something needs you; one tap takes you to that chat.

**Web mode**

- Switch between the native and web interfaces in one tap. The app reopens in whichever you used last.
- The web interface has the app's keys too, and notifications, sharing and host switching all land on the same chat.

**Landscape and tablets**

- New layouts for landscape phones and tablets: content stays centered, dialogs and share previews use the width, and the keyboard no longer crowds a landscape screen.
- The web interface uses the official desktop layout in landscape and keeps clear of the notch and gesture bar.

**English**

- The whole app is now available in English. Switch in Settings; by default it follows your system.

**Themes and icons**

- A new app icon, and every icon in the app redrawn.
- Six accent colors: Mist, Teal, Dusk, Aqua, Amber and Slate. Or match your wallpaper, or pick your own.
- Four home screen icons: Mist blue, Nightfall, Frost white and Ink.
- Three feature tile styles: Duotone, Geometric and Glass.

**Chats**

- Chime in while DSH is replying. Your message waits its turn, or tap "Send now" to interrupt.
- Stopping sends queued messages right away. Anything that didn't get through is marked "Not sent", ready to send again or withdraw.
- Process steps fold away on their own, including turns you chimed into, and long chats keep every step.

**Sharing**

- Share cards now include the message's images and come in five templates: Light, Dark, Card, Paper and Glass. Several rounds can be stitched into one long image.
- Share a whole chat as a file or a link. Others replay it in the browser or pick it up in dsh-go. Links are end-to-end encrypted; manage them in "My shared links".

**More reliable**

- When the system's battery saver holds DSH back in the background, the app tells you and opens the right setting, on vivo, Xiaomi, Huawei, Honor and OPPO.
- Resetting the engine keeps your interface settings and skills, and can keep installed plugins and settings too.
- Plugin web interfaces open right inside the app.
- The local web interface only answers to the app itself.
