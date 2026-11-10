import { fail } from './errors.js';

// Strict RFC 4648 standard alphabet and canonical zero padding bits.
// Validate before Buffer.from: Node's base64 decoder is intentionally permissive.
export function base64DecodedLength(value, limit) {
  if (!Number.isSafeInteger(limit) || limit < 1) fail('invalid_request');
  if (typeof value !== 'string' || value.length === 0 || value.length % 4 !== 0) {
    fail('response');
  }
  if (value.length > 4 * Math.ceil(limit / 3)) fail('too_large');
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const length = value.length / 4 * 3 - padding;
  if (length > limit) fail('too_large');
  const end = value.length - padding;
  let last = 0;
  for (let i = 0; i < end; i += 1) {
    const c = value.charCodeAt(i);
    if (c >= 65 && c <= 90) last = c - 65;
    else if (c >= 97 && c <= 122) last = c - 71;
    else if (c >= 48 && c <= 57) last = c + 4;
    else if (c === 43) last = 62;
    else if (c === 47) last = 63;
    else fail('response');
  }
  if ((padding === 2 && (last & 15) !== 0)
    || (padding === 1 && (last & 3) !== 0)) fail('response');
  return length;
}
