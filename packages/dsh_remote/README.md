# dsh_remote

Pure-Dart client for [ds-harness-remote](https://github.com/liguobao/ds-harness-remote) (李国宝, MIT). It reaches a remote Host's DSH Harness API through the Server Relay, end-to-end encrypted with `Noise_IK_25519_ChaChaPoly_SHA256`. The result is an ordinary `DshClient` from `package:dsh_client`, so chat, watch, approvals, models and keys work exactly as they do with the local engine.

Status (2026-10-27):

| Layer | State |
|---|---|
| Noise IK | Matches upstream `fixtures/crypto/v1/noise-ik.json` byte for byte |
| Control frames / negotiation | Passes upstream `fixtures/protocol/v1` (82 cases) |
| Relay transport, DSHF framing, RPC, tunnel carrier | Unit-tested against an in-process fake Server + Host |
| Whole stack vs real upstream | **E2E passes** against self-hosted `apps/server` (upstream `91d4e1d`) + `dsh web` 0.2.1-rc.2 with the `ds-harness-remote` Host plugin 0.5.20 from npm; also 0.5.19 (`tool/e2e/run_e2e.sh`; `PLUGIN_SPEC=<tarball>` for unreleased builds) |
| WebRTC / LAN / TURN | Not implemented. Relay only, behind a transport seam |

## Quick start (Flutter app)

```yaml
dependencies:
  dsh_remote: {path: ../packages/dsh_remote}   # re-exports package:dsh_client
```

```dart
import 'package:dsh_remote/dsh_remote.dart';

// 1. Secrets go through your SecretStore (flutter_secure_storage).
class SecureStore implements SecretStore {
  final s = const FlutterSecureStorage();
  @override Future<String?> read(String k) => s.read(key: k);
  @override Future<void> write(String k, String v) => s.write(key: k, value: v);
  @override Future<void> delete(String k) => s.delete(key: k);
}

final account = RemoteAccount(
  secrets: SecureStore(),
  serverUrl: 'https://dsh.r2049.cn',   // default; any self-hosted origin works
  deviceName: 'Pixel 9 · DSH App',      // shown in the account's device list
  platform: 'dsh-app-android',
  clientVersion: appVersion,
);

// 2. Sign in (once; tokens persist and refresh themselves).
if (await account.currentUser() == null) {
  final login = await account.startLogin();          // QR / browser sign-in
  await launchUrl(login.loginUrl);                   // Custom Tab or browser
  final user = await login.result;                   // polls every 2 s
  // Self-hosted Server: await account.loginWithPassword(email, password);
}

// 3. Hosts.
final hosts = await account.listHosts();             // online, versions, fingerprint, trust

// 4. Connect: a ready DshClient (same API as local).
final client = await account.connectHost(
  hosts.firstWhere((h) => h.online),
  onState: (s) => ui.showConnection(s),              // connecting/connected/reconnecting/failed/closed
  confirmNewHost: (h) => ui.confirmFingerprint(h.name, h.fingerprint!),  // optional first-use prompt
);
final sessions = await client.listSessions();
client.watch(sessions.first.sessionId).listen(transcript.apply);
await client.prompt(sessionId, 'hi');
await client.close();                                // or account.logout()
```

## API surface

### `RemoteAccount`: one account on one Server

| Member | Notes |
|---|---|
| `RemoteAccount({required SecretStore secrets, Object? serverUrl, deviceName, platform, clientVersion, ...})` | `serverUrl` defaults to `https://dsh.r2049.cn`. It is normalized to an origin, and plain HTTP is accepted only for loopback or private hosts. Storage is partitioned by origin |
| `Future<RemoteUser?> currentUser()` | Restores stored credentials. Returns `null` when signed out or when the refresh token has expired. `RemoteUser.provider` is the provider the device signed in with (`github`, `zhihu`, `password`, ...), or `null` for credentials stored before it was recorded |
| `Future<List<OAuthProvider>> loginProviders()` | Server-defined QR-capable providers (`github`, `google`, `zhihu`, ...). Empty on a self-hosted Server |
| `Future<RemoteLogin> startLogin({String? providerId})` | QR / browser sign-in that needs **no app URL scheme**. Fields: `loginUrl` (open it), `expiresAt`, `providerId`, `result` (a `Future<RemoteUser>`) and `cancel()`. Keep `result` alive while the Custom Tab is open; polling resumes when the app returns to the foreground. The one-time web token is used once to register this device and is never stored |
| `Future<RemoteUser> loginWithPassword(email, password)` | Self-hosted Server, or invited accounts on the hosted one |
| `Future<void> logout({bool revokeDevice = true})` | Closes the connection and revokes the device on the Server (best effort). Deletes the tokens, and also the identity when revoked. Host pins are kept |
| `Future<void> refresh()` / `Future<String> accessToken({forceRefresh})` | Refresh is normally automatic (60 s before expiry) and single-flight, because refresh tokens rotate and reusing an old one revokes the whole family |
| `Future<List<RemoteHost>> listHosts()` | Fetches every Host's descriptor in parallel to report the identity key and trust |
| `Future<void> forgetHost(hostId)` | Drops a pin. Use it after the user confirms a legitimate Host reinstall |
| `Future<DshClient> connectHost(host, {onState, confirmNewHost, muxOptions, timeout = 30 s, tracer})` | See below |
| `Stream<RemoteConnectionState> connectionStates`, `connectionState`, `activeClient` | Follow whichever connection is currently active |
| `Future<void> close()` | Closes the active connection and the HTTP client |

`RemoteHost` fields: `id`, `name` (untrusted, escape it in the UI), `platform`, `online`, `harnessVersion` (DSH on the Host), `pluginVersion` (ds-harness-remote), `lastSeenAt`, `identityKey`, `fingerprint` (`ABCD EF01 2345`), `pinnedIdentityKey`, and `trust` (`pinned | unpinned | keyChanged | unknown`).

### `connectHost`

It returns once the first `$events` generation is ready. It throws `RemoteConnectException(failure)` in three cases: immediately for terminal failures, immediately for `HOST_OFFLINE`, and otherwise after `timeout`. Opening a connection does this:

1. Fetches the Host descriptor and checks the **pin**. The first connect pins the key, after `confirmNewHost` returns true when that callback is given; otherwise trust is on first use. A changed key always fails closed with `PEER_IDENTITY_MISMATCH`, before any socket is opened.
2. Control WebSocket: `hello` → `connect.request` (relay) → `connect.accepted`. A refused token is refreshed and retried once.
3. Noise IK as initiator. The Host's static key must equal the pin, and the prologue binds the connection and both device ids.
4. `harness.transport.describe`. The Host must declare `harness.remote.v3` (DSH 0.2.x Session V3). Older or ApiProxy-only Hosts fail with `HARNESS_VERSION_INCOMPATIBLE`.

The returned client **reconnects by itself** (DshMux backoff 0.5 to 10 s): a new connection, a new `$events` generation, streams reopened, and `watch()` resynced with a snapshot where `isResync` is true. Liveness comes from a `harness.transport.describe` health probe every 25 s (5 s deadline) plus the Server's Control heartbeat; three silent heartbeats count as dead. The Server allows **one Host connection per client device**, so connecting another Host closes the previous client.

### Connection state

```dart
enum RemoteConnectionPhase { connecting, connected, reconnecting, failed, closed }
class RemoteConnectionState { phase; hostId; RemoteFailure? failure; String? transport /* 'relay' */; DateTime? at; }
class RemoteFailure { code; message; retryable; }
```

You can read it from `onState`, `account.connectionStates`, `client.remoteStates` or `client.remoteCarrier!.state`. The `DshClient` itself still reports `DshConnectionState`, and `watch()` still emits `ConnectionStateEvent`. Terminal remote failures map to `DshConnectionState.unauthorized`.

| `failure.code` | Kind | Suggested UI |
|---|---|---|
| `HOST_OFFLINE` | retrying | "Host offline" |
| `CONNECTION_FAILED`, `SECURE_CHANNEL_FAILED`, `RPC_TIMEOUT`, `TOKEN_EXPIRED`, `RATE_LIMITED` | retrying | "Reconnecting…" |
| `ACCOUNT_AUTH_REQUIRED` | terminal | Sign in again |
| `PEER_IDENTITY_MISMATCH` | terminal | Warn: the key changed; offer `forgetHost` only after explicit confirmation |
| `HOST_NOT_TRUSTED` | terminal | First-use confirmation declined |
| `CONNECTION_REPLACED` | terminal | "Used on another device"; offer to take over |
| `CONNECTION_REJECTED`, `MEMBERSHIP_REQUIRED`, `DEVICE_NOT_FOUND`, `DEVICE_REVOKED` | terminal | Host refused this phone / removed from the account |
| `HARNESS_VERSION_INCOMPATIBLE` | terminal | Update DSH (0.2.x) or the plugin on the Host |

A terminal failure **sticks**: the client stops reconnecting, so it never fights another device for the connection. After the user has fixed the cause, call `client.remoteCarrier!.reconnect()`.

### Differences from the local engine (same `DshClient` API)

| | Local `dsh web` | Remote tunnel |
|---|---|---|
| Endpoints | everything | Fixed upstream allow-list (`harnessRemoteAllowlist`, 89 + 10 terminal). Others fail locally with `DshRemoteException('METHOD_NOT_ALLOWED')`. **`uploadFile` (`fileUploads/upload`) is not available**, so send images inline (`PromptImage`). Check first with `client.supportsEndpoint(...)` |
| Uplink stream items | yes | **no**: `MuxStream.supportsUplink == false` and `send()` throws `UnsupportedError` |
| Size | 300 MiB HTTP body | Calls up to 2 MiB go direct; larger ones (big inline images) use chunked `harness.remote.transfer.*` (512 KiB chunks, 288 MiB max). Responses over 4 MiB are retried through a transfer |
| Binary results | multipart (rejected) | `workspaceFiles/readBytes`, `officeToPdf/render` return `data` as a base64 string |
| Tunnel failures | HTTP 401/403/404 | Host refusals (`RPC_TIMEOUT`, `RATE_LIMITED`, `TERMINAL_DISABLED`, ...) become `DshRemoteException` with `details.remote = true`. A lost connection or a local deadline becomes `DshTransportException`, meaning the outcome is unknown, so don't blindly retry mutations |
| Streams | unlimited | 16 per connection (Host limit) |
| `client.connection` | `DshConnection` | throws `StateError`; use `client.remoteCarrier` |

## Security model

- The device identity (X25519) and tokens live only in `SecretStore`, under keys `dsh_remote.v1.<sha256(origin)[:24]>.{identity,credentials,pins}`. Passwords and web tokens are never stored or logged, and tracers redact tokens and ciphertext.
- Noise IK authenticates both sides against keys distributed by the Server. **E2EE does not protect against a malicious Server on first contact**: the first pin trusts the Server's descriptor, and the fingerprint is only 48 bits. Pins fail closed afterwards. Upstream Hosts auto-trust any client of the same account, so an account takeover equals Host access. There is no rekey yet (upstream roadmap).
- Replay protection: the Relay `counter` must equal the next Noise receive nonce. Duplicates, reorders, forgeries, bad fragments and unknown message types close the channel.

## Architecture

```
RemoteAccount ─ RemoteServerApi (REST /api/v1)
      │ connectHost
      ▼
RemoteTunnelCarrier (DshCarrier) ── DshClient / DshRpc / DshMux (package:dsh_client)
      │ RemoteHostSession per connection
      ▼
RemoteRpcClient (rpc.request/response/error, events, 128 pending, deadlines)
      ▼
SecureChannel (Noise IK initiator, DSHF fragments, ordered sends, fail closed)
      ▼
SecureHandshakeTransport ◀── RelayTransport (Control WS: hello, connect, relay, ping/pong)
                         ◀── (future) LAN / P2P / TURN over a WebRTC DataChannel "dsh"
```

Adding WebRTC means implementing `SecureHandshakeTransport`: signal over the Control socket, send `transport.selected` before the handshake, put binary ciphertext on the DataChannel with RTCH chunking above 8 KiB, and fall back to Relay. Nothing above that interface changes.

Performance: crypto is pure Dart (`cryptography` 2.9 ChaCha20-Poly1305 and X25519, `crypto` SHA-256/HMAC) and runs synchronously on the calling isolate. A desktop JIT runs it at about 55 MB/s, so a 4 MiB message costs about 75 ms each way. Chat traffic is negligible. Large image transfers on low-end phones may be worth moving to an isolate later.

## Tests

```bash
dart test                      # Noise vectors, protocol conformance, DSHF, fake Server+Host carrier tests (110)
tool/e2e/run_e2e.sh            # real stack, isolated temp HOME/DSH_HOME, loopback only, no prompts
```

`run_e2e.sh` bundles upstream `apps/server` from a checkout (`UPSTREAM`, default `../../.refs/ds-harness-remote-upstream`) with esbuild. It installs `ds-harness-remote@0.5.17` from npm into a fresh DSH profile and points that profile at the local Server with a profile `cordis.patch.yml`. Terminal, Codex and ACP are disabled there; the bundled patch hard-codes `https://dsh.r2049.cn`, so the override is required. It pre-provisions the Host credentials (`tool/e2e/provision-host.mjs`; the plugin CLI only does QR or code login), starts `dsh web` (`DSH_BIN` selects the version) and runs `test/live_remote_test.dart`. That test covers connect, list/create/rename/archive sessions, live follow events, model/permission/key, workspaces, host events, the transfer path, reconnect/resync and token rotation.

`bin/remote_probe.dart` is an interactive CLI: `--server`, `--email` (password in `DSH_REMOTE_PASSWORD`) or QR sign-in, `--state` file, `--create-session --cwd`, `--watch-seconds`, `--reconnect-test`, `--trace`. It never sends prompts.

Not covered live: approvals and questions over `$events` (they need a model prompt; the fake-Host test covers them), the hosted `dsh.r2049.cn` QR flow (needs a real account; it matches the upstream Android and plugin code and runs against the fake Server), and real WAN latency.

## License and attribution

Protocol, framing, validation and connection logic are ported from ds-harness-remote, Copyright (c) 2026 DSH Remote contributors, MIT. The full text is in [LICENSE-ds-harness-remote](LICENSE-ds-harness-remote), and each ported file names its upstream source. The Noise state machine is our own implementation, with the author's agreement, and is verified against the upstream golden vectors. Fixtures under `test/fixtures` are copied from upstream.
