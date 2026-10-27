// Copyright (c) 2023 Sendbird, Inc. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/collection_manager/collection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/collection_manager/message_retention_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/command_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/network_reconnect_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/base_connection_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/delayed_connecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/reconnect_task.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/disconnected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/reconnecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';
import 'package:sendbird_chat_sdk/src/public/core/user/user.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/exceptions.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/sendbird_error.dart';
import 'package:sendbird_chat_sdk/src/public/main/handler/network_path_hooks.dart';
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

import 'collection_manager/auto_resend_manager.dart';

part 'connection_manager_network.dart';

class ConnectionManager {
  Timer? reconnectTimer;
  static final _publicConnectZone = Object();
  Object _publicConnectIdentity = Object();
  bool get _isPublicConnectCurrent => Zone.current[_publicConnectZone] == null ||
      identical(Zone.current[_publicConnectZone], _publicConnectIdentity);
  static final _connectionAttemptZone = Object();
  ConnectionAttempt? _connectionAttempt;
  Timer? _attemptDeadlineTimer;
  Timer? _recoveryRetryAfterTimer;
  Future<void> Function()? _scheduledReconnect;
  DateTime? _retryAt;
  DateTime? _serverRetryAt;
  Object? _serverRetryOwner;
  Object _authenticatedSessionIdentity = Object();
  Object get authenticatedSessionIdentity => _authenticatedSessionIdentity;
  bool _authRequired = false;
  bool _preserveRecoverySession = false;
  Completer<TransportRecoveryResult>? _recovery;

  final Chat chat;
  late WebSocketClient webSocketClient;
  late BaseConnectionState _currentState;
  Timer? _reconnectIfNeededTimer;
  static final _socketZone = Object();
  static final _sdkAttemptZone = Object();
  static final _sdkReservationZone = Object();
  SocketAttempt? _sdkAttempt;
  SocketAttempt? _sdkReservation;
  Object? _socketIdentity;
  Object? _clearingSocket;
  bool _reconnectNotificationPending = false;
  bool get reconnectNotificationPending => _reconnectNotificationPending;
  bool get hasAuthenticatedTransport => webSocketClient.isConnected() &&
      connectionSnapshot.authenticated && !_authRequired;

  void notifyReconnectStarted() {
    if (_reconnectNotificationPending) return;
    _reconnectNotificationPending = true;
    chat.eventManager.notifyReconnectStarted();
  }

  void notifyReconnectSucceeded() {
    if (!_reconnectNotificationPending) return;
    _reconnectNotificationPending = false;
    chat.eventManager.notifyReconnectSucceeded();
  }

  void notifyReconnectFailed() {
    if (!_reconnectNotificationPending) return;
    _reconnectNotificationPending = false;
    chat.eventManager.notifyReconnectFailed();
  }

  Future<void> reconnectAfterDelay(DelayedConnectingState state) async {
    if (!identical(_currentState, state) || _authRequired || chat.isBackground ||
        connectionSnapshot.authenticated) return;
    final socket = _socketIdentity;
    final session = _authenticatedSessionIdentity;
    final publicConnect = _publicConnectIdentity;
    final attempt = _sdkAttempt;
    await doDisconnect(clear: false);
    if (!identical(socket, _socketIdentity) ||
        !identical(session, _authenticatedSessionIdentity) ||
        !identical(publicConnect, _publicConnectIdentity) ||
        !identical(attempt, _sdkAttempt) || !isDisconnected() ||
        _authRequired || chat.isBackground || connectionSnapshot.authenticated) return;
    await doReconnect(reset: true, isDelayedConnecting: true);
  }
  final WebSocketClient Function(OnWebSocketData, OnWebSocketClosed,
      OnWebSocketError)? socketFactory;

  late final SocketTracker socketTracker = SocketTracker(clock: reconnectClock);
  final Duration Function()? reconnectClock;
  final DateTime Function()? wallClock;
  DateTime get now => wallClock?.call() ?? DateTime.now();
  NetworkConnectionSnapshot get connectionSnapshot => socketTracker.connectionSnapshot;
  Object? get callbackSocket => Zone.current[_socketZone];
  Object? get socketIdentity => _socketIdentity;

