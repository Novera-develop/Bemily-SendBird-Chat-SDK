import 'dart:async';

import 'package:sendbird_chat_sdk/src/internal/main/chat_context/chat_context.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/exceptions.dart';
import 'package:sendbird_chat_sdk/src/public/main/handler/network_path_hooks.dart';

class NetworkReconnectManager implements NetworkReconnectAdapter {
  NetworkReconnectManager(this.connection, {Duration Function()? clock})
      : _clock = clock;

  static const _retainedGenerations = 2;
  static const _initialGeneration = 0;
  static const _cancelledScopeLimit = 4096;
  static const _closeBudget = Duration(milliseconds: 500);
  static const _invalidKey = 'Reconnect attempt does not belong to this lease';
  static const _unknownGeneration = 'Reconnect generation has not started';
  static const _deadlineExceeded = 'Reconnect authentication deadline exceeded';
  final ConnectionManager connection;
  final Duration Function()? _clock;
  final Zone _futureZone = Zone.current;
  final Stopwatch _stopwatch = Stopwatch()..start();
  final _events = StreamController<NetworkReconnectEvent>.broadcast();
  final Map<int, _ReconnectLease> _leases = {};
  final Map<NetworkReconnectAttempt, Future<void>> _closes = {};
  final Map<WebSocketClient, Future<void>> _socketCloses = Map.identity();
  final Expando<bool> _closedSockets = Expando<bool>();
  final Set<String> _cancelledScopes = {};
  _ReconnectLease? _lease;
  int? _latestGeneration;
  int _currentGeneration = _initialGeneration;
  int _nextSdkAttempt = NetworkReconnectAttempt.initialAttempt;
  String? _recoveryScope;
  NetworkReconnectAttempt? _closingKey;
  Future<void> _transportClosed = Future.value();
  Timer? _deadlineTimer;

  @override
  Object get sdkInstance => connection.chat.sdkInstance;
  @override
  Duration get now => _clock?.call() ?? _stopwatch.elapsed;
  @override
  Stream<NetworkReconnectEvent> get events => _events.stream;

  bool get ownsReconnect => _closingKey != null ||
      (_lease != null &&
          _lease!.releasedFuture == null &&
          !_lease!.scopeCancelled &&
          !_cancelledScopes.contains(_lease!.current.key.scope));
  NetworkReconnectAttempt? get currentKey => _lease?.current.key;
  Future<void>? get currentFuture => _closingKey == null
      ? _lease?.future
      : _leases[_closingKey!.generation]?.future;
  Future<void> get transportClosed => _transportClosed;
  bool isAuthenticating(NetworkReconnectAttempt key) =>
      isCurrent(key) && !_lease!.current.authenticated;

  bool matchesCredentials(String userId, {String? accessToken, String? nickname,
      String? apiHost, String? wsHost}) {
    final context = connection.chat.chatContext;
    return _lease?.credentials.matches(context, userId,
        accessToken: accessToken, nickname: nickname,
        apiHost: apiHost, wsHost: wsHost) ?? false;
  }

  bool matchesSessionCredentials(String userId, {String? accessToken,
      String? apiHost, String? wsHost}) {
    final context = connection.chat.chatContext;
    return _ReconnectCredentials(context).matches(context, userId,
        accessToken: accessToken, apiHost: apiHost, wsHost: wsHost);
  }

  void receivedSessionKey(NetworkReconnectAttempt key, String? sessionKey) {
    if (isCurrent(key)) _lease!.credentials.sessionKey = sessionKey;
  }

  void _validate(NetworkReconnectAttempt key) {
    if (!identical(key.sdkInstance, sdkInstance)) {
      throw ArgumentError(_invalidKey);
    }
  }

  bool isCurrent(NetworkReconnectAttempt key) {
    final attempt = _lease?.current;
    if (attempt == null || attempt.key != key || attempt.cancelled ||
        _cancelledScopes.contains(key.scope)) return false;
    if (!attempt.authenticated && attempt.deadline != null &&
        now >= attempt.deadline!) {
      fail(key, TimeoutException(_deadlineExceeded));
      return false;
    }
    return true;
  }

  @override
  Future<void> closeWebsocket(NetworkReconnectAttempt key) {
    _validate(key);
    if (_cancelledScopes.contains(key.scope)) {
      return Future.error(ConnectionCanceledException());
    }
    final existing = _closes[key];
    if (existing != null) return existing;
    final lease = _prepareLease(key);
    if (lease == null || lease.scopeCancelled || lease.current.key != key) {
      return Future.error(ConnectionCanceledException());
    }
    _closingKey = key;
    final future = _closeTransport(observePendingClose: true).then((_) {
      if (_cancelledScopes.contains(key.scope) || _closingKey != key) {
        throw ConnectionCanceledException();
      }
      _events.add(NetworkReconnectEvent(
          NetworkReconnectEventKind.websocketClosed, key));
    }, onError: (Object error, StackTrace stack) {
      fail(key, error);
      Error.throwWithStackTrace(error, stack);
    });
    _closes[key] = future;
    return future;
  }

