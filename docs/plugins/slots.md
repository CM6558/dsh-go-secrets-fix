# 插槽参考

工具卡之外，插件还能在 dsh-go 的四个原生位置出现。位置由 `package.json` 里的 `dshGo` 清单声明，内容由宿主半侧（插件在引擎里跑的 Node 代码）通过 `ctx.dshGo` 提供。规格原文：`docs/design/native-plugins-protocol.md`。

| 插槽（surface） | 原生位置 | 条目字段 | 每插件 | 文字上限 | 点按 |
|---|---|---|---|---|---|
| `composer.actions` | 输入框上方的胶囊行，和用户在 ui.json 里写的胶囊同一行 | `id`、`label`、`icon?`、`effect?` | 2 | `label` 10 字 | 有 `effect` → App 直接执行；没有 → invoke `on(id)` |
| `message.actions` | 助手消息长按菜单，按插件分组，组名是插件 `title` | 同上 | 2 | `label` 12 字 | 同上 |
| `composer.strip` | 输入框上方一行；生成回复时让位；多个插件轮流 | `id`、`icon?`、`text?`、`panel?` | 1 | `text` 24 字 | 有 `panel` → 打开它；否则 invoke `on(id)` |
| `panels` | 对话详情页「插件」页签、全部功能、聊天页面板 | `id`、`title`、`icon?`、`placement?`、`view?` | 4 | `title` 16 字 | 视图里的按钮、行、选项 → invoke |

工具卡（`presentationMeta`）不占插槽，不需要清单，见[快速开始](quickstart.md)。

## 清单

```jsonc
// package.json
"dshGo": {
  "v": 1,
  "title": { "zh": "快捷", "en": "Quick" },
  "icon": "bolt",
  "wants": ["clipboard", "message"],
  "contributes": {
    "composer.actions": [
      { "id": "summarize", "label": "总结", "icon": "summary",
        "effect": { "type": "insert", "text": "总结上面的对话，列三条要点。" } },
      { "id": "translate", "label": { "zh": "译成英文", "en": "To English" }, "icon": "translate" }
    ],
    "message.actions": [{ "id": "copy-md", "label": "复制为 Markdown", "icon": "document" }],
    "composer.strip":   [{ "id": "today", "icon": "chart", "panel": "usage" }],
    "panels":           [{ "id": "usage", "title": "用量", "icon": "chart", "placement": ["session.tab", "features"] }]
  }
}
```

| 字段 | 必填 | 规则 |
|---|---|---|
| `v` | 是 | 写 `1` |
| `minApp` | 否 | `"x.y.z"`。App 低于它时原生部分不显示 |
| `title` | 否 | 插件显示名，≤ 24 字；缺省用包名 |
| `icon` | 否 | 图标名（见下）；不认识的画通用图标 |
| `wants` | 否 | 点按时要附带的内容：`draft`（输入框文字）、`clipboard`（剪贴板）——只在 `composer.actions`；`message`（被长按的回复正文）——只在 `message.actions`。App 在第一次点按前问用户一次 |
| `assets` | 否 | 图片目录（相对包目录），给 `image` 组件用 |
| `contributes` | 是 | 键是插槽名，值是数组 |

- 文字字段（`title`、`label`、`text`）可以写字符串，或 `{ "zh": "…", "en": "…" }`。按 App 语言取：完全匹配 → 语言部分 → `en` → `zh` → 第一个。
- `id`：`^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$`，**同一插件内所有插槽的 id 不能重复**。
- 整个 `dshGo` ≤ 16 KiB。
- 一项写错只丢那一项，其余照常；错在哪里，插件详情页「原生界面」一行能看到，`check` 也会列出。

图标名（162 个，胶囊、菜单、面板和视图里通用）：bolt star sparkle heart flag bookmark pin bell clock alarm calendar todo note document folder search code terminal globe chart lightbulb book puzzle robot chat mail translate image camera mic link summary wrench bug travel school home play refresh archive team wallet palette coin money speaker read copy quote share edit write save paste add remove delete clear fork regenerate reply select-text qr download downloads external info warning check done success error question pending running tip list table panel sidebar menu more expand collapse file folder-open workspace storage pdf zip slides article text diff gallery audio music video video-file play-video pause stop replay generate-image generate-video diagram plugin bot agent skill model tool workflow goal plan job automation command trajectory web web-search browser history time today timezone schedule repeat reminder user account group chats mention invite announcement reaction poll notification send community forum feedback wechat qq telegram discord phone computer cloud server power restart retry theme color text-size pet featured badge favorite settings

