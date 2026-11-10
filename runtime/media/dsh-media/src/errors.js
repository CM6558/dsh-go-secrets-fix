/** Public failures contain no provider body, URL, credential, or causal stack. */
const MESSAGES = Object.freeze({
  invalid_request: '生成参数无效，请检查模型和参数。',
  not_configured: '请先配置图像服务。',
  credential: '服务密钥不可用，请检查主机上的凭据设置。',
  permission: '当前会话不允许在此工作区保存图片。',
  unsupported_backend: '当前文件系统不支持保存生成图片。',
  unsafe_url: '服务地址或下载地址不受支持。',
  network: '无法连接生成服务，请稍后重试。',
  timeout: '生成超时，请检查服务端状态后再试。',
  cancelled: '已取消生成。',
  rate_limit: '服务请求过于频繁，请稍后重试。',
  authentication: '服务认证失败，请检查密钥和服务地址。',
  policy: '描述或生成结果未通过内容审核。',
  provider: '生成服务未能完成请求。',
  response: '生成服务返回了无法识别的结果。',
  too_large: '生成结果超过大小上限。',
  storage: '无法保存生成结果，请检查主机存储。',
  metadata: '生成结果的信息超过展示上限。',
  cleanup_failed: '生成未完成，部分文件未能清理，请检查主机存储。',
});

export class MediaError extends Error {
  constructor(code) {
    const safeCode = Object.hasOwn(MESSAGES, code) ? code : 'provider';
    super(MESSAGES[safeCode]);
    this.name = 'MediaError';
    this.code = safeCode;
  }
}

export function fail(code) {
  throw new MediaError(code);
}

export function abortError(signal) {
  return new MediaError(signal?.reason instanceof MediaError
    ? signal.reason.code : 'cancelled');
}

export function checkAbort(signal) {
  if (signal?.aborted) throw abortError(signal);
}

export function safeFailure(error, signal) {
  if (error instanceof MediaError && error.code === 'cleanup_failed') return error;
  if (signal?.aborted) return abortError(signal);
  return error instanceof MediaError ? error : new MediaError('provider');
}
