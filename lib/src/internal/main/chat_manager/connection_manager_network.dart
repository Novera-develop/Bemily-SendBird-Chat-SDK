part of 'connection_manager.dart';

extension _NetworkConnection on ConnectionManager {
  static const _recoveryDelay = Duration(seconds: 1);
  static const _statSettlingDelay = Duration(milliseconds: 1);
  static const _initialConnectTrial = 1;

  Future<void> _handleConnectError(Object e,
      Object? socket,
      Completer<User> login, String userId, String url,
      bool isDelayedConnecting) async {
    bool isCurrent() => isCallbackCurrent(socket) &&
        identical(login, chat.chatContext.loginCompleter);
    if (!isCallbackCurrent(socket)) return;
    if (!isCurrent()) return;
    sbLog.e(StackTrace.current, 'e: $e');
    if (isDelayedConnecting && _connectionAttempt != null) {
      _failAttempt(e);
      return;
    }

    if (!isDisconnected()) {
      if (!isDelayedConnecting) {
        changeState(DisconnectedState(chat: chat));
      }

      if (!login.isCompleted) {
        if (e is SendbirdException) {
          chat.statManager.endWsConnectStat(
            hostUrl: url,
            success: false,
            errorCode: e.code,
            errorDescription: e.message,
            accumTrial: isDelayedConnecting
                ? chat.chatContext.reconnectTask?.retryCount ?? _initialConnectTrial
                : _initialConnectTrial,
            isSoftRateLimited: isDelayedConnecting,
          );

          //+ [DBManager]
          if (chat.dbManager.isEnabled()) {
            final user = await chat.dbManager.getLoginInfoByException(
                userId, e);
            if (!isCurrent()) return;
            if (user != null) {
              if (!login.isCompleted) login.complete(user);
              chat.chatContext.loginCompleter = null;

              if (chat.chatContext.isChatConnected) {
                await chat.connectionManager.reconnect(reset: true);
              }
              return;
            }
          }
          //- [DBManager]

          if (isDelayedConnecting) {
            await chat.connectionManager.doReconnect(
              reset: false,
              isDelayedConnecting: true,
            );
          } else {
            if (!login.isCompleted) {
              login.completeError(e);
            }
          }
        } else {
          final exception = WebSocketFailedException(message: e.toString());

          chat.statManager.endWsConnectStat(
            hostUrl: url,
            success: false,
            errorCode: exception.code,
            errorDescription: exception.message,
            accumTrial: isDelayedConnecting
                ? chat.chatContext.reconnectTask?.retryCount ?? _initialConnectTrial
                : _initialConnectTrial,
            isSoftRateLimited: isDelayedConnecting,
          );

          if (isDelayedConnecting) {
            await chat.connectionManager.doReconnect(
              reset: false,
              isDelayedConnecting: true,
            );
          } else {
            if (!login.isCompleted) {
              login.completeError(exception);
            }
          }
        }
      }
    }
  }

  Future<User> _waitForLogin(Completer<User> login, Object? socket, String url) =>
      login.future.timeout(
          Duration(seconds: chat.chatContext.options.connectionTimeout),
          onTimeout: () async {
        final preservedLogin = identical(login, chat.chatContext.loginCompleter) &&
            identical(login, _refreshedLogin);
        if (!identical(login, chat.chatContext.loginCompleter) ||
            !isCallbackCurrent(socket)) {
          if (preservedLogin) {
            _preserveRecoverySession = true;
            _retryWithoutSessionKey = true;
            _cancelAttempt(TransportRecoveryResult.cancelled);
            _replaceTransport();
            _failPendingLogin(ConnectionCanceledException());
            changeState(DisconnectedState(chat: chat));
            notifyReconnectFailed();
          }
          throw ConnectionCanceledException();
        }
        final e = LoginTimeoutException();
        chat.statManager.endWsConnectStat(
          hostUrl: url,
          success: false,
          errorCode: e.code,
          errorDescription: e.name,
          accumTrial: _initialConnectTrial,
          isSoftRateLimited: false,
        );
        await doDisconnect(clear: true);
        throw e;
      });
  SocketAttempt? get _callbackSdkAttempt =>
      Zone.current[ConnectionManager._sdkAttemptZone] as SocketAttempt?;