  bool isCallbackCurrent(Object? socket) =>
      (socket == null || identical(socket, _socketIdentity)) &&
      (_callbackSdkAttempt == null || identical(_callbackSdkAttempt, _sdkAttempt));

  bool matchesSessionCredentials(String userId, {String? accessToken,
      String? apiHost, String? wsHost}) {
    final context = chat.chatContext;
    return context.currentUserId == userId && context.accessToken == accessToken &&
        context.apiHost == (apiHost ?? context.apiHost) &&
        context.wsHost == (wsHost ?? context.wsHost);
  }

  bool isLoginTransportCurrent(Object? socket) =>
      isCallbackCurrent(socket) && webSocketClient.isConnected() &&
      _sdkAttempt?.isActive == true;

  void authenticatedSocket() {
    if (!isLoginTransportCurrent(callbackSocket)) return;
    _callbackSdkAttempt?.authenticated();
  }

  void replaceSessionOwner() {
    _authenticatedSessionIdentity = Object();
    chat.sessionManager.cleanUp();
  }

  void authenticatedTransport() {
    if (!isLoginTransportCurrent(callbackSocket) ||
        !connectionSnapshot.authenticated) return;
    _cancelReconnectTimers();
    _serverRetryAt = null;
    _finishAttempt();
    _authRequired = false;
    _preserveRecoverySession = false;
    _completeRecovery(TransportRecoveryResult.authenticated);
  }

  void cancelReconnectTimers() {
    _cancelReconnectTimers();
    _finishAttempt();
  }

  ConnectionAttemptSnapshot getConnectionAttempt() => _getConnectionAttempt();
  Future<bool> advanceReconnect() => _advanceReconnect();
  Future<TransportRecoveryResult> recoverTransport({Duration? deadline}) =>
      _recoverTransport(deadline: deadline);
  bool Function() requireAuthentication() => _requireAuthentication();
  void failTransportAttempt(Object error) => _failAttempt(error);
  void sessionRefreshed() => _sessionRefreshed();
  Future<bool> reconnectAfterSessionRefresh() {
    final task = chat.chatContext.reconnectTask;
    if (task != null && task.exceedRetryCount) {
      chat.chatContext.reconnectTask = ReconnectTask(task.config);
    }
    return runZoned(
      () => reconnect(reset: true), zoneValues: {
        _connectionAttemptZone: null,
        _socketZone: null,
        _sdkAttemptZone: null,
        _sdkReservationZone: null,
      });
  }
  DateTime recordRetryAfter(Duration delay) =>
      _serverRetryAt = now.add(delay);
  void respectRetryAfter(Duration delay, {DateTime? retryAt}) =>
      _respectRetryAfter(delay, retryAt: retryAt);
  bool get isRecoveringTransport => _recovery != null;

  ConnectionManager({required this.chat, this.socketFactory, this.reconnectClock,
      this.wallClock}) {
    webSocketClient = createWebSocketClient();
    _currentState = DisconnectedState(chat: chat);
  }

  WebSocketClient createWebSocketClient() => _createWebSocketClient();

  bool changeState(BaseConnectionState state) {
    if (_currentState == state) {
      return false;
    }

    final previous = _currentState;
    if (previous is DelayedConnectingState) previous.cancelRetryAfterTimer();
    _currentState = state;
    sbLog.i(StackTrace.current, _currentState.runtimeType.toString());
    return true;
  }

  bool isConnected() {
    return _currentState is ConnectedState;
  }

  bool isConnecting() {
    return _currentState is ConnectingState;
  }

  bool isDisconnected() {
    return _currentState is DisconnectedState;
  }

  bool isReconnecting() {
    return _currentState is ReconnectingState;
  }

  BaseConnectionState getCurrentState() {
    return _currentState;
  }

