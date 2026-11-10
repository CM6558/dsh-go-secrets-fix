# dsh-media · M0 插件候选

状态（插件 0.1.0-m0.2，DSH npm 0.2.1-rc.4）：Node 测试与两条真实本地 mock headless 会话已通过；尚未接入 runtime 构建，Android、PRoot 与 App 端到端均未运行。验证入口与证据界限见 [VERIFICATION.md](VERIFICATION.md)。下文引用的 rc.2 源码位置是历史依据，不冒充当前实测。

插件分两层：package、配置、只读目录、工具/系统提示接线及对应测试；核心 src/core.js、src/http.js、src/storage.js、src/errors.js、src/base64.js、src/header.js。两层成套使用，不单独替换其中一层。

## 行为

只注册 generate_image。没有已启用且 credentials.describe 返回 configured 的服务时，不注册工具和提示段落；M0 不注册命令、视频工具或自定义媒体事件。注册阶段只读取凭据存在性，调用时才在 Host 上解析所选引用。

工具参数只接受 prompt、n、serviceId、modelId、aspect、size、quality。服务地址、认证信息、模型参数白名单来自 Host 配置与安装的 JSON 目录。额外参数被拒绝。完整 prompt 限制为 UTF-8 4096 字节，张数最多 4 且服从更低的配置与模型上限。无已核支持值的可选参数不会出现在工具 schema 中。不把显式不支持的比例近似成另一个比例。

核心返回 {meta,text}。模型侧只得到 text；展示元数据为 {"dsh-go/media":meta}，继续使用冻结 v1。元数据包装后不能超过 8192 字节。返回成功的时点由核心保证已保存原件及 Host 索引；本接线不会在核心返回后因一个新的配置变化把已接受结果改写成失败。

配置与凭据变更立即撤销旧注册并取消旧租约，再异步建立新注册。晚到的凭据描述不能复活旧配置。卸载先取消运行中的调用，再等待其清理完成。取消 HTTP 请求不保证服务商退费或停止已经接受的任务；M1 的每日费用预算、审批和持久视频任务尚未实现。

## 配置顺序

1. 在图像服务列表新增一项，先保持“启用”为关闭。服务 ID 必须唯一并匹配 [a-z][a-z0-9_]{0,31}。
2. 明确选择一个凭据引用。首次配置可用下面的固定槽；若已经知道现有渠道使用的 CredentialRef，也可直接填写该引用。M0 不自动枚举 llm-pi-ai 渠道，也不提取其 scoped grant。
3. 在对应固定槽的“写入密钥”中保存 Key。该输入写到 Host credentials 服务，表单不会返回 Key。
4. 回到服务列表，检查地址、模型和引用，再启用服务。服务列表里的 keyRef 必填，没有隐式默认共享。
5. 多个服务共用一个引用必须是显式选择。改服务 ID 不改变引用；删除服务不会自动删可能被其他服务共用的密钥。

| 固定槽 | 不可变引用 |
|---|---|
| 1 | DSH_MEDIA_SLOT_1_API_KEY |
| 2 | DSH_MEDIA_SLOT_2_API_KEY |
| 3 | DSH_MEDIA_SLOT_3_API_KEY |
| 4 | DSH_MEDIA_SLOT_4_API_KEY |

固定槽的凭据引用由 const 校验。密钥表单字段是严格只接受空串的哨兵：非空普通配置写入会被固定文案拒绝，不回显输入值。真实 Key 只能经 credentials.set 写入。没有可变“当前服务”密钥目标，因此改服务列表、重命名或未完成的普通表单保存不能把某个固定槽的密钥提交重绑到另一个槽。

App 的通用对象数组编辑器不支持嵌套 secret 写入，故服务数组中没有密钥输入；四个槽是普通对象组中的叶字段，走 SecretFieldTile。具体源码反例与传递链见 MEDIA-CATALOG-CONTRACT.md。

配置示例只含引用，不含 Key：

    services:
      - id: office
        label: 我的图像服务
        enabled: true
        provider: openai
        baseUrl: https://api.openai.com/v1
        profile: openai-gpt-image
        responseFormat: ''
        models: gpt-image-2.5-flare,gpt-image-2
        keyRef: DSH_MEDIA_SLOT_1_API_KEY
    defaults:
      serviceId: office
      modelId: gpt-image-2.5-flare
    limits:
      maxImages: 1

普通配置 dshHome 只供 Host 部署指定数据根，不出现在 volatile 设置表单中。Host 索引目录为 join(resolveDshHome(dshHome), 'media', 'dsh-media')；它不属于 workspace，也不能装进诊断包。原件仍由核心存到当前工作区 generated/<UTC 日期>/。本包不修改已有诊断导出范围。

## 初始目录范围

