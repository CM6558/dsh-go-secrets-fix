import { realpath, stat } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { credentialRef } from '@deepseek-ai/dsh-credentials';
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { Config, catalogModel, runtimeSnapshot } from './config.js';
import { generateImage } from './core.js';
import { GENERATION_HEADER_INSTRUCTIONS } from './header.js';
import { MediaError, checkAbort, safeFailure } from './errors.js';

export { Config };
export const name = 'dsh-media';
export const inject = [
  'tools', 'credentials', 'fs', 'workingDirectory', 'sandboxPolicy', 'systemPrompt',
];

export const SYSTEM_PROMPT = [
  GENERATION_HEADER_INSTRUCTIONS,
  '仅在当前用户消息明确要求生成图像时使用 generate_image。',
  'M0 只有文本生成图像；不提供编辑、参考图上传或视频生成。',
  '视频头可以识别，但当前没有视频工具时必须说明不支持，不能替换为图像。',
  '工具失败时简短说明失败，不声称已生成；不得编造图片路径。',
  '密钥、凭据引用和服务地址由主机配置，不能要求模型读取或输出密钥。',
].join('\n');

function promptFor(services) {
  const available = services.flatMap(service => service.modelIds.map(id => ({
    serviceId: service.id, modelId: id, label: catalogModel(id).label,
  })));
  return SYSTEM_PROMPT + '\n当前已启用且凭据已配置的图像模型，仅用于精确匹配：\n'
    + JSON.stringify(available);
}

function under(root, candidate) {
  const rel = relative(root, candidate);
  return rel === '' || (rel !== '..' && !rel.startsWith('..' + sep) && !isAbsolute(rel));
}

/**
 * This is a read-only authorization/mapping adapter, not a binary filesystem API.
 * The core owns all writes and must call this again before billable I/O/publication.
 * Only identity host mappings with a successful provider round trip are accepted.
 */
export function createWorkspaceAuthorizer(ctx, exec, signal) {
  const agent = exec.agent;
  const session = agent?.session;
  const sessionId = session?.id;
  if (!agent || !session || typeof sessionId !== 'string' || !sessionId) {
    throw new MediaError('permission');
  }

  function live() {
    checkAbort(signal);
    if (exec.agent !== agent || agent.session !== session || session.id !== sessionId) {
      throw new MediaError('permission');
    }
    ctx.fiber.assertActive();
    agent.ctx.fiber.assertActive();
  }

  function policy() {
    live();
    const value = ctx.sandboxPolicy.resolve({ session });
    if (!value || !['workspace-write', 'danger-full-access'].includes(value.mode)) {
      throw new MediaError('permission');
    }
    if (typeof value.workspaceRoot !== 'string' || !isAbsolute(value.workspaceRoot)) {
      throw new MediaError('unsupported_backend');
    }
    return { mode: value.mode, workspaceRoot: value.workspaceRoot };
  }

  async function hostDirectory(worldPath, expectedPolicy) {
    const fs = ctx.fs;
    const target = await fs.resolve(worldPath, { signal });
    live();
    const afterResolve = policy();
    if (afterResolve.mode !== expectedPolicy.mode
      || afterResolve.workspaceRoot !== expectedPolicy.workspaceRoot) {
      throw new MediaError('permission');
    }
    const processPath = fs.processPath(target);
    if (typeof processPath !== 'string' || !isAbsolute(processPath)) {
      throw new MediaError('unsupported_backend');
    }
    const canonical = await realpath(processPath);
    live();
    // The provider's execution path must already be the same host path.
    if (resolve(processPath) !== canonical) throw new MediaError('unsupported_backend');
    const info = await stat(canonical);
    live();
    if (!info.isDirectory()) throw new MediaError('unsupported_backend');
    const mapped = fs.processPathFromHostPath(canonical);
    if (typeof mapped !== 'string' || !isAbsolute(mapped)) {
      throw new MediaError('unsupported_backend');
    }
    const roundTrip = await fs.resolve(mapped, { signal });
    live();
    const afterRoundTrip = policy();
    if (afterRoundTrip.mode !== expectedPolicy.mode
      || afterRoundTrip.workspaceRoot !== expectedPolicy.workspaceRoot
      || roundTrip.targetKey !== target.targetKey
      || fs.processPath(roundTrip) !== canonical) {
      throw new MediaError('unsupported_backend');
    }
    return canonical;
  }

  return async function authorizeWorkspace() {
    try {
      const before = policy();
      const cwdWorld = await ctx.workingDirectory.ensure(agent, signal);
      live();
      const currentPolicy = policy();
      if (currentPolicy.mode !== before.mode
        || currentPolicy.workspaceRoot !== before.workspaceRoot) throw new MediaError('permission');
      const cwd = await hostDirectory(cwdWorld, currentPolicy);
      live();
      const workspaceRoot = await hostDirectory(currentPolicy.workspaceRoot, currentPolicy);
      live();
      const after = policy();
      if (after.mode !== currentPolicy.mode
        || after.workspaceRoot !== currentPolicy.workspaceRoot
        || ctx.workingDirectory.get(session) !== cwdWorld) throw new MediaError('permission');
      if (after.mode === 'workspace-write' && !under(workspaceRoot, cwd)) {
        throw new MediaError('permission');
      }
      return { cwd, mode: after.mode, workspaceRoot };
    } catch (error) {
      if (error instanceof MediaError) throw error;
      if (signal.aborted) throw safeFailure(error, signal);
      throw new MediaError('unsupported_backend');
    }
  };
}