  Future<User> connect(
    String userId, {
    String? nickname,
    String? accessToken,
    String? apiHost,
    String? wsHost,
  }) {
    final joiningLogin = (isConnecting() || isReconnecting()) &&
        matchesSessionCredentials(userId, accessToken: accessToken,
            apiHost: apiHost, wsHost: wsHost) &&
        chat.chatContext.loginCompleter?.isCompleted == false;
    final owner = joiningLogin ? _publicConnectIdentity :
        _publicConnectIdentity = Object();
    return runZoned(() => _connect(userId, nickname: nickname,
        accessToken: accessToken, apiHost: apiHost, wsHost: wsHost),
        zoneValues: {
          _publicConnectZone: owner,
          _connectionAttemptZone: null,
          _socketZone: null,
          _sdkAttemptZone: null,
          _sdkReservationZone: null,
        });
  }

  Future<User> _connect(
    String userId, {
    String? nickname,
    String? accessToken,
    String? apiHost,
    String? wsHost,
  }) async {
    final serverDelay = _serverDelay;
    if (serverDelay > Duration.zero) {
      final state = _currentState;
      if (state is DelayedConnectingState) {
        return state.connect(userId, nickname: nickname, accessToken: accessToken,
            apiHost: apiHost, wsHost: wsHost);
      }
      const retryAfterField = 'retry_after';
      final retryAfter = (serverDelay.inMicroseconds /
          Duration.microsecondsPerSecond).ceil();
      chat.eventManager.notifyConnectionDelayed(retryAfter);
      throw ServerOverloadedException(data: {retryAfterField: retryAfter});
    }
    if (_serverRetryOwner != null) _cancelReconnectTimers();
    final sameCredentials = matchesSessionCredentials(userId,
        accessToken: accessToken, apiHost: apiHost, wsHost: wsHost);
    final replacingCredentials = chat.chatContext.currentUserId != null &&
        !sameCredentials;
    final clearing = _clearingSocket != null &&
        identical(_clearingSocket, _socketIdentity);
    if (clearing || _currentState is DelayedConnectingState ||
        (isConnected() && sameCredentials && !hasAuthenticatedTransport) ||
        _recovery != null || (isDisconnected() && replacingCredentials) ||
        (isReconnecting() && sameCredentials &&
            chat.chatContext.loginCompleter == null)) {
      final login = chat.chatContext.loginCompleter;
      final socket = _socketIdentity;
      if (_reconnectNotificationPending) notifyReconnectFailed();
      if (!_isPublicConnectCurrent || !identical(socket, _socketIdentity)) {
        throw ConnectionCanceledException();
      }
      _cancelAttempt(TransportRecoveryResult.cancelled);
      if (identical(login, chat.chatContext.loginCompleter)) {
        chat.chatContext.loginCompleter = null;
      }
      if (login != null && !login.isCompleted) {
        login.completeError(ConnectionCanceledException());
      }
      _replaceTransport();
      if (replacingCredentials) {
        final clearing = doDisconnect(clear: true);
        final socket = _socketIdentity;
        await clearing;
        if (!identical(socket, _socketIdentity) ||
            !identical(Zone.current[_publicConnectZone], _publicConnectIdentity)) {
          throw ConnectionCanceledException();
        }
      }
      changeState(DisconnectedState(chat: chat));
    }
    _authRequired = false;
    _preserveRecoverySession = false;
    return await _currentState.connect(
      userId,
      nickname: nickname,
      accessToken: accessToken,
      apiHost: apiHost,
      wsHost: wsHost,
    );
  }

  Future<void> disconnect({required bool logout}) async {
    await _currentState.disconnect(logout: logout);
  }

  Future<bool> reconnect({required bool reset}) async {
    return await _currentState.reconnect(reset: reset);
  }