  bool _isSocketStartCurrent(Object? socket) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    return _isAttemptCurrent && isCallbackCurrent(socket) &&
        (reservation == null || identical(reservation, _sdkReservation));
  }

  void _cancelScheduledSdkReconnect(Object? socket) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    if (reservation is! SocketAttempt ||
        !identical(reservation, _sdkReservation) ||
        !identical(socket, _socketIdentity)) return;
    _sdkReservation = null;
    _finishAttempt();
    reconnectTimer?.cancel();
    reconnectTimer = null;
    _scheduledReconnect = null;
    changeState(_sdkAttempt?.isAuthenticated == true && webSocketClient.isConnected()
        ? ConnectedState(chat: chat) : DisconnectedState(chat: chat));
    reservation.closed();
  }

  void _connectSocket(String url,
      {String? accessToken, String? sessionKey, bool reconnect = false}) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    final previousAttempt = _sdkAttempt;
    webSocketClient.connect(url: url, accessToken: accessToken,
        sessionKey: sessionKey, reconnect: reconnect,
        onTransportStart: (connect) => _startSocketTransport(connect));
    if (identical(reservation, _sdkReservation)) _sdkReservation = null;
    if (identical(previousAttempt, _sdkAttempt) &&
        previousAttempt?.isAuthenticated == true && webSocketClient.isConnected()) {
      changeState(ConnectedState(chat: chat));
      _finishAttempt();
      notifyReconnectSucceeded();
    }
  }

  void _startSocketTransport(void Function() connect) {
    _sdkReservation = null;
    final attempt = socketTracker.createSdkAttempt();
    _sdkAttempt = attempt;
    _connectionAttempt?.phase = ConnectionAttemptPhase.handshake;
    attempt.started();
    runZonedGuarded(connect, (error, stack) {
      if (!identical(attempt, _sdkAttempt)) return;
      attempt.closed(error: error);
      Error.throwWithStackTrace(error, stack);
    }, zoneValues: {ConnectionManager._sdkAttemptZone: attempt,
      ConnectionManager._socketZone: _socketIdentity,
      ConnectionManager._sdkReservationZone: null});
  }

  Timer _scheduleSocketReconnect(Duration delay,
      Future<void> Function() action) {
    final publicConnect = _publicConnectIdentity;
    final attempt = socketTracker.reserveSdkAttempt(preserveConnection:
        _sdkAttempt?.isActive == true && webSocketClient.isConnected());
    _sdkReservation = attempt;
    attempt.scheduled(socketTracker.now + delay);
    final inherited = Zone.current[ConnectionManager._connectionAttemptZone];
    final existing = identical(inherited, _connectionAttempt)
        ? _connectionAttempt : null;
    if (existing == null) _finishAttempt();
    _retryAt = now.add(delay);
    Future<void> start() async {
      if (!identical(attempt, _sdkReservation)) return;
      reconnectTimer = null;
      _scheduledReconnect = null;
      final connectionAttempt = existing ?? _beginAttempt(
          chat.chatContext.options.reconnectAttemptDeadline);
      if (!connectionAttempt.active) return;
      _retryAt = null;
      await runZoned(() async {
        try {
          await action();
        } catch (error) {
          if (_isAttemptCurrent) _failAttempt(error);
        }
      }, zoneValues: {
        ConnectionManager._publicConnectZone: publicConnect,
        ConnectionManager._sdkAttemptZone: null,
        ConnectionManager._sdkReservationZone: attempt,
        ConnectionManager._connectionAttemptZone: connectionAttempt,
      });
    }
    _scheduledReconnect = start;
    return Timer(delay, start);
  }

  WebSocketClient _createWebSocketClient() {
    final socket = Object();
    _socketIdentity = socket;
    _sdkAttempt = null;
    _sdkReservation = null;
    T dispatch<T>(T Function() action) => runZoned(action,
        zoneValues: {ConnectionManager._socketZone: callbackSocket ?? socket,
          ConnectionManager._sdkAttemptZone: _callbackSdkAttempt ?? _sdkAttempt});
    final factory = socketFactory;
    if (factory != null) {
      return factory(
        (data) => dispatch(() => _onWebSocketData(data)),
        () => dispatch(_onWebSocketClosed),
        (error) => dispatch(() => _onWebSocketError(error)),
      );
    }
    return WebSocketClient(
      chat: chat,
      chatContext: chat.chatContext,
      onWebSocketConnected: () => dispatch(_onWebSocketConnected),
      onWebSocketClosed: () => dispatch(_onWebSocketClosed),
      onWebSocketData: (data) => dispatch(() => _onWebSocketData(data)),
      onWebSocketError: (error) => dispatch(() => _onWebSocketError(error)),
    );
  }

