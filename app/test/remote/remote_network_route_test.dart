import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:dsh_app/remote/relay/network_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only confirmed moves between local and remote networks renegotiate', () {
    for (final previous in RemoteNetworkRoute.values) {
      for (final next in RemoteNetworkRoute.values) {
        expect(
          shouldRenegotiateRemoteRoute(previous, next),
          previous != RemoteNetworkRoute.unknown && next != RemoteNetworkRoute.unknown && previous != next,
        );
      }
    }
  });
  test('Wi-Fi and Ethernet prefer LAN, P2P, TURN, Relay', () {
    for (final type in [ConnectivityResult.wifi, ConnectivityResult.ethernet]) {
      expect(automaticRemoteTransports([type]), RemoteTransportMode.values);
    }
  });
  test('confirmed cellular omits LAN, keeps P2P, TURN, Relay', () {
    expect(remoteNetworkRoute([ConnectivityResult.mobile, ConnectivityResult.vpn]), RemoteNetworkRoute.remote);
    expect(automaticRemoteTransports([ConnectivityResult.mobile]), [
      RemoteTransportMode.p2p,
      RemoteTransportMode.turn,
      RemoteTransportMode.relay,
    ]);
  });
  test('unknown, offline and VPN hints do not remove potentially reachable LAN', () {
    for (final interfaces in <List<ConnectivityResult>>[
      [],
      [ConnectivityResult.none],
      [ConnectivityResult.vpn],
      [ConnectivityResult.other],
    ]) {
      expect(automaticRemoteTransports(interfaces), RemoteTransportMode.values);
    }
  });
}