  /// Reconnects after a network interface change (e.g., Wi-Fi ↔ cellular).
  ///
  /// On network change the existing TCP socket is stale, so we:
  ///   1. Immediately fail all in-flight message completers → they register in
  ///      AutoResendManager._pendingMessageMap via the error handler.
  ///   2. Cancel all pending ACK timers (avoids 30-second AckTimeout delay).
  ///   3. Cancel any pending reconnect timers so they don't fire concurrently.
  ///   4. Close the WebSocket (fire-and-forget; _onWebSocketClosed clears state).
  ///   5. Cancel the _reconnectIfNeededTimer that _onWebSocketClosed just set,
  ///      since we drive the reconnect ourselves.
  ///   6. Start doReconnect(reset: true) for a fresh connection with no backoff.
  Future<void> reconnectForNetworkChange() async {
    bool canReconnect() => !chat.isBackground && !_authRequired && _isAttemptCurrent;
    if (!canReconnect() || _recovery != null || _serverDelay > Duration.zero) return;
    if (chat.chatContext.currentUser == null &&
        chat.chatContext.currentUserId == null) return;
    await _runBoundedReconnect(() async {
      sbLog.i(StackTrace.current);

      // 1 & 2. Fail pending messages immediately and cancel ACK timers.
      chat.commandManager.clearCompleterMap();
      chat.commandManager.cancelAckTimers();

      // 3. Cancel any pending reconnect timers.
      reconnectTimer?.cancel();
      reconnectTimer = null;

      // 4. Close the existing WS (triggers _onWebSocketClosed → sets
      //    _reconnectIfNeededTimer, which we cancel in step 5).
      // close() is a no-op when _webSocketChannel is null, so calling it
      // unconditionally also covers the "connecting but not yet connected" case
      // where isConnected() returns false but a socket is in progress.
      await webSocketClient.close(reason: 'Network change - reconnecting');

      // 5. Cancel the timer _onWebSocketClosed just set, so it doesn't
      //    fire a second reconnect attempt in 1 second.
      _reconnectIfNeededTimer?.cancel();
      _reconnectIfNeededTimer = null;

      // 6. Start a fresh reconnect immediately (reset: true resets backoff counter).
      if (!canReconnect()) return;
      await doReconnect(reset: true, foregroundOnly: true);
    });
  }

  Future<void> enterBackground() async {
    _cancelAttempt(TransportRecoveryResult.cancelled);
    return await _currentState.enterBackground();
  }

  Future<void> enterForeground() async {
    return await _currentState.enterForeground();
  }

//------------------------------//
// Implementation
//------------------------------//
  void setLoginInfo({
    required bool fromWebSocket,
    required String userId,
    String? accessToken,
    String? nickname,
    String? apiHost,
    String? wsHost,
  }) {
    chat.chatContext
      ..currentUserId = userId
      ..accessToken = accessToken
      ..nickname = nickname
      ..apiHost = apiHost ?? chat.chatContext.apiHost ?? getDefaultApiHost()
      ..apiHeaders = getDefaultApiHeader();

    if (fromWebSocket) {
      chat.chatContext
        ..wsHost = wsHost ?? chat.chatContext.wsHost ?? _getDefaultWsHost()
        ..loginCompleter = Completer();
    }
  }

