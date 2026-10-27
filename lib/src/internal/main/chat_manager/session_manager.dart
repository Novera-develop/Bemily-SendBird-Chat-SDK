// Copyright (c) 2023 Sendbird, Inc. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:encrypt/encrypt.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';
import 'package:sendbird_chat_sdk/src/internal/main/utils/string_utils.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/main/app_session_key_update_request.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/exceptions.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/sendbird_error.dart';
import 'package:sendbird_chat_sdk/src/public/main/handler/session_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AccessTokenRequesterImpl extends AccessTokenRequester {
  final SessionManager _sessionManager;
  final _SessionRefresh? _refresh;
  bool _used = false;

  _AccessTokenRequesterImpl({required SessionManager sessionManager,
      _SessionRefresh? refresh})
      : _sessionManager = sessionManager, _refresh = refresh;

  @override
  Future<void> onSuccess(String? newAccessToken) async {
    if (_refresh != null && _used) return;
    _used = true;
    await _sessionManager._requestSessionKey(newAccessToken, refresh: _refresh);
  }

  @override
  Future<void> onFail() async {
    if (_refresh != null && _used) return;
    _used = true;
    await _sessionManager._failedToRetrieveNewAccessToken(refresh: _refresh);
  }
}

class _SessionRefresh {
  _SessionRefresh(this.ownsSession);
  final bool Function() ownsSession;
  bool updating = false;
  final completers = <Completer<void>>[];
}

class SessionManager {
  late String _userIdKeyPath;
  late String _sessionKeyPath;

  static const _keyField = 'key';
  static const _newKeyField = 'new_key';
  _SessionRefresh? _refresh;
  Object _keyWriteIdentity = Object();

  final Chat _chat;
  late AccessTokenRequester accessTokenRequester;

  SessionManager({required Chat chat}) : _chat = chat {
    // Use appId to support multi-instance
    final appId = chat.chatContext.appId;
    _userIdKeyPath = 'com.sendbird.chat.user_id_$appId';
    _sessionKeyPath = 'com.sendbird.chat.session_key_$appId';
    accessTokenRequester = _AccessTokenRequesterImpl(sessionManager: this);
  }

  // Set a `sessionKey` that will be used for SDK globally
  // This method will also encrypt this key and store in prefs
  Future<void> setSessionKey(String? sessionKey) async {
    sbLog.d(StackTrace.current);

    final write = _keyWriteIdentity = Object();
    _chat.chatContext.sessionKey = sessionKey;
    await _encryptSessionKey(sessionKey, write);
  }

  Future<String?> getSessionKey() async {
    sbLog.d(StackTrace.current);

    if (_chat.chatContext.sessionKey != null) {
      return _chat.chatContext.sessionKey;
    }

    final socket = _chat.connectionManager.socketIdentity;
    final login = _chat.chatContext.loginCompleter;
    final userId = _chat.chatContext.currentUserId;
    final decryptedSessionKey = await _decryptSessionKey();
    if (!identical(socket, _chat.connectionManager.socketIdentity) ||
        !identical(login, _chat.chatContext.loginCompleter) ||
        userId != _chat.chatContext.currentUserId) return null;
    _chat.chatContext.sessionKey ??= decryptedSessionKey;
    return decryptedSessionKey;
  }

  // Set a `path` to store session key.
  // Recommend to set your own path to store this path for security purpose
  void setSessionKeyPath(String path) {
    sbLog.d(StackTrace.current, 'path: $path');
    _sessionKeyPath = path;
  }

  // Set a `path` to store user id key.
  // Recommend to set your own path to store this path for security purpose
  void setUserIdKeyPath(String path) {
    sbLog.d(StackTrace.current, 'path: $path');
    _userIdKeyPath = path;
  }

  bool Function() _captureSession() {
    final connection = _chat.connectionManager;
    final context = _chat.chatContext;
    final session = connection.authenticatedSessionIdentity;
    final userId = context.currentUserId;
    final token = context.accessToken;
    final apiHost = context.apiHost;
    final wsHost = context.wsHost;
    return () => identical(session, connection.authenticatedSessionIdentity) &&
        userId == context.currentUserId && token == context.accessToken &&
        apiHost == context.apiHost && wsHost == context.wsHost;
  }

