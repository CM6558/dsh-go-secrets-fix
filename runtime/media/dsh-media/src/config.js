import { readFileSync } from 'node:fs';
import z from '@deepseek-ai/schemastery';
import { formatGenerationMessage } from './header.js';

export const CATALOG_META_KEY = 'dsh-go/media/catalog';
export const CREDENTIAL_SLOTS = Object.freeze([
  'DSH_MEDIA_SLOT_1_API_KEY',
  'DSH_MEDIA_SLOT_2_API_KEY',
  'DSH_MEDIA_SLOT_3_API_KEY',
  'DSH_MEDIA_SLOT_4_API_KEY',
]);
export const HARD_LIMITS = Object.freeze({
  maxImages: 4,
  maxImageBytes: 20 * 1024 * 1024,
  maxResponseBytes: 32 * 1024 * 1024,
  maxTotalImageBytes: 64 * 1024 * 1024,
});

function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

function invalid() {
  throw new Error('图像服务配置无效，请检查服务、模型和凭据引用。');
}

// Reuse the message formatter so catalog values cannot advertise parameters
// that the shared v1 grammar cannot represent. This is syntax validation only;
// validating a video row here does not enable a video provider or tool.
export function validateCatalogHeaderModel(model) {
  try {
    const value = { kind: model.kind, prompt: '目录校验', model: { label: model.label } };
    // Check the label without a marker as well: a marker must not hide a label
    // that the grammar classifies as an aspect, count, duration or resolution.
    formatGenerationMessage(value);
    formatGenerationMessage({ ...value,
      model: { ...value.model, serviceId: 'catalog', id: model.id },
    });
    const fields = [
      ['ratios', 'aspect'],
      [model.kind === 'image' ? 'qualities' : 'resolutions', 'quality'],
    ];
    for (const [field, parameter] of fields) {
      if (model[field] === undefined) continue;
      if (!Array.isArray(model[field])) invalid();
      for (const item of model[field]) formatGenerationMessage({ ...value, [parameter]: item });
    }
  } catch { invalid(); }
  return model;
}

const rawCatalog = JSON.parse(readFileSync(
  new URL('../data/models.json', import.meta.url), 'utf8',
));
if (rawCatalog.v !== 1 || !Array.isArray(rawCatalog.models)) invalid();
const catalogIds = new Set();
for (const model of rawCatalog.models) {
  if (!model || typeof model.id !== 'string' || catalogIds.has(model.id)
    || model.kind !== 'image' || typeof model.label !== 'string'
    || !['openai-compatible', 'openai-gpt-image'].includes(model.profile)
    || !Array.isArray(model.sizes) || !Array.isArray(model.qualities)
    || !Number.isSafeInteger(model.maxN) || model.maxN < 1 || model.maxN > 4) invalid();
  validateCatalogHeaderModel(model);
  if (model.responseFormats !== undefined
    && (!Array.isArray(model.responseFormats) || model.responseFormats.length === 0
      || new Set(model.responseFormats).size !== model.responseFormats.length
      || model.responseFormats.some(value => !['url', 'b64_json'].includes(value)))) invalid();
  for (const [aspect, size] of Object.entries(model.aspectSizes ?? {})) {
    if (!/^[1-9]\d?:[1-9]\d?$/.test(aspect) || !model.sizes.includes(size)) invalid();
    const [a, b] = aspect.split(':').map(Number);
    const match = /^([1-9]\d*)x([1-9]\d*)$/.exec(size);
    if (!match || Number(match[1]) * b !== Number(match[2]) * a) invalid();
  }
  catalogIds.add(model.id);
}
export const CATALOG = freeze(rawCatalog);

export function catalogModel(id) {
  return CATALOG.models.find(model => model.id === id);
}

export function modelIdsOf(service) {
  if (typeof service.models !== 'string') invalid();
  const ids = service.models.split(',').map(value => value.trim()).filter(Boolean);
  if (ids.length < 1 || ids.length > 16 || new Set(ids).size !== ids.length
    || ids.some(id => !catalogModel(id))) invalid();
  return ids;
}

export function validateServices(services) {
  if (!Array.isArray(services) || services.length > 8) invalid();
  const ids = new Set();
  const allowed = new Set(['id', 'label', 'enabled', 'provider', 'baseUrl', 'profile', 'responseFormat', 'models', 'keyRef']);
  for (const service of services) {
    if (!service || Object.keys(service).some(key => !allowed.has(key))
      || !/^[a-z][a-z0-9_]{0,31}$/.test(service.id ?? '')
      || ids.has(service.id)
      || !/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(service.keyRef ?? '')
      || !['openai-compatible', 'openai-gpt-image'].includes(service.profile)
      || typeof service.provider !== 'string' || !service.provider.trim()
      || Buffer.byteLength(service.provider, 'utf8') > 80
      || /[\u0000-\u001f]/.test(service.provider)
      || !['', 'url', 'b64_json'].includes(service.responseFormat ?? '')) invalid();
    let url;
    try { url = new URL(service.baseUrl); } catch { invalid(); }
    if (url.protocol !== 'https:' || url.username || url.password
      || url.search || url.hash) invalid();
    if (service.profile === 'openai-gpt-image' && service.responseFormat) invalid();
    const models = modelIdsOf(service).map(catalogModel);
    if (models.some(model => model.profile !== service.profile)) invalid();
    // A catalog whitelist requires an explicit evidenced response format.
    // An absent list leaves the profile's existing rules in force.
    if (models.some(model => model.responseFormats !== undefined
      && !model.responseFormats.includes(service.responseFormat))) invalid();
    ids.add(service.id);
  }
  return services;
}