const ALLOWED_ARGS = new Set([
  'prompt', 'n', 'serviceId', 'modelId', 'aspect', 'size', 'quality',
]);

function selectedRequest(args, snapshot, readyServices) {
  if (!args || typeof args !== 'object' || Array.isArray(args)
    || Object.keys(args).some(key => !ALLOWED_ARGS.has(key))
    || typeof args.prompt !== 'string' || !args.prompt.trim()
    || Buffer.byteLength(args.prompt, 'utf8') > 4096) throw new MediaError('invalid_request');
  const serviceId = args.serviceId ?? (snapshot.defaults.serviceId || readyServices[0]?.id);
  const service = readyServices.find(item => item.id === serviceId);
  if (!service) throw new MediaError('not_configured');
  const modelId = args.modelId ?? (snapshot.defaults.modelId || service.modelIds[0]);
  if (!service.modelIds.includes(modelId)) throw new MediaError('invalid_request');
  const model = catalogModel(modelId);
  if (!model || model.profile !== service.profile) throw new MediaError('invalid_request');
  const n = args.n ?? 1;
  if (!Number.isSafeInteger(n) || n < 1
    || n > Math.min(snapshot.limits.maxImages, model.maxN)) throw new MediaError('invalid_request');
  for (const field of ['aspect', 'size', 'quality']) {
    if (args[field] !== undefined && (typeof args[field] !== 'string' || !args[field])) {
      throw new MediaError('invalid_request');
    }
  }
  if (args.aspect !== undefined && !Object.hasOwn(model.aspectSizes, args.aspect)) {
    throw new MediaError('invalid_request');
  }
  if (args.size !== undefined && !model.sizes.includes(args.size)) throw new MediaError('invalid_request');
  if (args.quality !== undefined && !model.qualities.includes(args.quality)) {
    throw new MediaError('invalid_request');
  }
  if (args.aspect !== undefined && args.size !== undefined
    && model.aspectSizes[args.aspect] !== args.size) throw new MediaError('invalid_request');
  return {
    request: {
      prompt: args.prompt, n,
      ...(args.aspect === undefined ? {} : { aspect: args.aspect }),
      ...(args.size === undefined ? {} : { size: args.size }),
      ...(args.quality === undefined ? {} : { quality: args.quality }),
      service: {
        id: service.id, provider: service.provider, baseUrl: service.baseUrl,
        profile: service.profile,
        ...(service.responseFormat === undefined ? {} : { responseFormat: service.responseFormat }),
      },
      model: {
        id: model.id, label: model.label, sizes: [...model.sizes],
        qualities: [...model.qualities], aspectSizes: { ...model.aspectSizes },
      },
    },
    keyRef: service.keyRef,
  };
}

/**
 * The dependency argument is an in-process unit-test seam, not a config or tool field.
 * Real startup always calls this with the imported core.
 */
