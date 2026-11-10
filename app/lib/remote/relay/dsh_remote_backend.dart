import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;

import '../../l10n/l10n.dart';
import '../link_status.dart';
import '../secret_store.dart';
import 'relay_backend.dart';

/// [RelayBackend] over `packages/dsh_remote` (ds-harness-remote by 李国宝:
/// account login, Host directory with key pinning, Noise IK over the Relay).
///
/// Host trust works like SSH: a Host seen for the first time is only pinned
/// after the person confirmed its fingerprint in the UI ([approveHost]); a
/// changed key fails closed until [forgetHost].
class DshRemoteRelayBackend implements RelayBackend {
  DshRemoteRelayBackend({
    required SecretStore secrets,
    Object? serverUrl,
    String clientVersion = '0.1.0',
    remote.RemoteAccount? account,
  }) : account =
           account ??
           remote.RemoteAccount(
             secrets: _Secrets(secrets),
             serverUrl: serverUrl,
             deviceName: 'DSH App (Android)',
             platform: 'dsh-app-android',
             clientVersion: clientVersion,
           );

  final remote.RemoteAccount account;

  /// Reconnects back off to a minute: a sleeping computer isn't polled every
  /// few seconds (network changes and 重试 still connect at once).
  static const _muxOptions = MuxOptions(
    retryCaps: [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
  );

  /// Last listing, so [connectHost] gets the full `RemoteHost` back.
  final Map<String, remote.RemoteHost> _hosts = {};

  /// Fingerprints the person confirmed in the UI, by Host id. A first connect
  /// pins only a key whose fingerprint is exactly the one they saw.
  final Map<String, String> _approved = {};

  /// The server's origin (`https://dsh.r2049.cn`), or a [HostLinkError] for
  /// something that isn't one (self-hosted servers: HTTPS, or HTTP on a
  /// private address).
  static String normalizeServer(String input) {
    try {
      return remote.normalizeServerUrl(input).origin;
    } on ArgumentError {
      throw HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrInvalidServer);
    }
  }

  @override
  bool get available => true;

  @override
  String get serverLabel => account.serverUrl.host;

  @override
  Future<RelayUser?> currentUser() => _map(() async {
    final user = await account.currentUser();
    return user == null ? null : _user(user);
  });

  @override
  Future<List<RelayAuthProvider>> loginProviders() => _map(() async {
    final providers = await account.loginProviders();
    return [for (final p in providers) RelayAuthProvider(id: p.id, displayName: p.displayName)];
  });

  @override
  Future<RelayLoginSession> login({String? providerId}) => _map(() async {
    final login = await account.startLogin(providerId: providerId);
    return RelayLoginSession(
      loginUrl: login.loginUrl,
      completed: _map(() async => _user(await login.result)),
      onCancel: login.cancel,
    );
  });

  @override
  Future<RelayUser> loginWithPassword(String email, String password) async {
    try {
      return _user(await account.loginWithPassword(email, password));
    } on remote.RemoteConnectException catch (e) {
      final code = e.failure.code;
      if (code.contains('AUTH') || code.contains('CREDENTIAL') || code == 'UNAUTHORIZED') {
        throw HostLinkError(
          HostLinkErrorKind.authFailed,
          appL10n.remoteErrEmailPassword,
          detail: '$code: ${e.failure.message}',
        );
      }
      throw describe(e.failure);
    }
  }

  @override
  Future<void> logout() => _map(() => account.logout());

  @override
  Future<List<RelayHost>> listHosts({bool refresh = false}) => _map(() async {
    final hosts = await account.listHosts();
    _hosts
      ..clear()
      ..addEntries(hosts.map((h) => MapEntry(h.id, h)));
    return [for (final h in hosts) _host(h)];
  });

  @override
  void approveHost(RelayHost host) {
    final fp = host.fingerprint;
    if (fp != null) _approved[host.id] = fp;
  }

  @override
  Future<void> forgetHost(RelayHost host) async {
    await account.forgetHost(host.id);
    approveHost(host);
  }

  /// Whether a first connect may pin [fingerprint] for [hostId]: only the
  /// exact key the person confirmed.
  bool approves(String hostId, String? fingerprint) => fingerprint != null && _approved[hostId] == fingerprint;

  @override
  bool reconnect(DshClient client) {
    final carrier = client.remoteCarrier;
    if (carrier == null || carrier.isClosed) return false;
    carrier.reconnect();
    return true;
  }

  @override
  Future<bool> probe(DshClient client) => client.remoteCarrier?.probe() ?? Future.value(true);

  @override
  Future<DshClient> connectHost(RelayHost host, {RelayStateCallback? onState}) => _map(() async {
    var target = _hosts[host.id];
    if (target == null) {
      await listHosts();
      target = _hosts[host.id];
    }
    if (target == null) {
      throw HostLinkError(HostLinkErrorKind.notLoggedIn, appL10n.remoteErrHostNotInAccount);
    }
    return account.connectHost(
      target,
      muxOptions: _muxOptions,
      confirmNewHost: (h) async => approves(h.id, h.fingerprint),
      onState: onState == null
          ? null
          : (s) => onState(_state(s.phase), s.failure == null ? null : describe(s.failure!, host.name)),
    );
  }, hostName: host.name);

  Future<void> close() => account.close();

  // ---------------------------------------------------------------------------

