# dsh-media M0 验证索引

当前对象：插件 0.1.0-m0.2，依赖 DSH npm 0.2.1-rc.4。所有命令显式 `TZ=Asia/Shanghai`，工作目录 `runtime/media/dsh-media`。

已实际执行：

- Node 测试：`TZ=Asia/Shanghai npm test`（即 `node --test test/*.test.js`），须先按 package.json 装好依赖。历史记录：2026-10-28 在 rc.4 依赖、Node v24.22.1 上 108 项全部通过。缺依赖时只有不引用 npm 包的用例能跑，例如参数头测试。
- 参数头：`test/header.test.js` 直接读 App 的共享 golden `app/test/media/fixtures/header_grammar_v1.json`，不依赖 npm 包。
- headless：两条真实本地 mock 会话（参数头一条、普通中文一条）曾实际通过，事件与物理日志逐对象一致、原件和 Host 索引写入、正常关闭、假凭据不回显。步骤、缺少的输入与证据界限见 `test/headless/HEADLESS-RECOVERY.md`。这两条会话的事件记录没有入库；`app/test/media/fixtures/` 里的 `synthetic_*.jsonl` 是合成夹具。

未执行：Flutter、Dart、Android、PRoot、runtime 构建接入（`runtime/build-runtime.sh` 目前不打包本插件）、完整 runtime/test-host、真实付费 provider、真实模型语言理解、全面 Loader 生命周期故障和 OS 关闭失败注入。历史的纯 JS 故障模型不算实跑。

golden：`test/fixtures/header-v1.json` 是早期语法候选，测试不再读取；语法以 App 的共享 golden 为准。两条 headless 会话是不同的真实 Session，不可拼接，也不改路径冒充手机产物。生产图像不重新编码；合成 1×1 PNG 只验证真实文件和元数据流程。

不需要代码生成命令。