  Future<void> _closeTransport({bool observePendingClose = false}) {
    connection.cancelReconnectTimers();
    connection.invalidateSocketCallbacks();
    connection.chat.commandManager.clearCompleterMap();
    connection.chat.commandManager.cancelAckTimers();
    final login = connection.chat.chatContext.loginCompleter;
    if (login != null && !login.isCompleted) {
      login.future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      login.completeError(ConnectionCanceledException());
    }
    connection.chat.chatContext.loginCompleter = null;
    final socket = connection.webSocketClient;
    final existing = _socketCloses[socket];
    if (existing != null) {
      return observePendingClose ? existing : _transportClosed;
    }
    if (_closedSockets[socket] == true) return _transportClosed;
    final closing = Future<bool>.sync(socket.close)
        .timeout(_closeBudget).then<void>((closed) {
      if (!closed) throw WebSocketFailedException();
    });
    final settled = closing.then<void>((_) {},
        onError: (Object _, StackTrace __) {});
    _transportClosed = Future.wait<void>([_transportClosed, settled])
        .then<void>((_) {});
    _socketCloses[socket] = closing;
    settled.then((_) {
      _socketCloses.remove(socket);
      _closedSockets[socket] = true;
    });
    return closing;
  }

  _ReconnectLease? _prepareLease(NetworkReconnectAttempt key) {
    final existing = _leases[key.generation];
    if (existing != null) {
      return existing.current.key.scope == key.scope ? existing : null;
    }
    if (_cancelledScopes.contains(key.scope) ||
        key.attempt != NetworkReconnectAttempt.initialAttempt ||
        (_latestGeneration != null && key.generation <= _latestGeneration!)) {
      return null;
    }
    cancelAll();
    final lease = _ReconnectLease(_ReconnectAttempt(key),
        _ReconnectCredentials(connection.chat.chatContext));
    _latestGeneration = key.generation;
    _leases[key.generation] = lease;
    _lease = lease;
    while (_leases.length > _retainedGenerations) {
      final generation = _leases.keys.first;
      _leases.remove(generation);
      _closes.removeWhere((key, _) => key.generation == generation);
    }
    return lease;
  }

  @override
  Future<void> beginOrJoinReconnect(
      NetworkReconnectAttempt key, Duration deadline) {
    _validate(key);
    final existing = _leases[key.generation];
    if (existing != null && existing.current.key.scope != key.scope) {
      return Future.error(ArgumentError(_invalidKey));
    }
    final lease = _prepareLease(key);
    if (lease == null) return Future.error(ConnectionCanceledException());
    final attempt = lease.current;
    if (attempt.started || attempt.cancelled || !identical(lease, _lease)) {
      return lease.future;
    }
    attempt.deadline = deadline;
    attempt.started = true;
    _closingKey = key;
    _armDeadline(attempt);
    _start(attempt, close: !_closes.containsKey(key));
    return lease.future;
  }

  Future<void> _start(_ReconnectAttempt attempt, {required bool close}) async {
    try {
      if (close) await _closeTransport();
      else await _closes[attempt.key];
      await _transportClosed;
      if (!isCurrent(attempt.key)) return;
      _closingKey = null;
      await connection.startOwnedReconnect(attempt.key);
    } catch (error) {
      fail(attempt.key, error);
    }
  }

  void _armDeadline(_ReconnectAttempt attempt) {
    _deadlineTimer?.cancel();
    _deadlineTimer = Timer(attempt.deadline! - now, () {
      fail(attempt.key, TimeoutException(_deadlineExceeded));
    });
  }

  Timer schedule(NetworkReconnectAttempt key, Duration delay,
      Future<void> Function() action) {
    final attempt = _lease!.current;
    final remaining = attempt.deadline! - now;
    _deadlineTimer?.cancel();
    final expiresFirst = remaining <= delay;
    final timer = Timer(expiresFirst ? remaining : delay, () {
      if (expiresFirst) {
        fail(key, TimeoutException(_deadlineExceeded));
      } else if (isCurrent(key)) {
        _armDeadline(attempt);
        action();
      }
    });
    _deadlineTimer = timer;
    return timer;
  }