  Future<User> doConnect(
    String userId, {
    String? nickname,
    String? accessToken,
    String? apiHost,
    String? wsHost,
    bool isDelayedConnecting = false,
    bool Function()? shouldStart,
  }) async {
    final socket = _socketIdentity;
    if (!_isPublicConnectCurrent || !_isSocketStartCurrent(socket) ||
        shouldStart?.call() == false) throw ConnectionCanceledException();
    sbLog.i(StackTrace.current, 'userId: $userId');

    if (!isDelayedConnecting) {
      chat.connectionManager.changeState(ConnectingState(chat: chat));
    }

    setLoginInfo(
      fromWebSocket: true,
      userId: userId,
      accessToken: accessToken,
      nickname: nickname,
      apiHost: apiHost,
      wsHost: wsHost,
    );
    final login = chat.chatContext.loginCompleter!;
    login.future.then<void>((_) {}, onError: (Object _, StackTrace __) {});

    // ===== Connect =====
    final params = {
      'user_id': userId,
      if (nickname != null && nickname != '') 'nickname': nickname,
      'SB-User-Agent': _sbUserAgentHeader,
      'SB-SDK-USER-AGENT': _sbSdkUserAgentHeader,
      'expiring_session':
          chat.eventManager.getSessionHandler() != null ? '1' : '0',
      'include_extra_data': chat.extraData.join(','),
      'include_poll_details': '1',
    };
    try {
      params.addAll(await _getWebSocketParams(userId: userId));
      if (!_isPublicConnectCurrent ||
          shouldStart?.call() == false || !_isSocketStartCurrent(socket)) {
        throw ConnectionCanceledException();
      }
    } catch (error, stack) {
      if (!login.isCompleted) login.completeError(error, stack);
      if (identical(login, chat.chatContext.loginCompleter)) {
        chat.chatContext.loginCompleter = null;
      }
      rethrow;
    }

    final url =
        '${chat.chatContext.wsHost}/?${Uri(queryParameters: params).query}';

    runZonedGuarded(() {
      sbLog.d(StackTrace.current, 'webSocketClient?.connect()');

      chat.chatContext.connectingUrl = url;
      chat.statManager.startWsConnectStat(hostUrl: url);
      _connectSocket(url, accessToken: accessToken);
    }, (e, s) => _handleConnectError(e, socket, login,
        userId, url, isDelayedConnecting));

    final User user;
    if (isDelayedConnecting) {
      user = await login.future;
    } else {
      user = await _waitForLogin(login, socket, url);
    }

    // After 'LOGI' received
    chat.statManager.endWsConnectStat(
      hostUrl: url,
      success: true,
      connectedTs: webSocketClient.connectedTs,
      logiTs: chat.commandManager.logiTs,
      accumTrial: isDelayedConnecting
          ? chat.chatContext.reconnectTask?.retryCount ?? 1
          : 1,
      isSoftRateLimited: isDelayedConnecting,
    );
    return user;
  }

  Future<void> doDisconnect({
    required bool clear,
    bool logout = false,
    bool fromEnterBackground = false,
    int? timeForDelayedConnectingState,
    int? retryAfterForDelayedConnectingState,
    int? reasonCodeForDelayedConnectingState,
    String? messageForDelayedConnectingState,
  }) async {
    if (clear || logout || fromEnterBackground) {
      _cancelAttempt(TransportRecoveryResult.cancelled);
    }
    if (clear || logout) replaceSessionOwner();
    if (logout) {
      _authRequired = false;
      _serverRetryAt = null;
      _preserveRecoverySession = false;
    }
    socketTracker.invalidateConnection();
    if (logout || clear) {
      _socketIdentity = Object();
      _clearingSocket = _socketIdentity;
    }
    sbLog.i(
      StackTrace.current,
      'clear: $clear, logout: $logout, userId: ${chat.chatContext.currentUserId}',
    );

    if (clear || logout || chat.dbManager.isEnabled() == false) {
      if (chat.chatContext.loginCompleter != null &&
          !chat.chatContext.loginCompleter!.isCompleted) {
        chat.chatContext.loginCompleter
            ?.completeError(ConnectionCanceledException());
      }
    }

    if (isReconnecting()) {
      reconnectTimer?.cancel();
      reconnectTimer = null;
      _sdkReservation = null;
    }

    final disconnectConnect = _publicConnectIdentity;
    final publicConnect = Zone.current[_publicConnectZone];
    final disconnectSocket = _socketIdentity;
    final disconnectAttempt = _sdkAttempt;
    final disconnectReservation = _sdkReservation;
    bool supersededBackgroundClose() {
      if (!identical(disconnectConnect, _publicConnectIdentity)) {
        if (publicConnect != null) throw ConnectionCanceledException();
        return true;
      }
      return !identical(disconnectSocket, _socketIdentity) ||
        (fromEnterBackground && (
            !identical(disconnectAttempt, _sdkAttempt) ||
            !identical(disconnectReservation, _sdkReservation)));
    }

    // Check
    if (!isDisconnected()) {
      await webSocketClient.close();
    }
    if (supersededBackgroundClose()) return;

    final disconnectedUserId = chat.chatContext.currentUserId ?? '';

    if (clear && _reconnectNotificationPending) {
      notifyReconnectFailed();
      if (supersededBackgroundClose()) return;
    }

    if (clear || logout) {
      await chat.collectionManager.resetReadCheckpoints();
      if (supersededBackgroundClose()) return;
      chat.messageQueueMap.forEach((key, q) => q.cleanUp());
      chat.messageQueueMap.clear();
      // chat.uploads.forEach((key, value) => _api.cancelUploadingFile(key));
      chat.uploadTaskMap.clear();

      chat.channelCache.cleanUp();
      chat.sessionManager.cleanUp();
      chat.commandManager.cleanUp();
      chat.apiClient.cleanUp();

      if (logout) {
        await chat.eventDispatcher.onLogout();
        if (supersededBackgroundClose()) return;

        chat.chatContext.cleanUp();
        chat.collectionManager.cleanUpGroupChannelCollections();
        chat.collectionManager.cleanUpMessageCollections();

        //+ [DBManager]
        if (chat.dbManager.isEnabled()) {
          await chat.dbManager.clear();
          if (supersededBackgroundClose()) return;
        }
        //- [DBManager]

        await chat.deviceTokenManager.cleanUp();
        if (supersededBackgroundClose()) return;
        await MessageRetentionManager().clearConfigTs(chat.chatContext.appId);
        if (supersededBackgroundClose()) return;
        AutoResendManager().cleanUp(chat.chatId);
      }
    } else {
      await chat.eventDispatcher.onDisconnected();
    }
    if (supersededBackgroundClose()) return;

    if (fromEnterBackground &&
        !chat.isBackground &&
        !isReconnecting() &&
        timeForDelayedConnectingState == null) {
      sbLog.i(StackTrace.current, 'reconnect()');
      chat.connectionManager.reconnect(reset: true); // Check
    } else {
      if (isReconnecting() && timeForDelayedConnectingState == null) {
        notifyReconnectFailed();
        if (supersededBackgroundClose()) return;
      }

      changeState(DisconnectedState(
        chat: chat,
        timeForDelayedConnectingState: timeForDelayedConnectingState,
        retryAfterForDelayedConnectingState:
            retryAfterForDelayedConnectingState,
        reasonCodeForDelayedConnectingState:
            reasonCodeForDelayedConnectingState,
        messageForDelayedConnectingState: messageForDelayedConnectingState,
      ));

      _clearingSocket = null;
      if (clear && disconnectedUserId.isNotEmpty) {
        chat.eventManager.notifyDisconnected(disconnectedUserId);
        if (supersededBackgroundClose()) return;
      }
    }
  }