## 宿主半侧：`ctx.dshGo`

```js
export function apply(ctx) {
  ctx.inject(['dshGo'], (ctx) => {          // 只有装了 dsh-go 桥接的主机才会进来
    ctx.dshGo.on('translate', (scope, event) => ({ insert: `译成英文：\n\n${scope.clipboard}` }))
    ctx.dshGo.strip('today', (scope, emit, caps) => watch(() => emit({ text: label(caps.locale) })))
    ctx.dshGo.panel('usage', {
      view: (scope, caps) => usageView(scope, caps),
      data: (scope, emit, caps) => watch(() => emit(usageData(scope))),
      actions: { copy: (scope, event) => ({ copy: summary(), toast: '已复制' }) },
    })
  })
}
```

**写 `['dshGo']`，不要写 `['dshGo?']`**，也不要把 `dshGo` 放进插件顶层的 `inject`：前者回调永远不执行，后者在没有桥接的主机上整个插件起不来。

| 方法 | 用途 |
|---|---|
| `on(id, handler)` | 胶囊、菜单项、状态条的点按。`handler(scope, event)` 返回效果；慢活返回延后效果（[动作与效果](actions.md)） |
| `strip(id, dataFn)` | 状态条的内容：`dataFn(scope, emit, caps)` 里 `emit({ text, icon?, tone? })`，返回取消函数 |
| `panel(id, { view, data?, actions? })` | 面板：`view` 是视图或 `(scope, caps) => 视图`；`data(scope, emit, caps)` 推数据；`actions` 处理视图里的点按 |
| `refresh(id, scope?)` | 视图结构变了，让 App 重新取 |

**回调参数**

| 名称 | 内容 |
|---|---|
| `scope` | `{ sessionId?, turnId?, messageId?, callId? }`。点按时再带上 `draft` / `clipboard` / `message`（声明了 `wants`、用户同意、插槽对得上才有） |
| `caps` | 视图函数拿到 `{ protocol, app, locale, surfaces, components }`：App 能画什么、什么语言；数据函数拿到 `{ protocol, locale }`，用来按语言推文字 |
| `event` | `{ surface, id, action?, value?, locale }`。面板里的点按：`action` 是视图里的动作 id，`value` 是它的 `args`；`options` → `{ value }` / `{ values }`，`confirm` → `{ confirmed }` |
| `emit(data)` | 每次给**完整**的数据（对象或 `null`）。桥接算差量、限 4 Hz、限 32 KiB。数据里的 `null` 等于缺失 |

回调抛错、超时（3 秒）、返回不合格的东西，桥接都接住，只记一次违规；连续 5 次，这个插件本次运行降级成网页版。

## 每个插槽怎么选

| 想做的 | 用 |
|---|---|
| 一句固定的话放进输入框 | `composer.actions` + 静态 `effect`，不用写宿主代码 |
| 读剪贴板 / 输入框再加工 | `composer.actions` + `wants` + `on(id)` |
| 对某条回复做事：复制、存档、转发到别处 | `message.actions` + `wants: ["message"]` |
| 一眼能看到的数字：用量、余额、上下文 | `composer.strip` + `strip(id)`，点开接 `panel` |
| 一页信息：图表、明细、列表、按钮 | `panels` + `panel(id)` |
| 工具结果画成卡片 | 工具卡，不占插槽 |

## 面板放在哪

| `placement` | 位置 | `scope` |
|---|---|---|
| `session.tab`（缺省） | 对话详情页「插件」页签 | 带 `sessionId` |
| `features` | 全部功能 | 空 |
| `chat.panel` | 聊天页「插件」弹层：输入框上方胶囊行最后一枚「插件」打开，原生面板按插件名排在前，网页插件的聊天页部件在后（见[网页面板](web-panels.md#聊天页插件弹层)） | 带 `sessionId` |

同一个面板可以放多处，视图函数按 `scope.sessionId` 有没有来区分（`session.tab` 和 `chat.panel` 都带）。只有这个对话有东西可放时，「插件」胶囊才出现，不占胶囊 8 个的名额。

## 静态面板

不想写宿主代码，也可以在清单里给一个静态视图文件：`{ "id": "help", "title": "说明", "view": "./views/help.json" }`。文件是严格 JSON、≤ 32 KiB，格式同[组件目录](components.md)。宿主半侧注册了 `panel(id)` 时以注册的为准。