  @override
  void resetBackoff(NetworkReconnectAttempt key, Duration deadline) {
    if (!isAuthenticating(key)) return;
    final attempt = _lease!.current;
    if (attempt.deadline == null) return;
    if (deadline < attempt.deadline!) {
      attempt.deadline = deadline;
    }
    _armDeadline(attempt);
    connection.chat.chatContext.reconnectTask?.increaseRetryCount(reset: true);
    connection.startScheduledReconnectNow(key);
  }

  @override
  Future<void> retryReconnect(NetworkReconnectAttempt key, Duration deadline) {
    _validate(key);
    final lease = _leases[key.generation];
    if (lease == null || !identical(lease, _lease) ||
        lease.current.key.scope != key.scope ||
        lease.scopeCancelled ||
        _cancelledScopes.contains(key.scope) ||
        key.attempt != NetworkReconnectAttempt.retryAttempt) {
      return Future.error(ConnectionCanceledException());
    }
    final existing = lease.attempts[key.attempt];
    if (existing != null) {
      return existing == lease.current ? lease.future : existing.completer.future;
    }
    if (lease.current.authenticated) return lease.current.completer.future;
    cancelAttempt(lease.current.key);
    final attempt = _ReconnectAttempt(key, deadline)..started = true;
    _recoveryScope = null;
    lease.current = attempt;
    lease.releasedFuture = null;
    lease.attempts[key.attempt] = attempt;
    _armDeadline(attempt);
    _start(attempt, close: true);
    return attempt.completer.future;
  }

  @override
  void cancelAttempt(NetworkReconnectAttempt key) {
    final lease = _leases[key.generation];
    final attempt = lease?.attempts[key.attempt];
    if (attempt == null || attempt.key != key) return;
    if (_lease?.current == attempt && _recoveryScope == key.scope) {
      _recoveryScope = null;
      _closeTransport().then<void>((_) {},
          onError: (Object _, StackTrace __) {});
    }
    if (attempt.cancelled) return;
    if (attempt.authenticated && lease!.current == attempt) {
      _releaseLease(lease, ConnectionCanceledException());
    }
    attempt.authenticated = false;
    attempt.cancelled = true;
    if (!attempt.completer.isCompleted) {
      attempt.completer.completeError(ConnectionCanceledException());
    }
    if (_lease?.current == attempt) {
      _deadlineTimer?.cancel();
      _closeTransport().then<void>((_) {},
          onError: (Object _, StackTrace __) {});
    }
  }

  @override
  void cancelScope(String scope) {
    _cancelledScopes.add(scope);
    if (_cancelledScopes.length > _cancelledScopeLimit) {
      _cancelledScopes.remove(_cancelledScopes.first);
    }
    for (final lease in _leases.values) {
      if (lease.current.key.scope == scope) {
        if (!lease.scopeCancelled) {
          lease.releasedFuture = _releasedError(ConnectionCanceledException());
        }
        lease.scopeCancelled = true;
        for (final attempt in lease.attempts.values) {
          cancelAttempt(attempt.key);
        }
      }
    }
    if (_closingKey?.scope == scope || _recoveryScope == scope) {
      _closingKey = null;
      _recoveryScope = null;
      _closeTransport().then<void>((_) {},
          onError: (Object _, StackTrace __) {});
    }
  }

  void cancelAll() {
    final closing = _closingKey;
    if (closing != null) cancelScope(closing.scope);
    final recovery = _recoveryScope;
    if (recovery != null) cancelScope(recovery);
    for (final lease in _leases.values.toList()) {
      cancelScope(lease.current.key.scope);
    }
  }

  @override
  Future<void> joinGeneration(int generation) {
    _currentGeneration = generation;
    return _leases[generation]?.future ??
        Future.error(StateError(_unknownGeneration));
  }

  NetworkSocketAttempt reserveSdkAttempt() => _newSdkAttempt(_nextSdkAttempt);

  NetworkSocketAttempt createSdkAttempt() => _newSdkAttempt(_nextSdkAttempt++);

  NetworkSocketAttempt _newSdkAttempt(int attempt) => NetworkSocketAttempt(
      NetworkReconnectAttempt(scope: NetworkReconnectAttempt.sdkScope,
          sdkInstance: sdkInstance, generation: _currentGeneration,
          attempt: attempt), _events.add);

  void scheduled(NetworkReconnectAttempt key, Duration at) {
    if (isCurrent(key)) {
      _events.add(NetworkReconnectEvent(
          NetworkReconnectEventKind.reconnectScheduled, key, scheduledAt: at));
    }
  }

  void started(NetworkReconnectAttempt key) {
    if (isCurrent(key)) {
      _events.add(NetworkReconnectEvent(
          NetworkReconnectEventKind.reconnectStarted, key));
    }
  }