  Future<bool> doReconnect({
    bool foregroundOnly = false,
    bool reset = false,
    bool isDelayedConnecting = false,
  }) async {
    if (_authRequired || (foregroundOnly && chat.isBackground)) return false;
    if (_recovery != null) return true;
    if (_serverDelay > Duration.zero) {
      _restoreServerRetry();
      return false;
    }
    if (isReconnecting() && _sdkAttempt?.isActive == true &&
        webSocketClient.isConnected()) return true;
    final socket = _socketIdentity;
    if (!isCallbackCurrent(socket)) return false;
    sbLog.i(StackTrace.current,
        'reset: $reset, isDelayedConnecting: $isDelayedConnecting');

    bool doNotCallReconnectStartedEvent = false;
    if (isReconnecting() && reset) {
      doNotCallReconnectStartedEvent = true;
    }

    if (chat.chatContext.currentUser == null &&
        chat.chatContext.sessionKey == null &&
        chat.chatContext.currentUserId != null) {
      isDelayedConnecting = true;
    } else if (chat.chatContext.currentUser == null ||
        chat.chatContext.sessionKey == null) {
      changeState(DisconnectedState(chat: chat));
      return false;
    }

    var task = chat.chatContext.reconnectTask;
    if (_preserveRecoverySession && task != null && task.exceedRetryCount) {
      task = ReconnectTask(task.config);
      chat.chatContext.reconnectTask = task;
    }
    if (task == null || (task.exceedRetryCount && task.hasRetriedLastChance)) {
      sbLog.w(StackTrace.current, 'exceedRetryCount and hasRetriedLastChance');
      disconnect(logout: task != null && !_preserveRecoverySession);
      return false;
    }

    changeState(ReconnectingState(chat: chat));
    chat.chatContext.reconnectTask?.increaseRetryCount(reset: reset); // Check

    sbLog.i(
      StackTrace.current,
      '[Timer()] ${chat.chatContext.reconnectTask?.backOffPeriod}sec, ${chat.chatContext.reconnectTask?.retryCount}/${chat.chatContext.reconnectTask?.config.maximumRetryCount}',
    );

    reconnectTimer?.cancel();
    final delay = Duration(seconds: chat.chatContext.reconnectTask!.backOffPeriod);
    bool canStart() {
      if (!foregroundOnly || !chat.isBackground) return true;
      _cancelScheduledSdkReconnect(socket);
      return false;
    }
    Future<void> reconnectAction() async {
      if (!canStart()) return;
      if (!_isSocketStartCurrent(socket)) return;
      try {
        sbLog.i(
          StackTrace.current,
          '[Timer() => RUN] ${chat.chatContext.reconnectTask?.backOffPeriod}sec, ${chat.chatContext.reconnectTask?.retryCount}/${chat.chatContext.reconnectTask?.config.maximumRetryCount}',
        );

        if (chat.chatContext.reconnectTask?.retryCount == 1) {
          if (!doNotCallReconnectStartedEvent) {
            await chat.eventDispatcher.onReconnecting();
            if (!canStart() || !_isSocketStartCurrent(socket)) return;
            notifyReconnectStarted();
            if (!canStart() || !_isSocketStartCurrent(socket)) return;
          }
        }

        if (isDelayedConnecting) {
          if (chat.chatContext.currentUserId != null) {
            await doConnect(
              chat.chatContext.currentUserId!,
              nickname: chat.chatContext.nickname,
              accessToken: chat.chatContext.accessToken,
              apiHost: chat.chatContext.apiHost,
              wsHost: chat.chatContext.wsHost,
              isDelayedConnecting: true,
              shouldStart: canStart,
            );
          }
        } else {
          await _reconnect(canStart: canStart);
        }
      } catch (error) {
        if (error is ConnectionCanceledException) return;
        rethrow;
      }
    }
    reconnectTimer = _scheduleSocketReconnect(delay, reconnectAction);
    return true;
  }