  static RelayUser _user(remote.RemoteUser user) =>
      RelayUser(id: user.deviceId, displayName: user.account, provider: user.provider);

  static RelayHost _host(remote.RemoteHost h) => RelayHost(
    id: h.id,
    name: h.name,
    online: h.online,
    platform: h.platform,
    harnessVersion: h.harnessVersion,
    fingerprint: h.fingerprint,
    trust: switch (h.trust) {
      remote.RemoteHostTrust.pinned => RelayTrust.pinned,
      remote.RemoteHostTrust.unpinned => RelayTrust.unpinned,
      remote.RemoteHostTrust.keyChanged => RelayTrust.keyChanged,
      remote.RemoteHostTrust.unknown => RelayTrust.unknown,
    },
  );

  static RelayConnectionState _state(remote.RemoteConnectionPhase phase) => switch (phase) {
    remote.RemoteConnectionPhase.connecting => RelayConnectionState.connecting,
    remote.RemoteConnectionPhase.connected => RelayConnectionState.connected,
    remote.RemoteConnectionPhase.reconnecting => RelayConnectionState.reconnecting,
    remote.RemoteConnectionPhase.failed => RelayConnectionState.failed,
    remote.RemoteConnectionPhase.closed => RelayConnectionState.disconnected,
  };

  /// Runs [action], turning `dsh_remote` failures into person-readable
  /// [HostLinkError]s.
  static Future<T> _map<T>(Future<T> Function() action, {String? hostName}) async {
    try {
      return await action();
    } on remote.RemoteConnectException catch (e) {
      throw describe(e.failure, hostName);
    }
  }

  /// Chinese UI text for a `RemoteFailure.code` (see dsh_remote `state.dart`).
  static HostLinkError describe(remote.RemoteFailure failure, [String? hostName]) {
    final name = hostName == null ? appL10n.remoteHostFallback : appL10n.remoteQuotedHostName(hostName);
    final detail = '${failure.code}: ${failure.message}';
    HostLinkError e(HostLinkErrorKind kind, String message, {bool? retryable}) =>
        HostLinkError(kind, message, detail: detail, retryable: retryable ?? failure.retryable);
    return switch (failure.code) {
      'HOST_OFFLINE' => e(HostLinkErrorKind.hostOffline, appL10n.remoteErrHostOffline, retryable: true),
      'DEVICE_NOT_FOUND' => e(HostLinkErrorKind.other, appL10n.remoteErrHostRemoved(name)),
      'ACCOUNT_AUTH_REQUIRED' ||
      'DEVICE_REVOKED' ||
      'TOKEN_EXPIRED' when !failure.retryable => e(HostLinkErrorKind.notLoggedIn, appL10n.remoteErrRelaySignInExpired),
      'PEER_IDENTITY_MISMATCH' => e(HostLinkErrorKind.hostKeyMismatch, appL10n.remoteErrIdentityKeyChanged),
      'HOST_NOT_TRUSTED' => e(HostLinkErrorKind.hostKeyUnverified, appL10n.remoteErrIdentityUnconfirmed),
      'CONNECTION_REPLACED' => e(HostLinkErrorKind.other, appL10n.remoteErrConnectionReplaced),
      'CONNECTION_REJECTED' => e(HostLinkErrorKind.other, appL10n.remoteErrHostRejected),
      'MEMBERSHIP_REQUIRED' => e(HostLinkErrorKind.other, appL10n.remoteErrHostNotOwned),
      // Version and protocol mismatches fail the same way on every attempt:
      // no reconnect loop (network changes don't fix them), 重试 still works.
      'HARNESS_VERSION_INCOMPATIBLE' => e(HostLinkErrorKind.other, appL10n.remoteErrVersionIncompatible, retryable: false),
      // PROTOCOL_MISMATCH: a relay Control frame this app cannot parse.
      // (INVALID_MESSAGE also covers REST replies that were not JSON, e.g. a
      // captive portal, so it keeps the generic text below.)
      'PROTOCOL_MISMATCH' ||
      'UNSUPPORTED_VERSION' ||
      'CAPABILITY_NOT_SUPPORTED' => e(HostLinkErrorKind.other, appL10n.remoteErrUpdateNeeded, retryable: false),
      'FRAME_TOO_LARGE' when !failure.retryable => e(HostLinkErrorKind.other, appL10n.remoteErrUpdateNeeded),
      'LOGIN_EXPIRED' => e(HostLinkErrorKind.other, appL10n.remoteErrSignInTimeout),
      'LOGIN_CANCELLED' => e(HostLinkErrorKind.other, appL10n.remoteSignInCancelled),
      'OAUTH_PROVIDER_UNAVAILABLE' => e(HostLinkErrorKind.unavailable, appL10n.remoteErrBrowserSignInUnsupported),
      'RATE_LIMITED' => e(HostLinkErrorKind.unreachable, appL10n.remoteErrTooManyRequests, retryable: true),
      _ when failure.retryable => e(HostLinkErrorKind.unreachable, appL10n.remoteErrHostUnreachable),
      _ => e(HostLinkErrorKind.other, appL10n.remoteErrRemoteConnection),
    };
  }
}

/// dsh_remote's secret-store interface over the app's (Keystore-backed) one.
class _Secrets implements remote.SecretStore {
  _Secrets(this._inner);

  final SecretStore _inner;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
