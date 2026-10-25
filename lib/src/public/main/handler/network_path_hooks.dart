abstract class NetworkPathHooks {
  Future<bool> onConnectivityChanged({
    required Object sdkInstance,
    required bool hasWifi,
    required bool hasCellular,
    required bool hasVpn,
    required bool isOnline,
  });
}

class NetworkReconnectAttempt {
  const NetworkReconnectAttempt({
    required this.scope,
    required this.sdkInstance,
    required this.generation,
    required this.attempt,
  });

  static const initialAttempt = 0;
  static const retryAttempt = 1;
  static const sdkScope = 'sdk';
  final String scope;
  final Object sdkInstance;
  final int generation;
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is NetworkReconnectAttempt &&
      scope == other.scope &&
      identical(sdkInstance, other.sdkInstance) &&
      generation == other.generation &&
      attempt == other.attempt;

  @override
  int get hashCode =>
      Object.hash(scope, identityHashCode(sdkInstance), generation, attempt);
}

enum NetworkReconnectEventKind {
  reconnectScheduled,
  reconnectStarted,
  websocketClosed,
  authenticated,
  authenticationFailed,
}

class NetworkReconnectEvent {
  const NetworkReconnectEvent(this.kind, this.key,
      {this.scheduledAt, this.error, this.sequence});

  final NetworkReconnectEventKind kind;
  final NetworkReconnectAttempt key;
  final Duration? scheduledAt;
  final Object? error;
  final int? sequence;
}

abstract class NetworkReconnectAdapter {
  Object get sdkInstance;
  Duration get now;
  NetworkConnectionSnapshot get connectionSnapshot;
  Stream<NetworkReconnectEvent> get events;
  Future<void> closeWebsocket(NetworkReconnectAttempt key);
  Future<void> beginOrJoinReconnect(
      NetworkReconnectAttempt key, Duration deadline);
  void resetBackoff(NetworkReconnectAttempt key, Duration deadline);
  Future<void> retryReconnect(NetworkReconnectAttempt key, Duration deadline);
  void cancelAttempt(NetworkReconnectAttempt key);
  void cancelScope(String scope);
  Future<void> joinGeneration(int generation);
}

class NetworkConnectionSnapshot {
  const NetworkConnectionSnapshot({this.key, this.sequence = initialSequence,
      this.authenticated = false, this.reconnecting = false});

  static const initialSequence = 0;
  final NetworkReconnectAttempt? key;
  final int sequence;
  final bool authenticated;
  final bool reconnecting;
}
