part of 'connection_manager.dart';

extension _NetworkConnection on ConnectionManager {
  static const _recoveryDelay = Duration(seconds: 1);
  static const _statSettlingDelay = Duration(milliseconds: 1);
  static const _initialConnectTrial = 1;

  Future<void> _handleConnectError(Object e,
      NetworkReconnectAttempt? ownedAttempt, Object? socket,
      Completer<User> login, String userId, String url,
      bool isDelayedConnecting) async {
    bool isCurrent() => isCallbackCurrent(ownedAttempt, socket) &&
        identical(login, chat.chatContext.loginCompleter);
    if (!isCallbackCurrent(ownedAttempt, socket)) return;
    if (ownedAttempt != null) {
      _onOwnedReconnectError(ownedAttempt, socket, e);
      return;
    }
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
                userId, e, shouldProceed: isCurrent);
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
            !isCallbackCurrent(null, socket)) {
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
  NetworkSocketAttempt? get _callbackSdkAttempt =>
      Zone.current[ConnectionManager._sdkAttemptZone] as NetworkSocketAttempt?;

  bool _isSocketStartCurrent(NetworkReconnectAttempt? key, Object? socket) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    return isCallbackCurrent(key, socket) &&
        (reservation == null || identical(reservation, _sdkReservation));
  }

  void _cancelScheduledSdkReconnect(Object? socket) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    if (reservation is! NetworkSocketAttempt ||
        !identical(reservation, _sdkReservation) ||
        !identical(socket, _socketIdentity) || networkReconnect.ownsReconnect) return;
    _sdkReservation = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    _scheduledReconnectAction = null;
    _scheduledAttempt = null;
    changeState(_sdkAttempt?.isAuthenticated == true && webSocketClient.isConnected()
        ? ConnectedState(chat: chat) : DisconnectedState(chat: chat));
    reservation.closed(error: ConnectionCanceledException());
  }

  void _connectSocket(NetworkReconnectAttempt? key, String url,
      {String? accessToken, String? sessionKey, bool reconnect = false}) {
    final reservation = Zone.current[ConnectionManager._sdkReservationZone];
    final previousAttempt = _sdkAttempt;
    webSocketClient.connect(url: url, accessToken: accessToken,
        sessionKey: sessionKey, reconnect: reconnect,
        onTransportStart: (connect) => _startSocketTransport(key, connect));
    if (identical(reservation, _sdkReservation)) _sdkReservation = null;
    if (key == null && identical(previousAttempt, _sdkAttempt) &&
        previousAttempt?.isAuthenticated == true && webSocketClient.isConnected()) {
      changeState(ConnectedState(chat: chat));
    }
  }

  void _startSocketTransport(NetworkReconnectAttempt? key, void Function() connect) {
    _sdkReservation = null;
    if (key != null) {
      networkReconnect.started(key);
      runZoned(connect, zoneValues: {ConnectionManager._sdkAttemptZone: null,
        ConnectionManager._socketZone: _socketIdentity,
        ConnectionManager._sdkReservationZone: null});
      return;
    }
    final attempt = networkReconnect.createSdkAttempt();
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

  Timer _scheduleSocketReconnect(NetworkReconnectAttempt? key, Duration delay,
      Future<void> Function() action) {
    if (key != null) {
      networkReconnect.scheduled(key, networkReconnect.now + delay);
      return networkReconnect.schedule(key, delay, action);
    }
    final attempt = networkReconnect.reserveSdkAttempt(preserveConnection:
        _sdkAttempt?.isActive == true && webSocketClient.isConnected());
    _sdkReservation = attempt;
    attempt.scheduled(networkReconnect.now + delay);
    return Timer(delay, () => runZoned(action,
        zoneValues: {ConnectionManager._sdkAttemptZone: null,
          ConnectionManager._sdkReservationZone: attempt}));
  }
  Future<void> _startOwnedReconnect(NetworkReconnectAttempt key) async {
    if (!networkReconnect.isCurrent(key)) return;
    webSocketClient = createWebSocketClient(key);
    final started = await doReconnect(reset: true, ownedAttempt: key);
    if (!started) networkReconnect.fail(key, ConnectionRequiredException());
  }

  void _startScheduledReconnectNow(NetworkReconnectAttempt key) {
    final action = _scheduledReconnectAction;
    if (_scheduledAttempt != key || action == null) return;
    reconnectTimer?.cancel();
    _scheduledReconnectAction = null;
    _scheduledAttempt = null;
    action();
  }

  WebSocketClient _createWebSocketClient(NetworkReconnectAttempt? key) {
    final socket = Object();
    _socketIdentity = socket;
    _socketInvalidated = false;
    _sdkAttempt = null;
    _sdkReservation = null;
    T dispatch<T>(T Function() action) => runZoned(action,
        zoneValues: {ConnectionManager._attemptZone: key,
          ConnectionManager._socketZone: callbackSocket ?? socket,
          ConnectionManager._sdkAttemptZone: key == null
              ? _callbackSdkAttempt ?? _sdkAttempt : null});
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
      managedReconnect: key != null,
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
    final key = callbackAttempt;
    if (!isCallbackCurrent(key, callbackSocket)) return;
    if (key == null) _callbackSdkAttempt?.closed();
    final recoverAuthenticated = key != null && networkReconnect.closed(key);
    if (key != null && !recoverAuthenticated) return;
    if (networkReconnect.ownsReconnect) return;
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
    if ((recoverAuthenticated || isConnected() || isReconnecting()) &&
        !webSocketClient.isConnected()) {
      if (_reconnectIfNeededTimer != null) {
        _reconnectIfNeededTimer!.cancel();
      }
      _reconnectIfNeededTimer = Timer(_recoveryDelay, () async {
        if ((recoverAuthenticated || isConnected() || isReconnecting()) &&
            !webSocketClient.isConnected()) {
          sbLog.d(StackTrace.current, '_reconnectIfNeeded()');
          await _reconnectIfNeeded();
        }
      });
    }
  }

  Future<void> _onWebSocketData(dynamic data) async {
    final key = callbackAttempt;
    final socket = callbackSocket;
    if (!isCallbackCurrent(key, socket)) return;
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
          if (!isCallbackCurrent(key, socket)) return;
          if (key != null && networkReconnect.isAuthenticating(key) &&
              (command.isError || command.hasError || command.isBusy)) {
            networkReconnect.fail(key, SendbirdException(
                code: command.errorCode, message: command.errorMessage));
            return;
          }
          await chat.commandManager.processCommand(command);
        }
      } catch (e) {
        sbLog.e(StackTrace.current, 'e: $e');
        rethrow;
      }
    }, (e, s) {
      if (!isCallbackCurrent(key, socket)) return;
      if (key != null) {
        if (networkReconnect.isAuthenticating(key)) {
          networkReconnect.fail(key, e);
        } else {
          _onWebSocketError(e);
        }
        return;
      }
      _callbackSdkAttempt?.closed(error: e);
      if (chat.chatContext.loginCompleter != null &&
          !chat.chatContext.loginCompleter!.isCompleted) {
        chat.chatContext.loginCompleter?.completeError(e);
      }
    });
  }

  Future<void> _onWebSocketError(Object e) async {
    final key = callbackAttempt;
    if (!isCallbackCurrent(key, callbackSocket)) return;
    if (key == null) _callbackSdkAttempt?.closed(error: e);
    if (key != null) {
      if (!networkReconnect.closed(key, error: e)) return;
    }
    // Immediately fail pending ACK completers so messages go to auto-resend
    // without waiting for the full ACK timeout (webSocketTimeout = 30s).
    // This is especially important on iOS where the watchdog detects a dead
    // socket via the error path (not the clean close path).
    chat.commandManager.clearCompleterMap(
      e: WebSocketFailedException(message: e.toString()),
    );
    await _reconnectIfNeeded();
  }

  void _onOwnedReconnectError(
      NetworkReconnectAttempt key, Object? socket, Object error) {
    if (networkReconnect.isAuthenticating(key)) {
      networkReconnect.fail(key, error);
      return;
    }
    runZoned(() => _onWebSocketError(error), zoneValues: {
      ConnectionManager._attemptZone: key,
      ConnectionManager._socketZone: socket,
    });
  }

  Future<void> _reconnectIfNeeded() async {
    if (networkReconnect.ownsReconnect) {
      await networkReconnect.currentFuture?.then<void>((_) {},
          onError: (Object _, StackTrace __) {});
      return;
    }
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
    _scheduledReconnectAction = null;
    _scheduledAttempt = null;
  }

}
