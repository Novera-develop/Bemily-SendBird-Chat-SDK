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
        if (!identical(login, chat.chatContext.loginCompleter) ||
            !isCallbackCurrent(socket)) {
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
    return isCallbackCurrent(socket) &&
        (reservation == null || identical(reservation, _sdkReservation));
  }

  void _cancelScheduledSdkReconnect(Object? socket) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    if (reservation is! SocketAttempt ||
        !identical(reservation, _sdkReservation) ||
        !identical(socket, _socketIdentity)) return;
    _sdkReservation = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    changeState(_sdkAttempt?.isAuthenticated == true && webSocketClient.isConnected()
        ? ConnectedState(chat: chat) : DisconnectedState(chat: chat));
    reservation.closed(error: ConnectionCanceledException());
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
    }
  }

  void _startSocketTransport(void Function() connect) {
    _sdkReservation = null;
    final attempt = socketTracker.createSdkAttempt();
    _sdkAttempt = attempt;
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
    final attempt = socketTracker.reserveSdkAttempt(preserveConnection:
        _sdkAttempt?.isActive == true && webSocketClient.isConnected());
    _sdkReservation = attempt;
    attempt.scheduled(socketTracker.now + delay);
    return Timer(delay, () => runZoned(action,
        zoneValues: {ConnectionManager._sdkAttemptZone: null,
          ConnectionManager._sdkReservationZone: attempt}));
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
    // Nothing to do here.
  }

  void _onWebSocketClosed() async {
    if (!isCallbackCurrent(callbackSocket)) return;
    _callbackSdkAttempt?.closed();
    chat.commandManager.clearCompleterMap();
    chat.commandManager
        .cancelAckTimers(); // Cancel ack timers to prevent AckTimeoutException

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
    // Immediately fail pending ACK completers so messages go to auto-resend
    // without waiting for the full ACK timeout (webSocketTimeout = 30s).
    // This is especially important on iOS where the watchdog detects a dead
    // socket via the error path (not the clean close path).
    chat.commandManager.clearCompleterMap(
      e: WebSocketFailedException(message: e.toString()),
    );
    await _reconnectIfNeeded();
  }

  Future<void> _reconnectIfNeeded() async {
    final socket = _socketIdentity;
    sbLog.d(StackTrace.current);
    if (chat.chatContext.currentUser != null) {
      if (isReconnecting()) {
        await Future.delayed(_statSettlingDelay); // [Timing issue] Because of endWsConnectStat()
        if (!identical(socket, _socketIdentity)) return;
        await reconnect(reset: false);
      } else {
        await disconnect(logout: false);
        if (!identical(socket, _socketIdentity)) return;
        await reconnect(reset: true);
      }
    }
  }

  void _cancelReconnectTimers() {
    _sdkReservation = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    _reconnectIfNeededTimer?.cancel();
    _reconnectIfNeededTimer = null;
  }

}