  Future<void> _reconnect({required bool Function() canStart}) async {
    final socket = _socketIdentity;
    // ===== Reconnect =====
    final sessionKey = await chat.sessionManager.getSessionKey();
    if (!canStart() || !_isSocketStartCurrent(socket)) return;
    final params = {
      if (sessionKey == null) 'user_id': chat.chatContext.currentUserId,
      'SB-User-Agent': _sbUserAgentHeader,
      'SB-SDK-USER-AGENT': _sbSdkUserAgentHeader,
      'expiring_session':
          chat.eventManager.getSessionHandler() != null ? '1' : '0',
      'include_extra_data': chat.extraData.join(','),
      'include_poll_details': '1',
    };
    params.addAll(await _getWebSocketParams(
        userId: chat.chatContext.currentUser?.userId ?? ''));
    if (!canStart() || !_isSocketStartCurrent(socket)) return;

    final url =
        '${chat.chatContext.wsHost}/?${Uri(queryParameters: params).query}';

    runZonedGuarded(() {
      sbLog.d(StackTrace.current, 'webSocketClient?.connect()');

      chat.statManager.startWsConnectStat(hostUrl: url);
      if (chat.chatContext.reconnectTask != null) {
        chat.chatContext.reconnectTask?.url = url;
      }

      _connectSocket(url,
        accessToken: chat.chatContext.accessToken,
        sessionKey: sessionKey,
        reconnect: true,
      );

      reconnectTimer?.cancel();
      reconnectTimer = null;
    }, (e, s) {
      if (!isCallbackCurrent(socket) || !_isAttemptCurrent) return;
      sbLog.e(StackTrace.current, 'e: $e');
      _failAttempt(e);

      if (e is SendbirdException) {
        chat.statManager.endWsConnectStat(
          hostUrl: url,
          success: false,
          errorCode: e.code,
          errorDescription: e.message,
          accumTrial: chat.chatContext.reconnectTask?.retryCount ?? 1,
          connectionId: chat.chatContext.reconnectTask?.id ?? const Uuid().v4(),
        );
      } else {
        final exception = WebSocketFailedException(message: e.toString());

        chat.statManager.endWsConnectStat(
          hostUrl: url,
          success: false,
          errorCode: exception.code,
          errorDescription: exception.message,
          accumTrial: chat.chatContext.reconnectTask?.retryCount ?? 1,
          connectionId: chat.chatContext.reconnectTask?.id ?? const Uuid().v4(),
        );
      }
    });
  }

//------------------------------//
// Values
//------------------------------//
  String getDefaultApiHost() {
    final appId = chat.chatContext.appId;
    return 'api-$appId.sendbird.com';
  }

