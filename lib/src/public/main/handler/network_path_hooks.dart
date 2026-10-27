enum ConnectionAttemptPhase { idle, preparing, handshake, authenticating, backoff }

enum TransportRecoveryResult { authenticated, timeout, cancelled, authRequired }

class ConnectionAttemptSnapshot {
  const ConnectionAttemptSnapshot({this.attemptId, this.since, this.deadline,
    this.phase = ConnectionAttemptPhase.idle, this.retryAt,
    this.authRequired = false});

  final String? attemptId;
  final DateTime? since;
  final DateTime? deadline;
  final ConnectionAttemptPhase phase;
  final DateTime? retryAt;
  final bool authRequired;
}

class NetworkConnectionSnapshot {
  const NetworkConnectionSnapshot({this.key, this.sequence = initialSequence,
      this.authenticated = false, this.reconnecting = false});

  static const initialSequence = 0;
  final Object? key;
  final int sequence;
  final bool authenticated;
  final bool reconnecting;
}