//------------------------------//
// WebSocket Event Listener
//------------------------------//
  void _onWebSocketConnected() {
    if (!isCallbackCurrent(callbackSocket)) return;
    _connectionAttempt?.phase = ConnectionAttemptPhase.authenticating;
  }

  void _onWebSocketClosed() async {
    if (!isCallbackCurrent(callbackSocket)) return;
    _callbackSdkAttempt?.closed();
    _failPendingLogin(WebSocketFailedException(sendStage: SendStage.afterWrite));
    chat.commandManager.clearCompleterMap();
    chat.commandManager
        .cancelAckTimers(); // Cancel ack timers to prevent AckTimeoutException

    if (_connectionAttempt?.phase == ConnectionAttemptPhase.preparing) return;
    if (_recovery != null) {
      _failAttempt(WebSocketFailedException(sendStage: SendStage.afterWrite));
      return;
    }
    _finishAttempt();
    final closeCode = webSocketClient.getCloseCode();
    if (closeCode != null) {
      chat.statManager.appendWsDisconnectStat(
        success: true,
        errorCode: SendbirdError.webSocketConnectionClosed,
        errorDescription: "cause=$closeCode",
      );
    }

    // On iOS, when connection is automatically disconnected after 1 hour in idle state,
    // attempt reconnection if still in connected/reconnecting state after 1 second.
    // Also handles the case where AckTimeout forced WS close while in ReconnectingState
    // (e.g., connectivity-triggered reconnect fired but connect() returned early because
    // WS appeared still connected, then AckTimeout detected the dead WS and closed it).
    if ((isConnected() || isReconnecting()) &&
        !webSocketClient.isConnected()) {
      if (_reconnectIfNeededTimer != null) {
        _reconnectIfNeededTimer!.cancel();
      }
      _reconnectIfNeededTimer = Timer(_recoveryDelay, () async {
        if ((isConnected() || isReconnecting()) &&
            !webSocketClient.isConnected()) {
          sbLog.d(StackTrace.current, '_reconnectIfNeeded()');
          await _reconnectIfNeeded();
        }
      });
    }
  }

  Future<void> _onWebSocketData(dynamic data) async {
    final socket = callbackSocket;
    if (!isCallbackCurrent(socket)) return;
    if (data == null) return;

    String commandString;
    if (data.runtimeType == String) {
      commandString = (data as String);
    } else {
      commandString =
          const Utf8Decoder(allowMalformed: true).convert(data as List<int>);
    }

    if (commandString.isEmpty) return;
    List<Command> commands = CommandManager.parseCommandsString(commandString);
    if (commands.isEmpty) return;

    runZonedGuarded(() async {
      try {
        for (final command in commands) {
          if (!isCallbackCurrent(socket)) return;
          await chat.commandManager.processCommand(command);
        }
      } catch (e) {
        sbLog.e(StackTrace.current, 'e: $e');
        rethrow;
      }
    }, (e, s) {
      if (!isCallbackCurrent(socket)) return;
      _callbackSdkAttempt?.closed(error: e);
      if (chat.chatContext.loginCompleter != null &&
          !chat.chatContext.loginCompleter!.isCompleted) {
        chat.chatContext.loginCompleter?.completeError(e);
      }
    });
  }

  Future<void> _onWebSocketError(Object e) async {
    if (!isCallbackCurrent(callbackSocket)) return;
    _callbackSdkAttempt?.closed(error: e);
    _failPendingLogin(WebSocketFailedException(message: e.toString(),
        sendStage: SendStage.afterWrite));
    // Immediately fail pending ACK completers so messages go to auto-resend
    // without waiting for the full ACK timeout (webSocketTimeout = 30s).
    // This is especially important on iOS where the watchdog detects a dead
    // socket via the error path (not the clean close path).
    chat.commandManager.clearCompleterMap(
      e: WebSocketFailedException(message: e.toString()),
    );
    if (_recovery != null || _preserveRecoverySession) {
      _failAttempt(e);
      return;
    }
    _finishAttempt();
    await _reconnectIfNeeded();
  }

  void _failPendingLogin(Object error) {
    final login = chat.chatContext.loginCompleter;
    chat.chatContext.loginCompleter = null;
    if (identical(login, _refreshedLogin)) _refreshedLogin = null;
    if (login != null && !login.isCompleted) login.completeError(error);
    if (isConnecting()) changeState(DisconnectedState(chat: chat));
  }

  Future<void> _reconnectIfNeeded() async {
    if (_authRequired || chat.isBackground || _recovery != null) return;
    final socket = _socketIdentity;
    if (chat.chatContext.currentUser == null) {
      if (_isPublicConnectCurrent && isCallbackCurrent(callbackSocket) &&
          isReconnecting()) {
        changeState(DisconnectedState(chat: chat));
        notifyReconnectFailed();
      }
      return;
    }
    if (isReconnecting()) {
      await Future.delayed(_statSettlingDelay);
      if (!identical(socket, _socketIdentity)) return;
      await reconnect(reset: false);
    } else {
      await _runBoundedReconnect(() async {
        await disconnect(logout: false);
        if (!_isAttemptCurrent || !identical(socket, _socketIdentity)) return;
        await reconnect(reset: true);
      });
    }
  }

  void _cancelReconnectTimers() {
    final state = _currentState;
    if (state is DelayedConnectingState) state.cancelRetryAfterTimer();
    _serverRetryOwner = null;
    _scheduledReconnect = null;
    _retryAt = null;
    _sdkReservation = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    _reconnectIfNeededTimer?.cancel();
    _reconnectIfNeededTimer = null;
  }

}