  String _getDefaultWsHost() {
    final appId = chat.chatContext.appId;
    return 'wss://ws-$appId.sendbird.com';
  }

  Map<String, String> getDefaultApiHeader() {
    return <String, String>{
      'SB-User-Agent': _sbUserAgentHeader,
      'SB-SDK-USER-AGENT': _sbSdkUserAgentHeader,
      'SendBird': _sendbirdHeader,
      'Connection': 'keep-alive',
    };
  }

  String get _sbUserAgentHeader {
    const core = '/c$sdkVersion';

    final uikitVersion = chat.extensions[Chat.extensionKeyUiKit];
    final uikit = uikitVersion != null ? '/u$uikitVersion' : '';

    final os = '/o${kIsWeb ? 'web' : Platform.operatingSystem}';

    return '${Chat.platform}$core$uikit$os';
  }

  String get _sbSdkUserAgentHeader {
    const mainSdkInfo = 'chat/${Chat.platform}/$sdkVersion';
    final deviceOsPlatform = kIsWeb ? 'web' : Platform.operatingSystem;
    final osVersion = _sanitizedOsVersion;
    // '2.19.0 (stable) (Mon Jan 23 11:29:09 2023 -0800) on "android_arm64"'
    final platformVersion = kIsWeb ? '' : Platform.version.split(' ').first;

    final uikitVersion = chat.extensions[Chat.extensionKeyUiKit];
    final uikitInfo = 'uikit-chat/$deviceOsPlatform/${uikitVersion ?? ''}';

    return 'main_sdk_info=$mainSdkInfo'
        '&device_os_platform=$deviceOsPlatform'
        '&os_version=$osVersion'
        '&platform_version=$platformVersion'
        '&extension_sdk_info=$uikitInfo';
  }

  String get _sendbirdHeader {
    var headers = [
      Chat.platform,
      kIsWeb ? '' : Platform.version.split(' ').first, // empty platform version
      sdkVersion,
      chat.chatContext.appId,
      chat.chatContext.appVersion ?? '',
      kIsWeb ? 'web' : Platform.operatingSystem,
      _sanitizedOsVersion,
    ];
    return headers.join(',');
  }

  String get _sanitizedOsVersion {
    if (kIsWeb) return '';
    final version = Platform.operatingSystemVersion;
    // macOS/Windows returns localized version string on non-English systems
    // e.g. Korean macOS: "버전 26.0(빌드 25A354)" → invalid HTTP header value
    if (Platform.isMacOS || Platform.isWindows) {
      return version.replaceAll(RegExp(r'[^\x00-\x7F]'), '').trim();
    }
    return version;
  }

  Future<Map<String, String>> _getWebSocketParams({
    required String userId,
  }) async {
    final appId = chat.chatContext.appId;
    final appVersion = chat.chatContext.appVersion;

    int configTs = await MessageRetentionManager().getConfigTs(appId) ?? 0;
    String? uikitVersion = chat.extensions[Chat.extensionKeyUiKit];

    return {
      'p': Chat.platform,
      if (!kIsWeb) 'pv': Platform.version.split(' ').first,
      'o': kIsWeb ? 'web' : Platform.operatingSystem,
      if (!kIsWeb) 'ov': Platform.operatingSystemVersion,
      'sv': sdkVersion,
      'ai': appId,
      if (appVersion != null && appVersion != '') 'av': appVersion,
      'config_ts': configTs.toString(), // To get config_sync_needed
      if (uikitVersion != null) 'uikit_config': '1',
    };
  }
}