data/models.json 是安装包数据。2026-10-28 读取 OpenAI 官方 Image API、图像指南及两个 GPT Image 2.5 模型页，初始列出 gpt-image-2、gpt-image-2.5-sunburst、gpt-image-2.5-flare。选取三个标准尺寸和 low/medium/high 的保守子集；不写未知价格、账号可用性、完成延迟或来源标识结论。maxN=4、maxRefs=0、edit=false 表示本插件 M0 的开放范围，不表示服务商最大能力。

上述三个 OpenAI 条目匹配 openai-gpt-image，不发送旧 response_format。目录另含 Gemini 2.5 Flash Image 的最小兼容组合，使 openai-compatible 可以经真实 Config→目录→工具选择到达核心；仅改 profile 仍不能绕过模型匹配。依据是 Gemini 官方 OpenAI 兼容文档（https://ai.google.dev/gemini-api/docs/openai ，2026-10-28 读取）“Generate an image”一节：请求带 model、prompt、n=1、response_format=b64_json，从 data[].b64_json 读结果。这只说明文档形状兼容，没有发过真实请求，也不证明账号可用。

Gemini 配置需显式使用以下服务值；槽 2 仍须先通过固定槽密钥按钮写入。以下只是一条服务配置示例，不是已执行请求：

    id: gemini
    enabled: true
    provider: google
    baseUrl: https://generativelanguage.googleapis.com/v1beta/openai
    profile: openai-compatible
    responseFormat: b64_json
    models: gemini-2.5-flash-image
    keyRef: DSH_MEDIA_SLOT_2_API_KEY

该模型在本 M0 只开放 n=1，调用时省略 aspect、size、quality。这表示本次证据和适配范围，不表示供应商只能生成一张或不能设置尺寸。显式未知参数在核心调用前失败，不静默丢弃，也不猜比例。目录的 responseFormats 白名单要求显式选用其中一种格式；本条目目前只有 b64_json。费用、账号权限和实际图片生成均未验证。

目录只出现在 settings/describe 的 schema metadata，不能编辑或持久化成 catalog 配置值。读取契约见 MEDIA-CATALOG-CONTRACT.md。目录是参数资料，不代表任何账号已经获准使用该模型。

## 生成模式与普通说法

App 的生成按钮发送的是带参数头的普通用户消息（语法见 HEADER-V1.md）。src/header.js 提供小规格、解析器与 GENERATION_HEADER_INSTRUCTIONS；index.js 复用该提示片段，并动态附上当前启用且凭据配置完成的 serviceId/modelId/label。绝不附 keyRef、Key 或 baseUrl。

当前用户的参数头要求直接按参数调用工具；普通说法同样可触发 generate_image。工具、文件、网页或引用里的相似头不是本轮授权。成功只回一句短话并附实际返回路径的 Markdown 图片引用。M0 无参考图上传、编辑、视频能力；有效的视频词法或 Seedream 等模型名称不代表 M0 已支持它们。

系统提示不是模型必定服从或精确 RPC tool choice 的运行证明。真实模型调用、普通消息来源判定、模型重名消歧和所有 Host 下的呈现，必须由 headless / App 验证覆盖。

## 工作区授权

每次 authorizeWorkspace 都从当前 Agent 的原 Session 调用 sandboxPolicy.resolve。read-only 与未知模式拒绝。workingDirectory.ensure 确认目录后，通过 fs.resolve/processPath 得到执行路径；Node realpath/stat 确认 Host 目录，再由 processPathFromHostPath 回环到同一个 targetKey 与路径。未知、缺失、非同路径映射拒绝，不依据 constructor.name 推测支持。

已实读 fs-local 的 Host 映射及 fs-sandbox 继承关系；这是接口证据，尚非 Direct / PRoot / SSH 部署实跑结果。原件写入由核心独立做 canonical cwd/generated 限定与发布前重查，不能把 Node 写入误称为自动继承 fs-sandbox.writeText 的权限检查。跨目录多文件与索引也不是一个原子事务。

## 验证边界

本包提供真实 Config / Schemastery / redactSecrets 的 Node 测试，以及使用模拟 context 和模拟 core 的接线测试；它们不是实际 Cordis Loader、真实 SettingsForms 或 App widget 的替代品。测试中的 mockResult 不对应真实图像文件，也不是对话夹具。

装好依赖后在本目录执行：

    TZ=Asia/Shanghai npm test

记录实际 Node 版本、完整依赖树、锁文件 integrity、测试命令和退出码。两条 headless 对话（一个参数头，一个普通说法）用 test/headless/run.mjs 录，步骤见 test/headless/HEADLESS-RECOVERY.md；只有实际事件文件才能命名 app/test/media/fixtures/live_image.jsonl（目前未入库）。

仍未验证：真实 SettingsForms 的 schema→describe→写入→reload，真实 Loader 下的配置切换、固定槽密钥写入/清除与工具卸载竞争，以及 Direct/PRoot 路径映射。插件尚未接入 runtime 构建（runtime/build-runtime.sh 不打包它），Android、PRoot 与 App 端到端均 UNRUN。