extension _ConnectionRecovery on ConnectionManager {
  Future<void> _runBoundedReconnect(Future<void> Function() action) {
    final attempt = _beginAttempt(chat.chatContext.options.reconnectAttemptDeadline);
    final operation = runZoned(() async {
      try {
        await action();
      } catch (error) {
        if (_isAttemptCurrent) _failAttempt(error);
      }
    }, zoneValues: {ConnectionManager._connectionAttemptZone: attempt});
    return Future.any([operation, attempt.stopped.future]);
  }

  ConnectionAttemptSnapshot _getConnectionAttempt() {
    final attempt = _connectionAttempt;
    return ConnectionAttemptSnapshot(
      attemptId: attempt?.id,
      since: attempt?.since,
      deadline: attempt?.deadline,
      phase: attempt?.phase ?? (_retryAt != null
          ? ConnectionAttemptPhase.backoff : ConnectionAttemptPhase.idle),
      retryAt: _retryAt,
      authRequired: _authRequired,
    );
  }

  bool get _isAttemptCurrent {
    final attempt = Zone.current[ConnectionManager._connectionAttemptZone];
    return attempt == null ||
        (identical(attempt, _connectionAttempt) && _connectionAttempt?.active == true);
  }

  Duration get _serverDelay {
    final state = _currentState;
    if (_serverRetryAt == null && state is DelayedConnectingState) {
      _serverRetryAt = now.add(Duration(seconds: state.retryAfter));
    } else if (_serverRetryAt == null && state is DisconnectedState &&
        state.timeForDelayedConnectingState != null &&
        state.retryAfterForDelayedConnectingState != null) {
      _serverRetryAt = DateTime.fromMillisecondsSinceEpoch(
          state.timeForDelayedConnectingState!).add(
          Duration(seconds: state.retryAfterForDelayedConnectingState!));
    }
    final delay = _serverRetryAt?.difference(now) ?? Duration.zero;
    return delay > Duration.zero ? delay : Duration.zero;
  }

  void _finishAttempt() {
    _attemptDeadlineTimer?.cancel();
    _attemptDeadlineTimer = null;
    final attempt = _connectionAttempt;
    if (attempt != null) {
      attempt.active = false;
      if (!attempt.stopped.isCompleted) attempt.stopped.complete();
    }
    _connectionAttempt = null;
    _retryAt = null;
  }