const Service = z.object({
  id: z.string().pattern(/^[a-z][a-z0-9_]{0,31}$/).required()
    .description('服务 ID（唯一小写标识）'),
  label: z.string().max(80).default('').description('显示名称'),
  enabled: z.boolean().default(false).description('启用'),
  provider: z.string().max(80).default('openai').description('服务商标识'),
  baseUrl: z.string().max(2048).default('https://api.openai.com/v1')
    .description('服务地址（HTTPS API 根路径）'),
  profile: z.union(['openai-gpt-image', 'openai-compatible'])
    .default('openai-gpt-image').description('请求协议'),
  responseFormat: z.union(['', 'url', 'b64_json']).default('')
    .description('兼容接口返回格式（按模型目录；GPT Image 留空）'),
  models: z.string().max(2048).default('gpt-image-2.5-flare')
    .description('允许的模型 ID（英文逗号分隔，来自已安装目录）'),
  keyRef: z.string().pattern(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/).required()
    .description('凭据引用（必填；选择固定槽或已知引用）'),
});

// Exact-empty validation with a fixed error avoids Schemastery's const "got"
// diagnostic echoing a misplaced secret. Keep a transform leaf: f87 treats
// intersect nodes as groups before checking their secret role.
const SecretSentinel = z.transform(z.any(), value => {
  if (value !== '') throw new Error('密钥只能通过凭据服务写入。');
  return '';
}, true).default('').role('secret');

function credentialSlot(ref, number) {
  return z.object({
    credentialRef: z.const(ref).default(ref).role('credential-ref'),
    apiKey: SecretSentinel
      .description('写入密钥：' + ref),
  }).description('凭据槽 ' + number + '：' + ref);
}

const Credentials = z.object(Object.fromEntries(
  CREDENTIAL_SLOTS.map((ref, index) => ['slot' + (index + 1), credentialSlot(ref, index + 1)]),
));

export const Config = z.object({
  // Deployment-only. It is intentionally not volatile or editable via settings.
  dshHome: z.string().description('DSH 数据根（仅主机部署配置）'),
  services: z.transform(z.array(Service).max(8), validateServices, true)
    .default([]).volatile()
    .extra('extra', { [CATALOG_META_KEY]: CATALOG })
    .description('图像服务'),
  credentials: Credentials.volatile().description('密钥（固定目标，只写）'),
  defaults: z.object({
    serviceId: z.string().max(32).default('')
      .description('默认服务 ID（留空使用首个已配置服务）'),
    modelId: z.string().max(160).default('')
      .description('默认模型 ID（留空使用所选服务首项）'),
  }).volatile().description('默认值'),
  limits: z.object({
    maxImages: z.number().step(1).min(1).max(HARD_LIMITS.maxImages)
      .default(HARD_LIMITS.maxImages).description('单次图片张数上限'),
    maxImageBytes: z.number().step(1).min(1).max(HARD_LIMITS.maxImageBytes)
      .default(HARD_LIMITS.maxImageBytes).description('单张原件字节上限'),
    maxResponseBytes: z.number().step(1).min(1).max(HARD_LIMITS.maxResponseBytes)
      .default(HARD_LIMITS.maxResponseBytes).description('服务响应字节上限'),
    maxTotalImageBytes: z.number().step(1).min(1).max(HARD_LIMITS.maxTotalImageBytes)
      .default(HARD_LIMITS.maxTotalImageBytes).description('单次原件总字节上限'),
  }).volatile().description('请求与存储上限（不含每日费用预算）'),
});

function current(ref) {
  if (!ref || typeof ref.get !== 'function') invalid();
  return ref.get();
}

export function runtimeSnapshot(config) {
  const services = validateServices(current(config.services));
  const defaults = current(config.defaults);
  const limits = current(config.limits);
  const cleanLimits = {};
  for (const [name, maximum] of Object.entries(HARD_LIMITS)) {
    const value = limits[name];
    if (!Number.isSafeInteger(value) || value < 1 || value > maximum) invalid();
    cleanLimits[name] = value;
  }
  if (typeof defaults.serviceId !== 'string' || typeof defaults.modelId !== 'string') invalid();
  return freeze({
    services: services.filter(service => service.enabled === true).map(service => ({
      id: service.id, label: service.label || service.id, provider: service.provider,
      baseUrl: service.baseUrl, profile: service.profile,
      ...(service.responseFormat ? { responseFormat: service.responseFormat } : {}),
      keyRef: service.keyRef, modelIds: modelIdsOf(service),
    })),
    defaults: { serviceId: defaults.serviceId, modelId: defaults.modelId },
    limits: cleanLimits,
  });
}