export function installMedia(ctx, config, { generate = generateImage } = {}) {
  const hostStateDir = join(resolveDshHome(config.dshHome), 'media', 'dsh-media');
  const lifetime = new AbortController();
  const operations = new Set();
  let closed = false;
  let epoch = 0;
  let registration;
  let pending = Promise.resolve();

  function retire() {
    const old = registration;
    registration = undefined;
    if (!old) return;
    old.abort.abort(new MediaError('cancelled'));
    for (const dispose of old.disposers.reverse()) dispose();
  }

  function capability(snapshot, services, lease) {
    const ids = [...new Set(services.flatMap(service => service.modelIds))];
    const models = ids.map(catalogModel);
    const maxN = Math.min(snapshot.limits.maxImages, Math.max(...models.map(model => model.maxN)));
    const optionalParameters = {};
    for (const [field, values] of [
      ['aspect', models.flatMap(model => Object.keys(model.aspectSizes))],
      ['size', models.flatMap(model => model.sizes)],
      ['quality', models.flatMap(model => model.qualities)],
    ]) {
      const supported = [...new Set(values)];
      // Empty enum is not a usable optional parameter. Per-model validation
      // still rejects an unsupported argument when services have mixed models.
      if (supported.length) optionalParameters[field] = { type: 'string', enum: supported };
    }
    const tool = defineTool({
      name: 'generate_image',
      description: '按用户要求生成图片并保存到工作区；使用已配置服务，不接受密钥或服务地址。'
        + '可用服务：' + services.map(service => service.id + ' (' + service.modelIds.join(', ') + ')').join('; '),
      parameters: {
        prompt: { type: 'string', required: true, description: '完整图像描述，UTF-8 最多 4096 字节。' },
        n: { type: 'integer', enum: Array.from({ length: maxN }, (_, i) => i + 1) },
        serviceId: { type: 'string', enum: services.map(service => service.id) },
        modelId: { type: 'string', enum: ids },
        ...optionalParameters,
      },
      timeoutMs: 180000,
      isConcurrencySafe: () => false,
      output: {
        schema: {
          type: 'object', additionalProperties: false,
          properties: {
            meta: { type: 'json', required: true },
            text: { type: 'string', required: true },
          },
        },
        render: (_args, value) => [{ type: 'text', text: value.text }],
        presentationMeta: (_args, value) => ({ 'dsh-go/media': value.meta }),
      },
      execute(args, exec) {
        const signal = AbortSignal.any([exec.signal, lifetime.signal, lease.signal]);
        const run = async () => {
          try {
            checkAbort(signal);
            if (closed || registration?.abort !== lease) throw new MediaError('cancelled');
            const selected = selectedRequest(args, snapshot, services);
            const agent = exec.agent;
            const session = agent?.session;
            if (!session || typeof session.id !== 'string') throw new MediaError('permission');
            const authorizeWorkspace = createWorkspaceAuthorizer(ctx, exec, signal);
            const result = await generate(selected.request, {
              resolveCredential: async () => {
                checkAbort(signal);
                ctx.fiber.assertActive();
                agent.ctx.fiber.assertActive();
                if (agent.session !== session) throw new MediaError('permission');
                const value = await ctx.credentials.resolve(credentialRef(selected.keyRef));
                checkAbort(signal);
                ctx.fiber.assertActive();
                agent.ctx.fiber.assertActive();
                if (agent.session !== session) throw new MediaError('permission');
                if (!value || typeof value.value !== 'string' || !value.value) {
                  throw new MediaError('credential');
                }
                return value.value;
              },
              authorizeWorkspace, hostStateDir, sessionId: session.id,
              signal, limits: { ...snapshot.limits },
            });
            // Core returns only after its files and host index are committed.
            if (!result || typeof result.text !== 'string' || !result.meta
              || Buffer.byteLength(JSON.stringify({ 'dsh-go/media': result.meta }), 'utf8') > 8192) {
              throw new MediaError('metadata');
            }
            return result;
          } catch (error) {
            throw safeFailure(error, signal);
          }
        };
        const operation = run();
        operations.add(operation);
        void operation.then(
          () => operations.delete(operation),
          () => operations.delete(operation),
        );
        return operation;
      },
    });
    // defineTool's validator closes over this same parameters object in rc.2.
    // Manual rejection above remains a second boundary for future helper changes.
    tool.parameters.additionalProperties = false;
    return tool;
  }

  async function refresh() {
    const mine = ++epoch;
    retire();
    if (closed) return;
    let snapshot;
    try { snapshot = runtimeSnapshot(config); } catch { return; }
    const descriptions = await Promise.allSettled(snapshot.services.map(async service => ({
      service,
      info: await ctx.credentials.describe(credentialRef(service.keyRef)),
    })));
    if (closed || mine !== epoch) return;
    const services = descriptions.flatMap(result => result.status === 'fulfilled'
      && result.value.info.configured === true ? [result.value.service] : []);
    if (!services.length) return;
    const abort = new AbortController();
    const next = { abort, disposers: [] };
    registration = next;
    try {
      ctx.fiber.assertActive();
      next.disposers.push(ctx.tools.register(capability(snapshot, services, abort)));
      next.disposers.push(ctx.systemPrompt.section({
        name: 'dsh-media', order: 520, text: promptFor(services), interpolate: false,
      }));
    } catch {
      retire();
    }
  }

  function scheduleRefresh() {
    pending = refresh();
    // Event dispatch never receives an unhandled rejection or secret-bearing error.
    void pending.catch(() => { retire(); });
    return pending;
  }

  async function dispose() {
    if (closed) return;
    closed = true;
    epoch += 1;
    lifetime.abort(new MediaError('cancelled'));
    retire();
    await Promise.allSettled([...operations]);
  }

  ctx.effect(() => dispose);
  ctx.on('loader/volatile-update', paths => {
    if (paths.some(path => ['services', 'defaults', 'limits'].includes(path[0]))) {
      void scheduleRefresh();
    }
  });
  ctx.on('credentials/reference-updated', ref => {
    let relevant = true;
    try { relevant = runtimeSnapshot(config).services.some(service => service.keyRef === String(ref)); }
    catch { /* Fail closed if the current configuration cannot be read. */ }
    if (relevant) void scheduleRefresh();
  });
  const ready = scheduleRefresh();
  return { ready, settled: () => pending, dispose };
}

export async function apply(ctx, config) {
  const installed = installMedia(ctx, config);
  await installed.ready;
}