  bool _isCurrent(_SessionRefresh refresh) =>
      identical(refresh, _refresh) && refresh.ownsSession();

  _SessionRefresh _beginRefresh() {
    final previous = _refresh;
    if (previous != null && _isCurrent(previous)) return previous;
    if (previous != null) _discardRefresh(previous);
    return _refresh = _SessionRefresh(_captureSession());
  }

  AccessTokenRequester createAccessTokenRequester() =>
      _AccessTokenRequesterImpl(sessionManager: this, refresh: _beginRefresh());

  void _discardRefresh(_SessionRefresh refresh) {
    _flushUpdateSessionCompleterList(refresh, e: ConnectionCanceledException());
    if (identical(refresh, _refresh)) _refresh = null;
  }

  Future<void> updateSessionKey() {
    sbLog.d(StackTrace.current);
    final requiresCredentials =
        _chat.connectionManager.getConnectionAttempt().authRequired;
    final current = _refresh;
    if (requiresCredentials && (current == null || !_isCurrent(current))) {
      return Future.error(SessionKeyRefreshFailedException());
    }
    final refresh = _beginRefresh();
    final completer = Completer<void>();
    refresh.completers.add(completer);
    if (!refresh.updating && !requiresCredentials) {
      refresh.updating = true;
      setSessionKey(null);
      _updateSessionKey(refresh);
    }
    return completer.future;
  }

  Future<void> _updateSessionKey(_SessionRefresh refresh) async {
    try {
      final res = await _chat.apiClient.send(
        AppSessionKeyUpdateRequest(
          _chat,
          appId: _chat.chatContext.appId,
          accessToken: _chat.chatContext.accessToken,
        ),
      );
      if (!_isCurrent(refresh)) {
        _discardRefresh(refresh);
        return;
      }
      await _applyRefreshedSessionKey(res, refresh);
    } catch (error) {
      if (!_isCurrent(refresh)) {
        _discardRefresh(refresh);
        return;
      }
      sbLog.e(StackTrace.current, 'e: $error');
      if (error is SendbirdException && error.code == SendbirdError.accessTokenNotValid) {
        _refresh = null;
        final ownsTransition = _chat.connectionManager.requireAuthentication();
        if (!ownsTransition()) {
          _discardRefresh(refresh);
          return;
        }
        final replacement = _SessionRefresh(_captureSession());
        replacement.completers.addAll(refresh.completers);
        refresh.completers.clear();
        _refresh = replacement;
        _chat.eventManager.notifyAccessTokenRequired();
      } else {
        _flushUpdateSessionCompleterList(refresh, e: SessionKeyRefreshFailedException());
        _refresh = null;
        final ownsTransition = _chat.connectionManager.requireAuthentication();
        if (!ownsTransition()) return;
        _chat.eventManager.notifySessionError(SessionKeyRefreshFailedException());
      }
    }
  }

  void cleanUp() {
    final refresh = _refresh;
    if (refresh != null) _discardRefresh(refresh);
  }

  Future<void> _encryptSessionKey(String? sessionKey, Object write) async {
    final userId = _chat.chatContext.currentUserId;
    if (userId == null) {
      return; // Check tempSessionKey in markAsDelivered()
    }

    final prefs = await SharedPreferences.getInstance();
    if (userId != _chat.chatContext.currentUserId ||
        sessionKey != _chat.chatContext.sessionKey ||
        !identical(write, _keyWriteIdentity)) return;

    if (sessionKey == null) {
      prefs.remove(_userIdKeyPath);
      prefs.remove(_sessionKeyPath);
      return;
    }

    List<int> userId24Data = [];
    final userIdData = utf8.encode(userId);
    const dataLength = 24;
    if (userIdData.length >= dataLength) {
      userId24Data.addAll(userIdData.sublist(0, dataLength));
    } else {
      final randomStringData =
          utf8.encode(getRandomString(dataLength - userIdData.length));
      userId24Data
        ..addAll(userIdData)
        ..addAll(randomStringData);
    }

    String base64UserId = base64.encode(userId24Data);
    if (base64UserId.length > 16) {
      base64UserId = base64UserId.substring(0, 16);
    }
    prefs.setString(_userIdKeyPath, base64UserId);

    final key = Key.fromUtf8(base64UserId);
    final iv = IV.fromUtf8(base64UserId);
    final encrypter = Encrypter(AES(key));
    final encryptedData = encrypter.encrypt(sessionKey, iv: iv);
    prefs.setString(_sessionKeyPath, encryptedData.base64);
  }

