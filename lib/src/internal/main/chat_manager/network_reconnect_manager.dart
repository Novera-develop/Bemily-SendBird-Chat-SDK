import 'dart:async';

import 'package:uuid/uuid.dart';

import 'package:sendbird_chat_sdk/src/public/main/handler/network_path_hooks.dart';

enum SocketEventKind {
  reconnectScheduled,
  reconnectStarted,
  websocketClosed,
  authenticated,
  authenticationFailed,
}

class SocketEvent {
  const SocketEvent(this.kind, this.key,
      {this.scheduledAt, this.error, this.sequence});
  final SocketEventKind kind;
  final Object key;
  final Duration? scheduledAt;
  final Object? error;
  final int? sequence;
}

class SocketTracker {
  SocketTracker({Duration Function()? clock}) : _clock = clock;
  final Duration Function()? _clock;
  static const _sequenceIncrement = 1;
  final _events = StreamController<SocketEvent>.broadcast();
  final _stopwatch = Stopwatch()..start();
  Object _nextKey = Object();
  NetworkConnectionSnapshot _connectionSnapshot = const NetworkConnectionSnapshot();

  Stream<SocketEvent> get events => _events.stream;
  NetworkConnectionSnapshot get connectionSnapshot => _connectionSnapshot;
  Duration get now => _clock?.call() ?? _stopwatch.elapsed;

  void invalidateConnection() {
    _connectionSnapshot = NetworkConnectionSnapshot(key: _connectionSnapshot.key,
        sequence: _connectionSnapshot.sequence);
  }

  void _activateConnection(Object key) {
    if (identical(_connectionSnapshot.key, key)) return;
    _connectionSnapshot = NetworkConnectionSnapshot(key: key,
        sequence: _connectionSnapshot.sequence + _sequenceIncrement,
        reconnecting: true);
  }

  void _emit(SocketEvent event) {
    final previous = _connectionSnapshot;
    final current = identical(previous.key, event.key);
    if (current) {
      _connectionSnapshot = NetworkConnectionSnapshot(key: event.key,
          sequence: previous.sequence,
          authenticated: event.kind == SocketEventKind.authenticated,
          reconnecting: event.kind == SocketEventKind.reconnectScheduled ||
              event.kind == SocketEventKind.reconnectStarted);
    }
    _events.add(SocketEvent(event.kind, event.key,
        scheduledAt: event.scheduledAt, error: event.error,
        sequence: current ? previous.sequence : null));
  }

  SocketAttempt reserveSdkAttempt({bool preserveConnection = false}) {
    if (!preserveConnection) _activateConnection(_nextKey);
    return SocketAttempt(_nextKey, _emit);
  }

  SocketAttempt createSdkAttempt() {
    final key = _nextKey;
    _nextKey = Object();
    _activateConnection(key);
    return SocketAttempt(key, _emit);
  }
}

class SocketAttempt {
  SocketAttempt(this.key, this._emit);
  final Object key;
  final void Function(SocketEvent) _emit;
  bool hasStarted = false;
  bool _authenticated = false;
  bool _terminated = false;
  bool get isActive => hasStarted && !_terminated;
  bool get isAuthenticated => _authenticated && !_terminated;

  void scheduled(Duration at) => _emit(SocketEvent(
      SocketEventKind.reconnectScheduled, key, scheduledAt: at));

  void started() {
    if (hasStarted || _terminated) return;
    hasStarted = true;
    _emit(SocketEvent(SocketEventKind.reconnectStarted, key));
  }

  void authenticated() {
    if (_authenticated || _terminated) return;
    _authenticated = true;
    _emit(SocketEvent(SocketEventKind.authenticated, key));
  }

  void closed({Object? error}) {
    if (_terminated) return;
    _terminated = true;
    _emit(SocketEvent(error == null
        ? SocketEventKind.websocketClosed
        : SocketEventKind.authenticationFailed, key, error: error));
  }
}

class ConnectionAttempt {
  ConnectionAttempt(Duration budget, {DateTime? since})
      : id = const Uuid().v4(), since = since ?? DateTime.now() {
    deadline = this.since.add(budget);
  }

  final String id;
  final DateTime since;
  late final DateTime deadline;
  ConnectionAttemptPhase phase = ConnectionAttemptPhase.preparing;
  bool active = true;
  final stopped = Completer<void>();
}