  ConnectionAttempt _beginAttempt(Duration budget) {
    _finishAttempt();
    final attempt = ConnectionAttempt(budget, since: now);
    _connectionAttempt = attempt;
    _attemptDeadlineTimer = Timer(budget, () {
      if (!identical(attempt, _connectionAttempt)) return;
      _failAttempt(LoginTimeoutException(), timedOut: true, attempt: attempt);
    });
    return attempt;
  }

  void _completeRecovery(TransportRecoveryResult result) {
    _recoveryRetryAfterTimer?.cancel();
    _recoveryRetryAfterTimer = null;
    final recovery = _recovery;
    _recovery = null;
    if (recovery != null && !recovery.isCompleted) recovery.complete(result);
  }

  void _cancelAttempt(TransportRecoveryResult result) {
    final active = _connectionAttempt != null || _recovery != null;
    _finishAttempt();
    _cancelReconnectTimers();
    _completeRecovery(result);
    if (active) {
      _sdkAttempt?.closed();
      _sdkAttempt = null;
      _socketIdentity = Object();
    }
  }

  void _replaceTransport() {
    socketTracker.invalidateConnection();
    final previous = webSocketClient;
    _sdkAttempt?.closed();
    webSocketClient = _createWebSocketClient();
    previous.close().catchError((Object error, StackTrace stack) {
      sbLog.e(stack, error.toString());
      return false;
    });
  }

  void _failAttempt(Object error, {bool timedOut = false,
      ConnectionAttempt? attempt}) {
    if (attempt != null) {
      if (!identical(attempt, _connectionAttempt) || !attempt.active) return;
    } else if (!_isAttemptCurrent) {
      return;
    }
    if (!timedOut && !chat.isBackground &&
        _recovery != null && _connectionAttempt != null) {
      chat.commandManager.clearCompleterMap();
      chat.commandManager.cancelAckTimers();
      _replaceTransport();
      chat.chatContext.reconnectTask?.increaseRetryCount();
      final backoff = Duration(seconds: chat.chatContext.reconnectTask?.backOffPeriod ??
          _NetworkConnection._initialConnectTrial);
      _waitForRecoveryRetryAfter(_connectionAttempt!,
          delay: _serverDelay > backoff ? _serverDelay : backoff);
      return;
    }
    _finishAttempt();
    _cancelReconnectTimers();
    chat.commandManager.clearCompleterMap();
    chat.commandManager.cancelAckTimers();
    final login = chat.chatContext.loginCompleter;
    if (timedOut && login != null && !login.isCompleted &&
        identical(login, _refreshedLogin)) {
      _preserveRecoverySession = true;
    } else {
      chat.chatContext.loginCompleter = null;
      if (login != null && !login.isCompleted) login.completeError(error);
      if (identical(login, _refreshedLogin)) _refreshedLogin = null;
    }
    _replaceTransport();
    _completeRecovery(timedOut
        ? TransportRecoveryResult.timeout : TransportRecoveryResult.cancelled);
    _retryBudgetExhausted = chat.chatContext.reconnectTask?.exceedRetryCount == true;
    if (_retryBudgetExhausted) _preserveRecoverySession = true;
    if (_preserveRecoverySession) {
      _retryWithoutSessionKey = true;
    }
    if (_retryBudgetExhausted || chat.isBackground ||
        chat.chatContext.currentUserId == null || _authRequired) {
      if (_retryBudgetExhausted) _failPendingLogin(ConnectionCanceledException());
      changeState(DisconnectedState(chat: chat));
      notifyReconnectFailed();
      return;
    }
    changeState(ReconnectingState(chat: chat));
    void retry() {
      _serverRetryAt = null;
      _retryAt = null;
      reconnectTimer = null;
      runZoned(() => doReconnect(foregroundOnly: true), zoneValues: {
        ConnectionManager._connectionAttemptZone: null,
        ConnectionManager._socketZone: null,
        ConnectionManager._sdkAttemptZone: null,
        ConnectionManager._sdkReservationZone: null,
      });
    }
    if (_serverDelay > Duration.zero) {
      _retryAt = _serverRetryAt;
      reconnectTimer = Timer(_serverDelay, retry);
    } else {
      retry();
    }
  }