  Future<String?> _decryptSessionKey() async {
    final prefs = await SharedPreferences.getInstance();
    final encryptedUserId = prefs.getString(_userIdKeyPath);

    if (encryptedUserId == null) {
      return null;
    }

    final key = Key.fromUtf8(encryptedUserId);
    final iv = IV.fromUtf8(encryptedUserId);
    final encrypter = Encrypter(AES(key));
    final encryptedSessionKey = prefs.getString(_sessionKeyPath);

    if (encryptedSessionKey == null) {
      return null;
    }

    return encrypter.decrypt(Encrypted.fromBase64(encryptedSessionKey), iv: iv);
  }

  // Applies refreshed session payload and reconnect if necessary
  Future<void> _applyRefreshedSessionKey(Map<String, dynamic> payload,
      _SessionRefresh refresh) async {
    if (!_isCurrent(refresh)) {
      _discardRefresh(refresh);
      return;
    }
    if (payload[_keyField] != null) {
      await setSessionKey(payload[_keyField]);
    } else if (payload[_newKeyField] != null) {
      await setSessionKey(payload[_newKeyField]);
    }
    if (!_isCurrent(refresh)) {
      _discardRefresh(refresh);
      return;
    }

    _flushUpdateSessionCompleterList(refresh);
    _chat.connectionManager.sessionRefreshed();
    _chat.eventManager.notifySessionRefreshed();
    if (!_isCurrent(refresh)) {
      _discardRefresh(refresh);
      return;
    }
    _refresh = null;
    if (_chat.chatContext.isChatConnected) {
      await _chat.connectionManager.reconnectAfterSessionRefresh();
    }
  }

  void _flushUpdateSessionCompleterList(_SessionRefresh refresh, {SendbirdException? e}) {
    for (final element in refresh.completers) {
      if (e != null) {
        element.completeError(e);
      } else {
        element.complete();
      }
    }
    refresh.completers.clear();
  }

  Future<void> _requestSessionKey(String? newAccessToken, {_SessionRefresh? refresh}) async {
    final previous = refresh ?? _beginRefresh();
    if (!_isCurrent(previous)) {
      _discardRefresh(previous);
      return;
    }
    _chat.chatContext.accessToken = newAccessToken;
    final operation = _SessionRefresh(_captureSession());
    operation.completers.addAll(previous.completers);
    previous.completers.clear();
    _refresh = operation;

    if (newAccessToken == null) {
      _flushUpdateSessionCompleterList(operation, e: SessionKeyRefreshFailedException());
      _refresh = null;
      final ownsTransition = _chat.connectionManager.requireAuthentication();
      if (!ownsTransition()) return;
      _chat.eventManager.notifySessionClosed();
      return;
    }

    operation.updating = true;
    try {
      final res = await _chat.apiClient.send(
        AppSessionKeyUpdateRequest(
          _chat,
          appId: _chat.chatContext.appId,
          accessToken: newAccessToken,
        ),
      );
      await _applyRefreshedSessionKey(res, operation);
    } catch (e) {
      if (!_isCurrent(operation)) {
        _discardRefresh(operation);
        return;
      }
      sbLog.e(StackTrace.current, 'e: $e');
      _flushUpdateSessionCompleterList(operation, e: SessionKeyRefreshFailedException());
      _refresh = null;
      final ownsTransition = _chat.connectionManager.requireAuthentication();
      if (!ownsTransition()) return;
      _chat.eventManager.notifySessionError(InvalidAccessTokenException());
    }
  }

  Future<void> _failedToRetrieveNewAccessToken({_SessionRefresh? refresh}) async {
    final operation = refresh ?? _beginRefresh();
    if (!_isCurrent(operation)) {
      _discardRefresh(operation);
      return;
    }
    _flushUpdateSessionCompleterList(operation, e: SessionKeyRefreshFailedException());
    _refresh = null;
    final ownsTransition = _chat.connectionManager.requireAuthentication();
    if (!ownsTransition()) return;
    _chat.eventManager.notifySessionError(InvalidAccessTokenException());
  }
}