  bool closed(NetworkReconnectAttempt key, {Object? error}) {
    if (!isCurrent(key)) return false;
    final lease = _lease!;
    final wasAuthenticated = lease.current.authenticated;
    final failure = error ?? WebSocketFailedException();
    _events.add(NetworkReconnectEvent(
        NetworkReconnectEventKind.websocketClosed, key));
    fail(key, failure);
    return wasAuthenticated;
  }

  void _releaseLease(_ReconnectLease lease, Object error) {
    lease.releasedFuture = _releasedError(error);
    if (_closingKey == lease.current.key) _closingKey = null;
  }

  Future<void> _releasedError(Object error) => _futureZone.run(() {
    final released = Future<void>.error(error);
    released.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return released;
  });

  void authenticated(NetworkReconnectAttempt key) {
    if (!isCurrent(key)) return;
    final attempt = _lease!.current;
    if (attempt.completer.isCompleted) return;
    attempt.authenticated = true;
    _deadlineTimer?.cancel();
    _events.add(NetworkReconnectEvent(
        NetworkReconnectEventKind.authenticated, key));
    attempt.completer.complete();
  }

  void fail(NetworkReconnectAttempt key, Object error) {
    final attempt = _lease?.current;
    if (attempt == null || attempt.key != key || attempt.cancelled) return;
    final wasAuthenticated = attempt.authenticated;
    if (wasAuthenticated) _releaseLease(_lease!, error);
    _events.add(NetworkReconnectEvent(
        NetworkReconnectEventKind.authenticationFailed, key, error: error));
    attempt.authenticated = false;
    if (!attempt.completer.isCompleted) attempt.completer.completeError(error);
    cancelAttempt(key);
    if (wasAuthenticated) _recoveryScope = key.scope;
  }
}

class NetworkSocketAttempt {
  NetworkSocketAttempt(this.key, this._emit);
  final NetworkReconnectAttempt key;
  final void Function(NetworkReconnectEvent) _emit;
  bool hasStarted = false;
  bool _authenticated = false;
  bool _terminated = false;

  void scheduled(Duration at) => _emit(NetworkReconnectEvent(
      NetworkReconnectEventKind.reconnectScheduled, key, scheduledAt: at));

  void started() {
    if (hasStarted || _terminated) return;
    hasStarted = true;
    _emit(NetworkReconnectEvent(NetworkReconnectEventKind.reconnectStarted, key));
  }

  void authenticated() {
    if (_authenticated || _terminated) return;
    _authenticated = true;
    _emit(NetworkReconnectEvent(NetworkReconnectEventKind.authenticated, key));
  }

  void closed({Object? error}) {
    if (_terminated) return;
    _terminated = true;
    _emit(NetworkReconnectEvent(error == null
        ? NetworkReconnectEventKind.websocketClosed
        : NetworkReconnectEventKind.authenticationFailed, key, error: error));
  }
}

class _ReconnectLease {
  _ReconnectLease(this.current, this.credentials) {
    attempts[current.key.attempt] = current;
  }
  final _ReconnectCredentials credentials;
  _ReconnectAttempt current;
  bool scopeCancelled = false;
  Future<void>? releasedFuture;
  Future<void> get future => releasedFuture ?? current.completer.future;
  final Map<int, _ReconnectAttempt> attempts = {};
}

class _ReconnectCredentials {
  _ReconnectCredentials(ChatContext context)
      : userId = context.currentUserId,
        accessToken = context.accessToken,
        sessionKey = context.sessionKey,
        nickname = context.nickname,
        apiHost = context.apiHost,
        wsHost = context.wsHost;

  final String? userId;
  final String? accessToken;
  String? sessionKey;
  final String? nickname;
  final String? apiHost;
  final String? wsHost;

  bool matches(ChatContext context, String requestedUserId,
      {String? accessToken, String? nickname, String? apiHost, String? wsHost}) =>
      userId == requestedUserId &&
      userId == context.currentUserId &&
      this.accessToken == accessToken &&
      this.accessToken == context.accessToken &&
      sessionKey == context.sessionKey &&
      (nickname == null || this.nickname == nickname) &&
      this.apiHost == (apiHost ?? context.apiHost) &&
      this.wsHost == (wsHost ?? context.wsHost);
}

class _ReconnectAttempt {
  _ReconnectAttempt(this.key, [this.deadline]) {
    completer.future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  }
  final NetworkReconnectAttempt key;
  Duration? deadline;
  bool started = false;
  final Completer<void> completer = Completer<void>();
  bool cancelled = false;
  bool authenticated = false;
}