  bool Function() _requireAuthentication() {
    final publicConnect = _publicConnectIdentity;
    _failPendingLogin(ConnectionCanceledException());
    _authRequired = true;
    replaceSessionOwner();
    _finishAttempt();
    _cancelReconnectTimers();
    _completeRecovery(TransportRecoveryResult.authRequired);
    chat.commandManager.clearCompleterMap();
    chat.commandManager.cancelAckTimers();
    _replaceTransport();
    changeState(DisconnectedState(chat: chat));
    final session = _authenticatedSessionIdentity;
    final socket = _socketIdentity;
    bool ownsTransition() => identical(publicConnect, _publicConnectIdentity) &&
        identical(session, _authenticatedSessionIdentity) &&
        identical(socket, _socketIdentity);
    if (_reconnectNotificationPending) notifyReconnectFailed();
    return ownsTransition;
  }

  void _sessionRefreshed() => _authRequired = false;

  void _respectRetryAfter(Duration delay, {DateTime? retryAt}) {
    _serverRetryAt = retryAt ?? now.add(delay);
    if (_recovery != null) {
      _replaceTransport();
      _waitForRecoveryRetryAfter(_connectionAttempt!);
    } else {
      _finishAttempt();
      _cancelReconnectTimers();
      _retryAt = _serverRetryAt;
    }
  }

  void _restoreServerRetry() {
    if (chat.isBackground || _authRequired || reconnectTimer?.isActive == true) return;
    final state = _currentState;
    if (state is DelayedConnectingState && state.retryAfterTimer?.isActive == true) return;
    final owner = Object();
    _serverRetryOwner = owner;
    final socket = _socketIdentity;
    final session = _authenticatedSessionIdentity;
    final attempt = _connectionAttempt;
    final sdkAttempt = _sdkAttempt;
    final login = chat.chatContext.loginCompleter;
    _retryAt = _serverRetryAt;
    reconnectTimer = Timer(_serverDelay, () {
      if (!identical(owner, _serverRetryOwner) ||
          !identical(socket, _socketIdentity) ||
          !identical(session, _authenticatedSessionIdentity) ||
          !identical(attempt, _connectionAttempt) ||
          !identical(sdkAttempt, _sdkAttempt) ||
          !identical(login, chat.chatContext.loginCompleter) ||
          isConnected() || connectionSnapshot.authenticated) return;
      _serverRetryOwner = null;
      reconnectTimer = null;
      _retryAt = null;
      _serverRetryAt = null;
      if (chat.isBackground || _authRequired) return;
      runZoned(() => doReconnect(reset: true, foregroundOnly: true), zoneValues: {
        ConnectionManager._connectionAttemptZone: null,
        ConnectionManager._socketZone: null,
        ConnectionManager._sdkAttemptZone: null,
        ConnectionManager._sdkReservationZone: null,
      });
    });
  }

  void _expireOverdueAttempt() {
    final attempt = _connectionAttempt;
    if (attempt != null && !attempt.deadline.isAfter(now)) {
      _failAttempt(LoginTimeoutException(), timedOut: true, attempt: attempt);
    }
  }

  bool get _hasPendingAttempt =>
      _sdkAttempt?.isActive == true || reconnectTimer?.isActive == true;

  Future<bool> _advanceReconnect({bool restarted = false}) {
    _expireOverdueAttempt();
    if (_authRequired && !chat.isBackground) {
      chat.sessionManager.renotifyExpiredCredentials();
    }
    if (chat.isBackground || _authRequired || _serverDelay > Duration.zero) {
      return Future.value(false);
    }
    if (_retryBudgetExhausted || (isDisconnected() && _retryWithoutSessionKey)) {
      if (restarted) return Future.value(true);
      return doReconnect(reset: _retryBudgetExhausted, foregroundOnly: true,
          restartWithoutLogin: true).then((started) {
        if (!started) return false;
        return _advanceReconnect(restarted: true);
      });
    }
    if (isConnected() || isDisconnected()) return Future.value(false);
    if (_recoveryRetryAfterTimer?.isActive == true && _connectionAttempt != null) {
      _recoveryRetryAfterTimer?.cancel();
      _recoveryRetryAfterTimer = null;
      _startRecovery(_connectionAttempt!);
      return Future.value(true);
    }
    if (_connectionAttempt?.active == true || _recovery != null) {
      return Future.value(true);
    }
    final action = _scheduledReconnect;
    if (reconnectTimer?.isActive != true || action == null) return Future.value(false);
    reconnectTimer?.cancel();
    reconnectTimer = null;
    action();
    return Future.value(true);
  }

  Future<TransportRecoveryResult> _recoverTransport({Duration? deadline}) {
    _expireOverdueAttempt();
    if (_recovery != null) return _recovery!.future;
    if (_authRequired) {
      if (!chat.isBackground) chat.sessionManager.renotifyExpiredCredentials();
      return Future.value(TransportRecoveryResult.authRequired);
    }
    if (chat.isBackground || chat.chatContext.currentUserId == null) {
      return Future.value(TransportRecoveryResult.cancelled);
    }
    _resetExhaustedRetryBudget();
    final delay = _serverDelay;
    final state = _currentState;
    if (state is DelayedConnectingState) state.retryAfterTimer?.cancel();
    _cancelAttempt(TransportRecoveryResult.cancelled);
    _preserveRecoverySession = true;
    final recovery = Completer<TransportRecoveryResult>();
    _recovery = recovery;
    final attempt = _beginAttempt(
        deadline ?? chat.chatContext.options.reconnectAttemptDeadline);
    _socketIdentity = Object();
    chat.commandManager.clearCompleterMap();
    chat.commandManager.cancelAckTimers();
    runZoned(() async {
      try {
        await doDisconnect(clear: false, logout: false);
        if (!_isAttemptCurrent) return;
        webSocketClient = _createWebSocketClient();
        changeState(ReconnectingState(chat: chat));
        if (delay > Duration.zero) {
          _waitForRecoveryRetryAfter(attempt);
        } else {
          await _startRecovery(attempt);
        }
      } catch (error) {
        if (_isAttemptCurrent) _failAttempt(error);
      }
    }, zoneValues: {
      ConnectionManager._connectionAttemptZone: attempt,
      ConnectionManager._socketZone: null,
      ConnectionManager._sdkAttemptZone: null,
      ConnectionManager._sdkReservationZone: null,
    });
    return recovery.future;
  }

  void _resetExhaustedRetryBudget({bool judgeTask = false}) {
    final task = chat.chatContext.reconnectTask;
    if (!_retryBudgetExhausted &&
        !(judgeTask && task?.exceedRetryCount == true)) return;
    if (task != null) chat.chatContext.reconnectTask = ReconnectTask(task.config);
    _retryBudgetExhausted = false;
  }

  void _waitForRecoveryRetryAfter(ConnectionAttempt attempt, {Duration? delay}) {
    final wait = delay ?? _serverDelay;
    attempt.phase = ConnectionAttemptPhase.backoff;
    _retryAt = now.add(wait);
    _recoveryRetryAfterTimer?.cancel();
    _recoveryRetryAfterTimer = Timer(wait, () {
      _serverRetryAt = null;
      _startRecovery(attempt);
    });
  }

  Future<void> _startRecovery(ConnectionAttempt attempt) async {
    if (!identical(attempt, _connectionAttempt) || !attempt.active) return;
    if (chat.isBackground) {
      _failAttempt(ConnectionCanceledException(), attempt: attempt);
      return;
    }
    _retryAt = null;
    attempt.phase = ConnectionAttemptPhase.preparing;
    final socket = _socketIdentity;
    try {
      changeState(ReconnectingState(chat: chat));
      notifyReconnectStarted();
      await runZoned(() => _reconnect(
          canStart: () => identical(attempt, _connectionAttempt) &&
              attempt.active && !chat.isBackground && !_authRequired),
          zoneValues: {
            ConnectionManager._connectionAttemptZone: attempt,
            ConnectionManager._socketZone: null,
            ConnectionManager._sdkAttemptZone: null,
            ConnectionManager._sdkReservationZone: null,
          });
    } catch (error) {
      if (identical(attempt, _connectionAttempt) &&
          identical(socket, _socketIdentity)) _failAttempt(error, attempt: attempt);
    }
  }
}
