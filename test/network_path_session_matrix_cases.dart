part of 'network_path_reconnect_test.dart';

const _nf5PrefsKey = 'com.sendbird.chat.session_key_$_appId';
const _nf5PrefsUser = 'com.sendbird.chat.user_id_$_appId';

class _Nf5Collections extends CollectionManager {
  _Nf5Collections(Chat chat) : super(chat: chat);
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<void> resetReadCheckpoints({bool dispose = false}) async {
    if (entered) return;
    entered = true;
    await gate.future;
  }
}

class _Nf5Harness {
  final _Fixture fixture;
  late final SessionManager sessions;
  final api = _Nf2SessionApi();
  final handler = _Nf2SessionHandler();
  final connectionHandler = _Nf5ConnectionHandler();
  _Nf5Harness(WidgetTester tester)
      : fixture = _Fixture(wallClock: tester.binding.clock.now) {
    connectionHandler.currentUser = () => fixture.chat.chatContext.currentUserId;
    addTearDown(fixture.dispose);
    fixture.chat.chatContext.apiHost = _nextApiHost;
    sessions = SessionManager(chat: fixture.chat);
    fixture.chat.sessionManager = sessions;
    fixture.chat.apiClient = api;
    fixture.chat.eventManager = EventManager(sessionManager: sessions)
      ..setSessionHandler(handler)
      ..addConnectionHandler(_appId, connectionHandler);
  }
  Future<void> login(WidgetTester tester) async {
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    await fixture.sockets.last.data('$_loginCommand${jsonEncode({
      ..._loginPayload, _sessionKeyField: _nextSessionKey,
    })}');
    await _flush(tester);
    expect(fixture.connection.connectionSnapshot.authenticated, isTrue);
  }
  Future<void> packet(String command, Map<String, dynamic> payload) =>
      fixture.sockets.last.data('$command${jsonEncode(payload)}');
}

void _registerNf5Tests() {
  _registerU5Tests();
  _registerU5gTests();
  _registerNf5Matrix();
  _registerNf5ClearStages();
  _registerNf5CancellationContracts();
  for (final success in _hookModes) {
    testWidgets('NF5-A1 EXPR then correlated LOGI lateSuccess=$success', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      final before = h.fixture.connection.connectionSnapshot.key;
      await h.packet(_nf4SessionCommand, {});
      await _flush(tester);
      expect(h.api.requests, _one);
      await h.packet(_loginCommand, {
        _requestIdField: _ackRequestId, _sessionKeyField: _nextSessionKey,
      });
      await _flush(tester);
      if (success) {
        h.api.response.complete({_sessionKeyField: _nf2StaleKey});
      } else {
        h.api.response.completeError(NetworkErrorException());
      }
      await _flush(tester);
      expect(h.fixture.connection.connectionSnapshot.authenticated, isTrue);
      expect(h.fixture.connection.connectionSnapshot.key, same(before));
      expect(h.fixture.events.where((e) => e.kind == SocketEventKind.authenticationFailed), isEmpty);
      expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
      expect(h.handler.events, [_nf2SessionRefreshed]);
    });
  }

  testWidgets('NF5-A2 nested connect B then A during checkpoint clear', (tester) async {
    final h = _Nf5Harness(tester);
    await h.login(tester);
    final recovery = h.fixture.connection.recoverTransport();
    await _flush(tester);
    await h.packet(_loginCommand, {
      _errorField: true, _codeField: SendbirdError.accessTokenRevoked,
    });
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.authRequired);
    final collections = _Nf5Collections(h.fixture.chat);
    h.fixture.chat.collectionManager = collections;
    Object? oldFailure;
    final older = h.fixture.connection.connect(_nf3OtherUser, accessToken: _nextAccessToken)
        .then<void>((_) {}, onError: (Object e) { oldFailure = e; });
    await _flush(tester);
    expect(collections.entered, isTrue);
    final latest = h.fixture.connection.connect(_userId);
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect((await latest).userId, _userId);
    final queue = AsyncQueue();
    final upload = AsyncSimpleTask(() async {});
    final channel = OpenChannel(channelUrl: _retainedChannel,
        participantCount: _none, operators: [])..set(h.fixture.chat);
    h.fixture.chat.setMessageQueue(_retainedChannel, queue);
    h.fixture.chat.uploadTaskMap[_ackRequestId] = upload;
    h.fixture.chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
    final starts = h.fixture.starts;
    collections.gate.complete();
    await _flush(tester);
    expect(h.fixture.chat.messageQueueMap[_retainedChannel], same(queue));
    expect(h.fixture.chat.uploadTaskMap[_ackRequestId], same(upload));
    expect(h.fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), same(channel));
    expect(h.fixture.starts, starts);
    expect(oldFailure, isA<ConnectionCanceledException>());
    await older;
    expect(h.fixture.connection.connectionSnapshot.authenticated, isTrue);
  });

  for (final correlated in _hookModes) {
    for (final success in _hookModes) {
      testWidgets('NF5-A3 LOGI rejected correlated=$correlated tokenSuccess=$success', (tester) async {
        final h = _Nf5Harness(tester);
        await h.login(tester);
        await h.packet(_loginCommand, {
          if (correlated) _requestIdField: _ackRequestId,
          _errorField: true, _codeField: SendbirdError.accessTokenNotValid,
        });
        await _flush(tester);
        expect(h.handler.events, [_nf2SessionRequired]);
        expect(h.api.requests, _none);
        expect(h.fixture.connection.getConnectionAttempt().authRequired, isTrue);
        final requester = h.handler.requester!;
        if (success) {
          final pending = requester.onSuccess(_nextAccessToken);
          await _flush(tester);
          expect(h.api.requests, _one);
          h.api.response.complete({_sessionKeyField: _nextSessionKey});
          await _flush(tester);
          await pending;
          expect(h.handler.events, [_nf2SessionRequired, _nf2SessionRefreshed]);
          await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect(h.fixture.connection.connectionSnapshot.authenticated, isTrue);
        } else {
          await requester.onFail();
          expect(h.handler.events, [_nf2SessionRequired, _nf2SessionError]);
        }
        await requester.onFail();
        expect(h.handler.events.length, _two);
      });
    }
  }

  for (final replaceKey in _hookModes) {
    testWidgets('NF5-A4 revoke persisted key replaceKey=$replaceKey', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      await h.sessions.setSessionKey(_userId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_nf5PrefsKey), isNotNull);
      await h.packet(_nf4SessionCommand, {_nf4ReasonField: SendbirdError.accessTokenRevoked});
      if (replaceKey) await h.sessions.setSessionKey(_nextSessionKey);
      await _flush(tester);
      if (replaceKey) {
        h.fixture.chat.chatContext.sessionKey = null;
        expect(await h.sessions.getSessionKey(), _nextSessionKey);
      } else {
        expect(prefs.getString(_nf5PrefsKey), isNull);
        expect(prefs.getString(_nf5PrefsUser), isNull);
        expect(await h.sessions.getSessionKey(), isNull);
      }
      expect(h.handler.events, [_nf2SessionClosed]);
      expect(h.fixture.connection.getConnectionAttempt().authRequired, isTrue);
    });
  }
}

enum _Nf5Row { http, requester, logi, expr, close, clear, retryAfter, backoff }
enum _Nf5Event {
  sameConnect, differentConnect, recover, close, error, expire, revoke,
  login, correlatedLogin, reject, lifecycle, lateSuccess, lateFailure,
}

const _nf5NoSocketEvents = {
  _Nf5Event.close, _Nf5Event.error, _Nf5Event.expire, _Nf5Event.revoke,
  _Nf5Event.login, _Nf5Event.correlatedLogin, _Nf5Event.reject,
};
const _nf5WaitingRows = {
  _Nf5Row.close, _Nf5Row.clear, _Nf5Row.backoff,
};

void _registerNf5Matrix() {
  for (final row in _Nf5Row.values) {
    for (final event in _Nf5Event.values) {
      if (_nf5WaitingRows.contains(row) && _nf5NoSocketEvents.contains(event)) continue;
      for (final completed in _hookModes) {
      if (!completed && (row == _Nf5Row.retryAfter || row == _Nf5Row.backoff)) continue;
      final label = completed ? 'NF5-M' : 'NF7-M pending';
      testWidgets('$label ${row.name}/${event.name}', (tester) async {
        final h = _Nf5Harness(tester);
        if (completed) await _nf7CompletePublicLogin(h, tester);
        final connection = h.fixture.connection;
        final context = h.fixture.chat.chatContext;
        final expectedEvents = <String>[];
        final oldRequests = <Future<void>>[];
        final failures = <Object>[];
        final publicResults = <User>[];
        final publicFailures = <Object>[];
        final publicWaiters = <Future<void>>[];
        final returnedAuthenticated = <bool>[];
        final returnedOpen = <bool>[];
        final recoveries = <Future<TransportRecoveryResult>>[];
        final recoveryResults = <TransportRecoveryResult>[];
        final initialResults = <User>[];
        final initialFailures = <Object>[];
        Future<void>? initialConnect;
        if (!completed) {
          initialConnect = connection.connect(_userId).then<void>((user) {
            initialResults.add(user);
            returnedAuthenticated.add(connection.connectionSnapshot.authenticated);
            returnedOpen.add(connection.webSocketClient.isConnected());
          }, onError: (Object e) { initialFailures.add(e); });
          await _flush(tester);
        }
        void recover() {
          final pending = connection.recoverTransport();
          recoveries.add(pending);
          pending.then((result) {
            recoveryResults.add(result);
            if (result == TransportRecoveryResult.authenticated) {
              returnedAuthenticated.add(connection.connectionSnapshot.authenticated);
              returnedOpen.add(connection.webSocketClient.isConnected());
            }
          });
        }
        final queue = AsyncQueue();
        final upload = AsyncSimpleTask(() async {});
        final channel = OpenChannel(channelUrl: _retainedChannel,
            participantCount: _none, operators: [])..set(h.fixture.chat);
        h.fixture.chat.setMessageQueue(_retainedChannel, queue);
        h.fixture.chat.uploadTaskMap[_ackRequestId] = upload;
        h.fixture.chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
        if (row == _Nf5Row.expr) {
          await h.packet(_nf4SessionCommand, {});
        } else if (row != _Nf5Row.backoff && row != _Nf5Row.retryAfter) {
          oldRequests.add(h.sessions.updateSessionKey().then<void>((_) {},
              onError: (Object e) { failures.add(e); }));
        }
        await _flush(tester);
        expect(h.api.requests,
            row == _Nf5Row.backoff || row == _Nf5Row.retryAfter ? _none : _one);
        final httpOwner = connection.authenticatedSessionIdentity;
        AccessTokenRequester? requester;
        if (row == _Nf5Row.requester) {
          h.fixture.chat.eventManager.notifyAccessTokenRequired();
          requester = h.handler.requester;
          expectedEvents.add(_nf2SessionRequired);
        }
        if (row == _Nf5Row.logi) {
          final command = Command(cmd: _loginCommand, requestId: _ackRequestId,
              payload: {_requestIdField: _ackRequestId});
          await h.fixture.chat.commandManager.sendCommand(command);
          expect(h.fixture.sockets.last.writes, [command.encode()]);
        }
        Completer<bool>? closeGate;
        _Nf5Collections? collections;
        Future<void>? clearing;
        if (row == _Nf5Row.close) {
          closeGate = Completer<bool>();
          h.fixture.sockets.last.closeBarrier = closeGate;
          recover();
          await _flush(tester);
          expect(connection.getConnectionAttempt().phase, ConnectionAttemptPhase.preparing);
        } else if (row == _Nf5Row.clear) {
          collections = _Nf5Collections(h.fixture.chat);
          h.fixture.chat.collectionManager = collections;
          clearing = connection.doDisconnect(clear: true);
          await _flush(tester);
          expect(collections.entered, isTrue);
        } else if (row == _Nf5Row.retryAfter) {
          h.fixture.sockets.last.closed();
          await tester.pump(_legacyReconnectDelay);
          await _flush(tester);
          await h.packet(_busyCommand, {_retryAfterField: _busySeconds});
          expect(connection.getCurrentState(), isA<DelayedConnectingState>());
          expect(connection.webSocketClient.isConnected(), isTrue);
          oldRequests.add(h.sessions.updateSessionKey().then<void>((_) {},
              onError: (Object e) { failures.add(e); }));
          await _flush(tester);
          expect(h.api.requests, _one);
        } else if (row == _Nf5Row.backoff) {
          h.fixture.sockets.last.closed();
          await tester.pump(_legacyReconnectDelay);
          await _flush(tester);
          h.fixture.sockets.last.closed();
          await tester.pump(_legacyReconnectDelay);
          await tester.pump(_statSettlingTick);
          await _flush(tester);
          expect(connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
          expect(connection.reconnectTimer?.isActive, isTrue);
          oldRequests.add(h.sessions.updateSessionKey().then<void>((_) {},
              onError: (Object e) { failures.add(e); }));
          await _flush(tester);
          expect(h.api.requests, _one);
        }
        final beforeEventOwner = connection.authenticatedSessionIdentity;
        final initialStarts = h.fixture.starts;
        switch (event) {
          case _Nf5Event.sameConnect:
          case _Nf5Event.differentConnect:
            final user = event == _Nf5Event.sameConnect ? _userId : _nf3OtherUser;
            publicWaiters.add(connection.connect(user).then<void>((result) {
              publicResults.add(result);
              returnedAuthenticated.add(connection.connectionSnapshot.authenticated);
              returnedOpen.add(connection.webSocketClient.isConnected());
            }, onError: (Object e) { publicFailures.add(e); }));
            break;
          case _Nf5Event.recover:
            recover();
            break;
          case _Nf5Event.close:
            h.fixture.sockets.last.closed();
            await tester.pump(_legacyReconnectDelay);
            break;
          case _Nf5Event.error:
            h.fixture.sockets.last.error(WebSocketFailedException());
            break;
          case _Nf5Event.expire:
            await h.packet(_nf4SessionCommand, {});
            break;
          case _Nf5Event.revoke:
            await h.packet(_nf4SessionCommand, {_nf4ReasonField: SendbirdError.accessTokenRevoked});
            expectedEvents.add(_nf2SessionClosed);
            break;
          case _Nf5Event.login:
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            break;
          case _Nf5Event.correlatedLogin:
            await h.packet(_loginCommand, {
              _requestIdField: _ackRequestId, _sessionKeyField: _nextSessionKey,
            });
            expectedEvents.add(_nf2SessionRefreshed);
            break;
          case _Nf5Event.reject:
            await h.packet(_loginCommand, {
              _requestIdField: _ackRequestId, _errorField: true,
              _codeField: SendbirdError.accessTokenNotValid,
            });
            expectedEvents.add(_nf2SessionRequired);
            break;
          case _Nf5Event.lifecycle:
            final paused = h.fixture.chat.didChangeAppLifecycleState(AppLifecycleState.paused);
            await _flush(tester);
            h.fixture.chat.isBackground = false;
            await h.fixture.chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
            if (closeGate == null) await paused;
            break;
          case _Nf5Event.lateSuccess:
          case _Nf5Event.lateFailure:
            break;
        }
        await _flush(tester);
        if (event == _Nf5Event.recover || event == _Nf5Event.close ||
            event == _Nf5Event.error || event == _Nf5Event.lifecycle ||
            event == _Nf5Event.sameConnect || event == _Nf5Event.expire ||
            event == _Nf5Event.lateSuccess || event == _Nf5Event.lateFailure) {
          expect(connection.authenticatedSessionIdentity, same(beforeEventOwner));
        }
        if (closeGate != null) {
          closeGate.complete(true);
          h.fixture.sockets.first.closeBarrier = null;
        }
        if (collections != null) collections.gate.complete();
        await _flush(tester);
        if (clearing != null) await clearing;
        final ownerChanged = !identical(httpOwner, connection.authenticatedSessionIdentity);
        final mustInvalidate = row == _Nf5Row.clear ||
            event == _Nf5Event.differentConnect && row != _Nf5Row.retryAfter ||
            event == _Nf5Event.login || event == _Nf5Event.correlatedLogin ||
            event == _Nf5Event.revoke || event == _Nf5Event.reject;
        expect(ownerChanged, mustInvalidate);
        final snapshot = connection.connectionSnapshot;
        final startsBeforeHttp = h.fixture.starts;
        final keyBeforeHttp = context.sessionKey;
        final authBeforeHttp = connection.getConnectionAttempt().authRequired;
        if (event == _Nf5Event.lateFailure) {
          h.api.response.completeError(NetworkErrorException());
        } else {
          h.api.response.complete({_sessionKeyField: _nf2StaleKey});
          if (!ownerChanged) expectedEvents.add(_nf2SessionRefreshed);
        }
        await _flush(tester);
        await Future.wait(oldRequests);
        expect(h.handler.events, expectedEvents);
        if (ownerChanged) {
          expect(context.sessionKey, keyBeforeHttp);
          expect(connection.getConnectionAttempt().authRequired, authBeforeHttp);
          expect(connection.connectionSnapshot.key, same(snapshot.key));
          expect(connection.connectionSnapshot.authenticated, snapshot.authenticated);
          expect(h.fixture.starts, startsBeforeHttp);
          if (row != _Nf5Row.expr) expect(failures, [isA<ConnectionCanceledException>()]);
          if (requester != null) {
            await requester.onSuccess(_nextAccessToken);
            await requester.onFail();
            expect(h.api.requests, _one);
            expect(h.handler.events, expectedEvents);
          }
        } else if (event == _Nf5Event.lateFailure) {
          expect(connection.getConnectionAttempt().authRequired, isFalse);
          expect(connection.getConnectionAttempt().retryAt,
              row == _Nf5Row.backoff ? isNull : isNotNull);
          if (row == _Nf5Row.backoff) {
            expect(context.currentUserId, _userId);
            expect(context.currentUser, isNotNull);
            expect(connection.isDisconnected(), isTrue);
            expect(h.connectionHandler.events.where((event) =>
                event == _nf5ReconnectFailed).length, _one);
          }
          if (row != _Nf5Row.expr) expect(failures, [isA<SessionKeyRefreshFailedException>()]);
        } else {
          expect(context.sessionKey, _nf2StaleKey);
          expect(connection.getConnectionAttempt().authRequired, isFalse);
          expect(failures, isEmpty);
        }
        final clearSuperseded = row == _Nf5Row.clear &&
            (event == _Nf5Event.sameConnect || event == _Nf5Event.recover);
        final cleared = row == _Nf5Row.clear && !clearSuperseded ||
            event == _Nf5Event.differentConnect && row != _Nf5Row.retryAfter;
        expect(h.fixture.chat.messageQueueMap[_retainedChannel], cleared ? isNull : same(queue));
        expect(h.fixture.chat.uploadTaskMap[_ackRequestId], cleared ? isNull : same(upload));
        expect(h.fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), cleared ? isNull : same(channel));
        if (row == _Nf5Row.retryAfter &&
            (event == _Nf5Event.sameConnect || event == _Nf5Event.differentConnect)) {
          expect(publicFailures, [isA<ServerOverloadedException>()]);
          expect(context.currentUserId, _userId);
          expect(h.fixture.starts, initialStarts);
        }
        final prefs = await SharedPreferences.getInstance();
        if (context.sessionKey == null) {
          expect(prefs.getString(_nf5PrefsKey), isNull);
        } else {
          final memory = context.sessionKey;
          context.sessionKey = null;
          expect(await h.sessions.getSessionKey(), memory);
        }
        final cancellationFailures = h.fixture.events.where((e) =>
            e.kind == SocketEventKind.authenticationFailed && e.error is ConnectionCanceledException);
        expect(cancellationFailures, isEmpty);
        if (event == _Nf5Event.login || event == _Nf5Event.correlatedLogin) {
          expect(connection.connectionSnapshot.authenticated,
              !((row == _Nf5Row.retryAfter || !completed) &&
                  event == _Nf5Event.correlatedLogin));
        }
        if (connection.getConnectionAttempt().authRequired == false) {
          await tester.pump(_nf3BusyWait);
          await _flush(tester);
          if (event == _Nf5Event.lateFailure && !ownerChanged &&
              row != _Nf5Row.backoff) {
            await connection.advanceReconnect();
            await _flush(tester);
          }
          if (connection.webSocketClient.isConnected()) {
            await h.packet(_loginCommand, {
              ..._loginPayload, _userIdField: context.currentUserId,
              _sessionKeyField: context.sessionKey ?? _nextSessionKey,
            });
            await _flush(tester);
            expect(connection.connectionSnapshot.authenticated, isTrue);
          }
        }
        if (publicWaiters.isNotEmpty && publicFailures.isEmpty) {
          await Future.wait(publicWaiters);
          expect(publicResults.single.userId,
              event == _Nf5Event.sameConnect ? _userId : _nf3OtherUser);
        }
        expect(recoveryResults.length, recoveries.length);
        expect(returnedAuthenticated, everyElement(isTrue));
        expect(returnedOpen, everyElement(isTrue));
        if (publicResults.isNotEmpty ||
            recoveryResults.contains(TransportRecoveryResult.authenticated)) {
          _nf6ExpectAuthenticated(h);
        }
        if (initialConnect != null) {
          expect(initialResults.length + initialFailures.length, _one);
          expect(initialFailures, everyElement(isA<SendbirdException>()));
          await initialConnect;
        }
        expect(publicResults.length + publicFailures.length, publicWaiters.length);
        _nf7ExpectNotifications(h);
        connection.cancelReconnectTimers();
      });
      }
    }
  }
}

enum _Nf5ClearStage { close, checkpoints, logout, database, device, retention }
const _nf5RetentionKey = 'flutter.com.sendbird.chat.config_ts_$_appId';

class _Nf5LogoutDispatcher extends _Dispatcher {
  _Nf5LogoutDispatcher(super.chat);
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<void> onLogout() async {
    if (entered) return;
    entered = true;
    await gate.future;
  }
}

class _Nf5ClearDB extends _CachedDB {
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<void> clear() async {
    if (entered) return;
    entered = true;
    await gate.future;
  }
}

class _Nf5ClearTokens extends _DeviceTokens {
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<void> cleanUp() async {
    if (entered) return;
    entered = true;
    await gate.future;
  }
}

class _Nf5Preferences extends InMemorySharedPreferencesStore {
  _Nf5Preferences() : super.empty();
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<bool> remove(String key) async {
    if (key == _nf5RetentionKey && !entered) { entered = true; await gate.future; }
    return super.remove(key);
  }
}

void _registerNf5ClearStages() {
  for (final stage in _Nf5ClearStage.values) {
    for (final sameUser in _hookModes) {
      for (final completed in _hookModes) {
      final label = completed ? 'NF5-C' : 'NF7-clear pending';
      testWidgets('$label clear await=${stage.name} sameUser=$sameUser', (tester) async {
        final h = _Nf5Harness(tester);
        if (completed) await _nf7CompletePublicLogin(h, tester);
        final connection = h.fixture.connection;
        final initialFailures = <Object>[];
        final initialResults = <User>[];
        Future<void>? initialConnect;
        if (!completed) {
          initialConnect = connection.connect(_userId).then<void>(initialResults.add,
              onError: (Object e) { initialFailures.add(e); });
          await _flush(tester);
        }
        final chat = h.fixture.chat;
        final close = Completer<bool>();
        final collections = _Nf5Collections(chat);
        final dispatcher = _Nf5LogoutDispatcher(chat);
        final db = _Nf5ClearDB();
        final tokens = _Nf5ClearTokens();
        final prefs = _Nf5Preferences();
        final previousPrefs = SharedPreferencesStorePlatform.instance;
        if (stage == _Nf5ClearStage.close) h.fixture.sockets.last.closeBarrier = close;
        if (stage == _Nf5ClearStage.checkpoints) chat.collectionManager = collections;
        if (stage == _Nf5ClearStage.logout) chat.eventDispatcher = dispatcher;
        if (stage == _Nf5ClearStage.database) chat.dbManager = db;
        if (stage == _Nf5ClearStage.device) chat.deviceTokenManager = tokens;
        if (stage == _Nf5ClearStage.retention) {
          SharedPreferencesStorePlatform.instance = prefs;
          addTearDown(() { SharedPreferencesStorePlatform.instance = previousPrefs; });
        }
        final retainedCollections = chat.collectionManager;
        final retainedDispatcher = chat.eventDispatcher;
        final retainedDatabase = chat.dbManager;
        final retainedTokens = chat.deviceTokenManager;
        final old = connection.doDisconnect(clear: true, logout: true);
        await _flush(tester);
        switch (stage) {
          case _Nf5ClearStage.close:
            expect(h.fixture.sockets.last.closes, greaterThan(_none));
            break;
          case _Nf5ClearStage.checkpoints:
            expect(collections.entered, isTrue);
            break;
          case _Nf5ClearStage.logout:
            expect(dispatcher.entered, isTrue);
            break;
          case _Nf5ClearStage.database:
            expect(db.entered, isTrue);
            break;
          case _Nf5ClearStage.device:
            expect(tokens.entered, isTrue);
            break;
          case _Nf5ClearStage.retention:
            expect(prefs.entered, isTrue);
            break;
        }
        h.fixture.sockets.last.closeBarrier = null;
        final nextUser = sameUser ? _userId : _nf3OtherUser;
        final returnedAuthenticated = <bool>[];
        final latest = connection.connect(nextUser, accessToken: _nextAccessToken).then((user) {
          returnedAuthenticated.add(connection.hasAuthenticatedTransport);
          return user;
        });
        await _flush(tester);
        await h.packet(_loginCommand, {
          ..._loginPayload, _userIdField: nextUser, _sessionKeyField: _nextSessionKey,
        });
        await _flush(tester);
        expect((await latest).userId, nextUser);
        expect(returnedAuthenticated, [true]);
        _nf6ExpectAuthenticated(h);
        final queue = AsyncQueue();
        final upload = AsyncSimpleTask(() async {});
        final channel = OpenChannel(channelUrl: _retainedChannel,
            participantCount: _none, operators: [])..set(chat);
        chat.setMessageQueue(_retainedChannel, queue);
        chat.uploadTaskMap[_ackRequestId] = upload;
        chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
        final snapshot = connection.connectionSnapshot;
        final owner = connection.authenticatedSessionIdentity;
        final starts = h.fixture.starts;
        close.complete(true);
        collections.gate.complete();
        dispatcher.gate.complete();
        db.gate.complete();
        tokens.gate.complete();
        prefs.gate.complete();
        await old;
        await _flush(tester);
        expect(chat.collectionManager, same(retainedCollections));
        expect(chat.eventDispatcher, same(retainedDispatcher));
        expect(chat.dbManager, same(retainedDatabase));
        expect(chat.deviceTokenManager, same(retainedTokens));
        expect(chat.messageQueueMap[_retainedChannel], same(queue));
        expect(chat.uploadTaskMap[_ackRequestId], same(upload));
        expect(chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), same(channel));
        expect(chat.chatContext.currentUserId, nextUser);
        expect(chat.chatContext.sessionKey, _nextSessionKey);
        expect(connection.authenticatedSessionIdentity, same(owner));
        expect(connection.connectionSnapshot.key, same(snapshot.key));
        expect(connection.connectionSnapshot.authenticated, isTrue);
        expect(h.fixture.starts, starts);
        _nf6ExpectAuthenticated(h);
        expect(h.handler.events, isEmpty);
        expect(h.fixture.events.where((e) => e.kind == SocketEventKind.authenticationFailed), isEmpty);
        chat.chatContext.sessionKey = null;
        expect(await h.sessions.getSessionKey(), _nextSessionKey);
        if (initialConnect != null) {
          expect(initialResults, isEmpty);
          expect(initialFailures, [isA<ConnectionCanceledException>()]);
          await initialConnect;
        }
        _nf7ExpectNotifications(h);
      });
      }
    }
  }
}

const _nf5Connected = 'connected';
const _nf5Disconnected = 'disconnected';
const _nf5ReconnectStarted = 'reconnectStarted';
const _nf5ReconnectSucceeded = 'reconnectSucceeded';
const _nf5ReconnectFailed = 'reconnectFailed';

class _Nf5ConnectionHandler extends ConnectionHandler {
  final events = <String>[];
  final connectedUsers = <String>[];
  final reconnectOwners = <String?>[];
  String? Function()? currentUser;
  void Function(String)? disconnected;
  void Function(String)? callback;
  @override
  void onConnected(String userId) {
    connectedUsers.add(userId);
    events.add(_nf5Connected);
    callback?.call(_nf5Connected);
  }
  @override
  void onDisconnected(String userId) {
    events.add(_nf5Disconnected);
    disconnected?.call(userId);
    callback?.call(_nf5Disconnected);
  }
  @override
  void onReconnectStarted() {
    reconnectOwners.add(currentUser?.call());
    events.add(_nf5ReconnectStarted);
    callback?.call(_nf5ReconnectStarted);
  }
  @override
  void onReconnectSucceeded() {
    reconnectOwners.add(currentUser?.call());
    events.add(_nf5ReconnectSucceeded);
    callback?.call(_nf5ReconnectSucceeded);
  }
  @override
  void onReconnectFailed() {
    reconnectOwners.add(currentUser?.call());
    events.add(_nf5ReconnectFailed);
    callback?.call(_nf5ReconnectFailed);
  }
}

void _registerNf5CancellationContracts() {
  for (final background in _hookModes) {
    testWidgets('NF5-S1 recovery cancellation handler contract background=$background', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      h.connectionHandler.events.clear();
      final recovery = h.fixture.connection.recoverTransport();
      await _flush(tester);
      if (background) {
        h.fixture.chat.isBackground = true;
        await h.fixture.connection.enterBackground();
      } else {
        final replacing = h.fixture.connection.connect(_userId);
        await _flush(tester);
        expect(h.fixture.connection.connectionSnapshot.authenticated, isFalse);
        await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
        await _flush(tester);
        expect((await replacing).userId, _userId);
      }
      await _flush(tester);
      expect(await recovery, TransportRecoveryResult.cancelled);
      expect(h.fixture.connection.connectionSnapshot.authenticated, !background);
      expect(h.fixture.events.where((e) => e.kind == SocketEventKind.authenticationFailed), isEmpty);
      expect(h.connectionHandler.events,
          background ? [_nf5ReconnectStarted, _nf5ReconnectFailed] :
              [_nf5ReconnectStarted, _nf5ReconnectFailed, _nf5Connected]);
    });
  }
}


void _nf6ExpectAuthenticated(_Nf5Harness h) {
  expect(h.fixture.connection.webSocketClient.isConnected(), isTrue);
  expect(h.fixture.connection.connectionSnapshot.authenticated, isTrue);
  expect(h.fixture.connection.connectionSnapshot.key, isNotNull);
  expect(h.fixture.connection.getConnectionAttempt().authRequired, isFalse);
}

class _Nf6CheckpointDB extends audit.DbPort {
  _Nf6CheckpointDB(Chat chat, audit.Trace trace, audit.CounterIsar isar)
      : super(chat: chat, trace: trace, isar: isar);
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<void> setLoginInfo(ChatContext context, User user,
      {bool Function()? shouldPersist}) async {}
  @override
  Future<void> updateGroupChannelReadStatus(GroupChannel channel,
      {required bool Function() shouldPersist}) async {
    if (channel.channelUrl == audit.A.room) {
      entered = true;
      await gate.future;
    }
    await super.updateGroupChannelReadStatus(channel, shouldPersist: shouldPersist);
  }
}

void _registerNf6Tests() {
  _registerNf6TokenMatrix();
  _registerNf6StaleMatrix();
  _registerNf6Continuations();
  testWidgets('NF6-A1 authenticated A clear B latest A', (tester) async {
    final h = _Nf5Harness(tester);
    await h.login(tester);
    final connection = h.fixture.connection;
    final collections = _Nf5Collections(h.fixture.chat);
    h.fixture.chat.collectionManager = collections;
    Object? failure;
    final old = connection.connect(_nf3OtherUser).then<void>((_) {},
        onError: (Object error) { failure = error; });
    await _flush(tester);
    expect(collections.entered, isTrue);
    User? result;
    bool? authenticatedAtReturn;
    bool? openAtReturn;
    final latest = connection.connect(_userId).then((user) {
      authenticatedAtReturn = connection.connectionSnapshot.authenticated;
      openAtReturn = connection.webSocketClient.isConnected();
      result = user;
    });
    await _flush(tester);
    collections.gate.complete();
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await latest;
    await old;
    expect(result!.userId, _userId);
    expect(authenticatedAtReturn, isTrue);
    expect(openAtReturn, isTrue);
    expect(failure, isA<ConnectionCanceledException>());
    _nf6ExpectAuthenticated(h);
  });

  testWidgets('NF6-A2 first LOGI continuation cannot replace newer key owner', (tester) async {
    final h = _Nf5Harness(tester);
    await h.login(tester);
    final gate = Completer<void>();
    h.fixture.deviceTokens.barrier = gate;
    final earlier = h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nf2StaleKey});
    await _flush(tester);
    await h.packet(_loginCommand, {_requestIdField: _ackRequestId, _sessionKeyField: _nextSessionKey});
    final owner = h.fixture.connection.authenticatedSessionIdentity;
    h.fixture.chat.eventManager.notifyAccessTokenRequired();
    final requester = h.handler.requester!;
    gate.complete();
    await earlier;
    await _flush(tester);
    expect(h.fixture.connection.authenticatedSessionIdentity, same(owner));
    expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
    h.fixture.chat.chatContext.sessionKey = null;
    expect(await h.sessions.getSessionKey(), _nextSessionKey);
    final response = requester.onSuccess(_nextAccessToken);
    await _flush(tester);
    expect(h.api.requests, _one);
    h.api.response.complete({_sessionKeyField: _nextSessionKey});
    await response;
    await _flush(tester);
    expect(h.handler.events, [_nf2SessionRefreshed, _nf2SessionRequired, _nf2SessionRefreshed]);
  });

  testWidgets('NF6-A3 automatic reconnect backoff connect closes notification', (tester) async {
    final h = _Nf5Harness(tester);
    await h.login(tester);
    h.connectionHandler.events.clear();
    h.fixture.sockets.last.closed();
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    expect(h.connectionHandler.events, [_nf5ReconnectStarted]);
    h.fixture.sockets.last.closed();
    await tester.pump(_legacyReconnectDelay);
    await tester.pump(_statSettlingTick);
    await _flush(tester);
    expect(h.fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
    expect(h.fixture.chat.chatContext.loginCompleter, isNull);
    final latest = h.fixture.connection.connect(_userId);
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await latest;
    await _flush(tester);
    _nf6ExpectAuthenticated(h);
    expect(h.connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectFailed, _nf5Connected]);
  });

  testWidgets('NF6-A4 actual BUSY then LOGI cancels delayed timer', (tester) async {
    final h = _Nf5Harness(tester);
    await h.login(tester);
    h.fixture.sockets.last.closed();
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    await h.packet(_busyCommand, {_retryAfterField: _busySeconds});
    final state = h.fixture.connection.getCurrentState();
    expect(state, isA<DelayedConnectingState>());
    expect(h.fixture.connection.webSocketClient.isConnected(), isTrue);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    _nf6ExpectAuthenticated(h);
    final starts = h.fixture.starts;
    await tester.pump(_nf3BusyWait);
    await _flush(tester);
    _nf6ExpectAuthenticated(h);
    expect(h.fixture.starts, starts);
    expect((state as DelayedConnectingState).retryAfterTimer, isNull);
  });

  testWidgets('NF6-P checkpoint writes survive session refresh without clear', (tester) async {
    final h = _Nf5Harness(tester);
    final chat = h.fixture.chat;
    chat.collectionManager = CollectionManager(chat: chat);
    await h.login(tester);
    final trace = audit.Trace(_appId, _userId, FakeAsync());
    final isar = audit.CounterIsar(trace);
    final db = _Nf6CheckpointDB(chat, trace, isar);
    chat.dbManager = db;
    final first = GroupChannel.fromJson(audit.channelJson(audit.A.room))..set(chat);
    final second = GroupChannel.fromJson(audit.channelJson(audit.A.warmRoom))..set(chat);
    await db.upsertGroupChannels([first, second]);
    chat.channelCache.insert(channelKey: first.channelUrl, data: first);
    chat.channelCache.insert(channelKey: second.channelUrl, data: second);
    await h.packet(CommandString.read, audit.readPayload(_one));
    await tester.pump(audit.A.local);
    expect(db.entered, isTrue);
    await h.packet(_loginCommand, {_requestIdField: _ackRequestId, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await h.packet(CommandString.read, {
      ...audit.readPayload(_two), audit.A.channelUrl: audit.A.warmRoom,
    });
    await tester.pump(audit.A.local);
    db.gate.complete();
    await _flush(tester);
    final restoredDb = DB(chat: Chat(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false)), isar: isar);
    final restoredFirst = await restoredDb.getGroupChannel(audit.A.room);
    final restoredSecond = await restoredDb.getGroupChannel(audit.A.warmRoom);
    expect(restoredFirst!.getCachedReadStatus(audit.A.room)[audit.A.peer], _one);
    expect(restoredSecond!.getCachedReadStatus(audit.A.warmRoom)[audit.A.peer], _two);
    _nf6ExpectAuthenticated(h);
  });

  for (final releaseBeforeFlush in _hookModes) {
  testWidgets('NF6-A5 real collection keeps new READ releaseBeforeFlush=$releaseBeforeFlush', (tester) async {
    final h = _Nf5Harness(tester);
    final chat = h.fixture.chat;
    final collections = CollectionManager(chat: chat);
    chat.collectionManager = collections;
    await h.login(tester);
    final trace = audit.Trace(_appId, _userId, FakeAsync());
    final isar = audit.CounterIsar(trace);
    final db = _Nf6CheckpointDB(chat, trace, isar);
    chat.dbManager = db;
    final first = GroupChannel.fromJson(audit.channelJson(audit.A.room))..set(chat);
    final second = GroupChannel.fromJson(audit.channelJson(audit.A.warmRoom))..set(chat);
    await db.upsertGroupChannels([first, second]);
    chat.channelCache.insert(channelKey: first.channelUrl, data: first);
    chat.channelCache.insert(channelKey: second.channelUrl, data: second);
    await h.packet(CommandString.read, audit.readPayload(_one));
    await tester.pump(audit.A.local);
    expect(db.entered, isTrue);
    h.fixture.connection.requireAuthentication();
    Object? failure;
    final old = h.fixture.connection.connect(_nf3OtherUser).then<void>((_) {},
        onError: (Object error) { failure = error; });
    await _flush(tester);
    final latest = h.fixture.connection.connect(_userId);
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await latest;
    await _flush(tester);
    _nf6ExpectAuthenticated(h);
    await h.packet(CommandString.read, {
      ...audit.readPayload(_two), audit.A.channelUrl: audit.A.warmRoom,
    });
    if (releaseBeforeFlush) db.gate.complete();
    await tester.pump(audit.A.local);
    if (!releaseBeforeFlush) db.gate.complete();
    await old;
    await _flush(tester);
    expect(failure, isA<ConnectionCanceledException>());
    expect(chat.collectionManager, same(collections));
    final restored = await DB(chat: Chat(appId: _appId, options: SendbirdChatOptions(useCollectionCaching: false)), isar: isar).getGroupChannel(audit.A.warmRoom);
    expect(restored!.getCachedReadStatus(audit.A.warmRoom)[audit.A.peer], _two);
  });
  }
}


enum _Nf6TokenEvent { sameConnect, differentConnect, recover, lifecycle, tokenSuccess, tokenFailure }

void _registerNf6TokenMatrix() {
  for (final event in _Nf6TokenEvent.values) {
    testWidgets('NF6-M tokenRequester/${event.name}', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      await h.packet(_loginCommand, {
        _errorField: true, _codeField: SendbirdError.accessTokenNotValid,
      });
      await _flush(tester);
      final connection = h.fixture.connection;
      final owner = connection.authenticatedSessionIdentity;
      final requester = h.handler.requester!;
      expect(connection.getConnectionAttempt().authRequired, isTrue);
      expect(h.api.requests, _none);
      expect(h.handler.events, [_nf2SessionRequired]);
      final starts = h.fixture.starts;
      switch (event) {
        case _Nf6TokenEvent.sameConnect:
        case _Nf6TokenEvent.differentConnect:
          final user = event == _Nf6TokenEvent.sameConnect ? _userId : _nf3OtherUser;
          bool? authenticated;
          bool? open;
          final latest = connection.connect(user).then((result) {
            authenticated = connection.connectionSnapshot.authenticated;
            open = connection.webSocketClient.isConnected();
            return result;
          });
          await _flush(tester);
          await h.packet(_loginCommand, {..._loginPayload,
            _userIdField: user, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect((await latest).userId, user);
          expect(authenticated, isTrue);
          expect(open, isTrue);
          await requester.onSuccess(_nextAccessToken);
          await requester.onFail();
          expect(h.api.requests, _none);
          expect(h.handler.events, [_nf2SessionRequired]);
          _nf6ExpectAuthenticated(h);
          break;
        case _Nf6TokenEvent.recover:
          expect(await connection.recoverTransport(), TransportRecoveryResult.authRequired);
          break;
        case _Nf6TokenEvent.lifecycle:
          await h.fixture.chat.didChangeAppLifecycleState(AppLifecycleState.paused);
          await h.fixture.chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
          break;
        case _Nf6TokenEvent.tokenSuccess:
          final pending = requester.onSuccess(_nextAccessToken);
          await _flush(tester);
          expect(h.api.requests, _one);
          h.api.response.complete({_sessionKeyField: _nextSessionKey});
          await pending;
          await _flush(tester);
          await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          _nf6ExpectAuthenticated(h);
          expect(h.handler.events, [_nf2SessionRequired, _nf2SessionRefreshed]);
          break;
        case _Nf6TokenEvent.tokenFailure:
          await requester.onFail();
          await requester.onFail();
          expect(h.handler.events, [_nf2SessionRequired, _nf2SessionError]);
          break;
      }
      if (event == _Nf6TokenEvent.recover || event == _Nf6TokenEvent.lifecycle ||
          event == _Nf6TokenEvent.tokenFailure) {
        expect(connection.authenticatedSessionIdentity,
            event == _Nf6TokenEvent.tokenFailure ? isNot(same(owner)) : same(owner));
        expect(h.api.requests, _none);
        expect(h.fixture.starts, starts);
        expect(connection.getConnectionAttempt().authRequired, isTrue);
        expect(connection.connectionSnapshot.authenticated, isFalse);
      }
      _nf7ExpectNotifications(h);
    });
  }
}

enum _Nf6Row { http, httpRequester, tokenRequester, logi, expr, close, clear, retryAfter, backoff }
enum _Nf6Callback { close, error, data, login }

void _registerNf6StaleMatrix() {
  for (final row in _Nf6Row.values) {
    for (final callback in _Nf6Callback.values) {
      for (final afterLogin in _hookModes) {
        testWidgets('NF6-D ${row.name}/${callback.name} authenticated=$afterLogin', (tester) async {
          final h = _Nf5Harness(tester);
          await h.login(tester);
          final connection = h.fixture.connection;
          final gate = Completer<bool>();
          final collections = _Nf5Collections(h.fixture.chat);
          Future<void>? old;
          Future<TransportRecoveryResult>? oldRecovery;
          AccessTokenRequester? requester;
          final failures = <Object>[];
          if (row == _Nf6Row.retryAfter || row == _Nf6Row.backoff) {
            h.fixture.sockets.last.closed();
            await tester.pump(_legacyReconnectDelay);
            await _flush(tester);
            if (row == _Nf6Row.retryAfter) {
              await h.packet(_busyCommand, {_retryAfterField: _busySeconds});
              expect(connection.getCurrentState(), isA<DelayedConnectingState>());
            } else {
              h.fixture.sockets.last.closed();
              await tester.pump(_legacyReconnectDelay);
              await tester.pump(_statSettlingTick);
              await _flush(tester);
              expect(connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
            }
          }
          if (row == _Nf6Row.tokenRequester) {
            await h.packet(_loginCommand, {
              _errorField: true, _codeField: SendbirdError.accessTokenNotValid,
            });
            await _flush(tester);
            requester = h.handler.requester;
            expect(h.api.requests, _none);
          } else if (row == _Nf6Row.expr) {
            await h.packet(_nf4SessionCommand, {});
          } else {
            old = h.sessions.updateSessionKey().then<void>((_) {},
                onError: (Object e) { failures.add(e); });
          }
          await _flush(tester);
          if (row == _Nf6Row.httpRequester) {
            h.fixture.chat.eventManager.notifyAccessTokenRequired();
            requester = h.handler.requester;
          }
          if (row == _Nf6Row.logi) {
            await h.fixture.chat.commandManager.sendCommand(Command(
              cmd: _loginCommand, requestId: _ackRequestId,
              payload: {_requestIdField: _ackRequestId}));
          }
          final data = h.fixture.sockets.last.data;
          final closed = h.fixture.sockets.last.closed;
          final error = h.fixture.sockets.last.error;
          Future<void>? clear;
          if (row == _Nf6Row.close) {
            h.fixture.sockets.last.closeBarrier = gate;
            oldRecovery = connection.recoverTransport();
            await _flush(tester);
          }
          if (row == _Nf6Row.clear) {
            h.fixture.chat.collectionManager = collections;
            clear = connection.doDisconnect(clear: true);
            await _flush(tester);
            expect(collections.entered, isTrue);
          }
          Future<User>? connecting;
          Future<TransportRecoveryResult>? recovery;
          final authenticatedReturns = <bool>[];
          final openReturns = <bool>[];
          if (row == _Nf6Row.retryAfter) {
            recovery = connection.recoverTransport().then((result) {
              authenticatedReturns.add(connection.connectionSnapshot.authenticated);
              openReturns.add(connection.webSocketClient.isConnected());
              return result;
            });
            await _flush(tester);
            await tester.pump(_nf3BusyWait);
          } else {
            connecting = connection.connect(_userId, accessToken: _nextAccessToken).then((user) {
              authenticatedReturns.add(connection.connectionSnapshot.authenticated);
              openReturns.add(connection.webSocketClient.isConnected());
              return user;
            });
          }
          await _flush(tester);
          gate.complete(true);
          h.fixture.sockets.first.closeBarrier = null;
          collections.gate.complete();
          await _flush(tester);
          if (clear != null) await clear;
          if (afterLogin) {
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            await _flush(tester);
            _nf6ExpectAuthenticated(h);
          }
          final snapshot = connection.connectionSnapshot;
          final owner = connection.authenticatedSessionIdentity;
          final key = h.fixture.chat.chatContext.sessionKey;
          final starts = h.fixture.starts;
          final events = List<String>.of(h.handler.events);
          final connectionEvents = List<String>.of(h.connectionHandler.events);
          switch (callback) {
            case _Nf6Callback.close:
              closed();
              break;
            case _Nf6Callback.error:
              error(WebSocketFailedException());
              break;
            case _Nf6Callback.data:
              await data('$_nf4SessionCommand${jsonEncode({_nf4ReasonField: SendbirdError.accessTokenRevoked})}');
              break;
            case _Nf6Callback.login:
              await data('$_loginCommand${jsonEncode({..._loginPayload,
                _userIdField: _nf3OtherUser, _sessionKeyField: _nf2StaleKey})}');
              break;
          }
          await _flush(tester);
          expect(connection.connectionSnapshot.key, same(snapshot.key));
          expect(connection.connectionSnapshot.authenticated, snapshot.authenticated);
          expect(connection.authenticatedSessionIdentity, same(owner));
          expect(h.fixture.chat.chatContext.sessionKey, key);
          expect(h.fixture.starts, starts);
          expect(h.handler.events, events);
          expect(h.connectionHandler.events, connectionEvents);
          expect(connection.webSocketClient.isConnected(), isTrue);
          if (!afterLogin) {
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            await _flush(tester);
          }
          if (connecting != null) expect((await connecting).userId, _userId);
          if (recovery != null) expect(await recovery, TransportRecoveryResult.authenticated);
          if (oldRecovery != null) expect(await oldRecovery, TransportRecoveryResult.cancelled);
          if (row != _Nf6Row.tokenRequester) {
            h.api.response.complete({_sessionKeyField: _nf2StaleKey});
            await _flush(tester);
            if (old != null) await old;
          }
          if (requester != null) {
            await requester.onSuccess(_nextAccessToken);
            await requester.onFail();
          }
          expect(authenticatedReturns, everyElement(isTrue));
          expect(openReturns, everyElement(isTrue));
          expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
          _nf6ExpectAuthenticated(h);
          _nf7ExpectNotifications(h);
        });
      }
    }
  }
}

enum _Nf6Continuation { loginPrefs, loginDatabase, loginDispatcher, correlatedSave, httpSave }
enum _Nf6Interruption { login, correlatedLogin, revoke, differentConnect, replaceTransport }
const _nf6DeviceList = 'flutter.com.sendbird.chat.device_token_list_$_appId';
const _nf6ApplicationAttributes = 'application_attributes';
const _nf6DeviceCache = 'sdk_device_token_cache';

class _Nf6LoginPreferences extends InMemorySharedPreferencesStore {
  _Nf6LoginPreferences() : super.empty();
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<bool> remove(String key) async {
    if (key == _nf6DeviceList && !entered) {
      entered = true;
      await gate.future;
    }
    return super.remove(key);
  }
}

class _Nf6SessionContinuation extends SessionManager {
  _Nf6SessionContinuation(Chat chat) : super(chat: chat);
  Completer<void>? gate;
  bool entered = false;
  @override
  Future<void> setSessionKey(String? key) async {
    await super.setSessionKey(key);
    if (gate != null && key == _nf2StaleKey && !entered) {
      entered = true;
      await gate!.future;
    }
  }
}

void _registerNf6Continuations() {
  for (final stage in _Nf6Continuation.values) {
    for (final event in _Nf6Interruption.values) {
      testWidgets('NF6-C ${stage.name}/${event.name}', (tester) async {
        final h = _Nf5Harness(tester);
        await h.login(tester);
        final chat = h.fixture.chat;
        final connection = h.fixture.connection;
        final gate = Completer<void>();
        final prefs = _Nf6LoginPreferences();
        final db = _CachedDB();
        final sessions = _Nf6SessionContinuation(chat);
        Future<void>? oldRefresh;
        final failures = <Object>[];
        if (stage == _Nf6Continuation.loginPrefs) {
          final previous = SharedPreferencesStorePlatform.instance;
          SharedPreferencesStorePlatform.instance = prefs;
          addTearDown(() { SharedPreferencesStorePlatform.instance = previous; });
          chat.deviceTokenManager = DeviceTokenManager(appId: _appId);
        } else if (stage == _Nf6Continuation.loginDatabase) {
          db.returnBarrier = gate;
          chat.dbManager = db;
        } else if (stage == _Nf6Continuation.loginDispatcher) {
          h.fixture.dispatcher.barrier = gate;
        } else {
          sessions.gate = gate;
          chat.sessionManager = sessions;
        }
        if (stage == _Nf6Continuation.httpSave) {
          oldRefresh = sessions.updateSessionKey().then<void>((_) {},
              onError: (Object e) { failures.add(e); });
          await _flush(tester);
          h.api.response.complete({_sessionKeyField: _nf2StaleKey});
        } else {
          await h.packet(_loginCommand, {
            if (stage != _Nf6Continuation.correlatedSave) ..._loginPayload,
            if (stage == _Nf6Continuation.correlatedSave) _requestIdField: _ackRequestId,
            if (stage == _Nf6Continuation.loginPrefs) _nf6ApplicationAttributes: [_nf6DeviceCache],
            _sessionKeyField: _nf2StaleKey,
          });
        }
        await _flush(tester);
        if (stage == _Nf6Continuation.loginPrefs) expect(prefs.entered, isTrue);
        if (stage == _Nf6Continuation.loginDatabase) expect(db.users.length, _one);
        if (stage == _Nf6Continuation.correlatedSave || stage == _Nf6Continuation.httpSave) {
          expect(sessions.entered, isTrue);
        }
        db.returnBarrier = null;
        h.fixture.dispatcher.barrier = null;
        Future<User>? connect;
        Future<TransportRecoveryResult>? recovery;
        final authenticatedReturns = <bool>[];
        final openReturns = <bool>[];
        switch (event) {
          case _Nf6Interruption.login:
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            break;
          case _Nf6Interruption.correlatedLogin:
            await h.packet(_loginCommand, {_requestIdField: _ackRequestId, _sessionKeyField: _nextSessionKey});
            break;
          case _Nf6Interruption.revoke:
            await h.packet(_nf4SessionCommand, {_nf4ReasonField: SendbirdError.accessTokenRevoked});
            break;
          case _Nf6Interruption.differentConnect:
            connect = connection.connect(_nf3OtherUser).then((user) {
              authenticatedReturns.add(connection.connectionSnapshot.authenticated);
              openReturns.add(connection.webSocketClient.isConnected());
              return user;
            });
            await _flush(tester);
            await h.packet(_loginCommand, {..._loginPayload,
              _userIdField: _nf3OtherUser, _sessionKeyField: _nextSessionKey});
            break;
          case _Nf6Interruption.replaceTransport:
            recovery = connection.recoverTransport().then((result) {
              authenticatedReturns.add(connection.connectionSnapshot.authenticated);
              openReturns.add(connection.webSocketClient.isConnected());
              return result;
            });
            await _flush(tester);
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            break;
        }
        await _flush(tester);
        if (connect != null) expect((await connect).userId, _nf3OtherUser);
        if (recovery != null) expect(await recovery, TransportRecoveryResult.authenticated);
        final owner = connection.authenticatedSessionIdentity;
        final snapshot = connection.connectionSnapshot;
        final key = chat.chatContext.sessionKey;
        final events = List<String>.of(h.handler.events);
        final notifications = List<String>.of(h.connectionHandler.events);
        final starts = h.fixture.starts;
        gate.complete();
        prefs.gate.complete();
        await _flush(tester);
        if (oldRefresh != null) await oldRefresh;
        expect(connection.authenticatedSessionIdentity, same(owner));
        expect(connection.connectionSnapshot.key, same(snapshot.key));
        expect(connection.connectionSnapshot.authenticated, snapshot.authenticated);
        expect(chat.chatContext.sessionKey, key);
        expect(h.handler.events, events);
        expect(h.connectionHandler.events, notifications);
        expect(h.fixture.starts, starts);
        expect(authenticatedReturns, everyElement(isTrue));
        expect(openReturns, everyElement(isTrue));
        _nf7ExpectNotifications(h);
        if (stage == _Nf6Continuation.httpSave) expect(failures, [isA<ConnectionCanceledException>()]);
        if (key != null) {
          chat.chatContext.sessionKey = null;
          expect(await chat.sessionManager.getSessionKey(), key);
        } else {
          expect((await SharedPreferences.getInstance()).getString(_nf5PrefsKey), isNull);
        }
      });
    }
  }
  for (final recover in _hookModes) {
    testWidgets('NF6-C BUSY delayed close continuation recover=$recover', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      final connection = h.fixture.connection;
      h.fixture.sockets.last.closed();
      await tester.pump(_legacyReconnectDelay);
      await _flush(tester);
      await h.packet(_busyCommand, {_retryAfterField: _busySeconds});
      final previous = h.fixture.sockets.last;
      final gate = Completer<bool>();
      previous.closeBarrier = gate;
      await tester.pump(_nf3BusyWait);
      await _flush(tester);
      expect(previous.closes, greaterThan(_none));
      previous.closeBarrier = null;
      Future<User>? connect;
      Future<TransportRecoveryResult>? recovery;
      if (recover) {
        recovery = connection.recoverTransport();
      } else {
        connect = connection.connect(_nf3OtherUser);
      }
      await _flush(tester);
      await h.packet(_loginCommand, {..._loginPayload,
        _userIdField: recover ? _userId : _nf3OtherUser, _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      if (connect != null) expect((await connect).userId, _nf3OtherUser);
      if (recovery != null) expect(await recovery, TransportRecoveryResult.authenticated);
      _nf6ExpectAuthenticated(h);
      final starts = h.fixture.starts;
      final owner = connection.authenticatedSessionIdentity;
      gate.complete(true);
      await _flush(tester);
      expect(connection.authenticatedSessionIdentity, same(owner));
      expect(h.fixture.starts, starts);
      _nf6ExpectAuthenticated(h);
      _nf7ExpectNotifications(h);
    });
  }
}


enum _Nf7Initial { pending, completed, automatic }

enum _Nf7Stage { loginPrefs, loginDatabase, loginDispatcher, correlatedSave, httpSave }
enum _Nf7Event { close, error, correlatedLogin, login, revoke, differentConnect, replaceTransport }

class _Nf7Isar extends audit.CounterIsar {
  _Nf7Isar(super.trace);
  final logins = <String, CLogin>{};
  Completer<void>? transactionGate;
  int? gateAt;
  int transactions = _none;
  bool afterTransaction = false;
  bool transactionEntered = false;
  final savedLogins = <CLogin>[];
  @override
  Future<T> writeTxn<T>(Future<T> Function() callback, {bool silent = false}) async {
    transactions++;
    final gated = transactions == gateAt;
    if (gated) transactionEntered = true;
    if (gated && !afterTransaction) await transactionGate!.future;
    final result = await super.writeTxn(callback, silent: silent);
    if (gated && afterTransaction) await transactionGate!.future;
    return result;
  }
  @override
  IsarCollection<T> collection<T>() => T == CLogin ? _Nf7Rows<T>(this) : super.collection<T>();
  @override
  void put(Object? row) {
    if (Zone.current[audit.A.txnZone] != true) throw StateError(audit.A.txnMissing);
    trace.add(audit.K.row, row.runtimeType);
    if (row is CGroupChannel) channels[row.channelUrl] = row;
    if (row is CUserMessage) messages[row.messageId] = row;
    if (row is CUser) users[row.userId] = row;
    if (row is CLogin) {
      logins[row.userId] = row;
      savedLogins.add(row);
    }
  }
  @override
  Future<void> clear() async {
    channels.clear();
    messages.clear();
    users.clear();
    logins.clear();
  }
}

class _Nf7Rows<T> extends audit.Rows<T> {
  _Nf7Rows(_Nf7Isar super.owner);
  @override
  Query<R> buildQuery<R>({List<WhereClause> whereClauses = const [],
      bool whereDistinct = false, Sort whereSort = Sort.asc,
      FilterOperation? filter, List<SortProperty> sortBy = const [],
      List<DistinctProperty> distinctBy = const [], int? offset, int? limit,
      String? property}) {
    final key = (whereClauses.single as IndexWhereClause).lower!.single;
    return audit.RowQuery<R>((owner as _Nf7Isar).logins[key] as R?);
  }
}

class _Nf7DB extends DB {
  _Nf7DB({required super.chat, required super.isar});
  Completer<void>? gate;
  bool entered = false;
  int clearCalls = _none;
  @override
  Future<void> clear({bool Function()? shouldPersist}) {
    clearCalls++;
    return super.clear(shouldPersist: shouldPersist);
  }
  @override
  Future<Login?> getLogin(String userId) async {
    final result = await super.getLogin(userId);
    if (gate != null && !entered) {
      entered = true;
      await gate!.future;
    }
    return result;
  }
}

class _Nf7DBManager extends audit.DbPort {
  _Nf7DBManager(Chat chat, audit.Trace trace, _Nf7Isar isar)
      : actual = _Nf7DB(chat: chat, isar: isar),
        super(chat: chat, trace: trace, isar: isar);
  final _Nf7DB actual;
  @override
  DB getDB() => actual;
  @override
  Future<void> clear() => actual.clear();
}

void _nf7ExpectNotifications(_Nf5Harness h) {
  var pending = false;
  for (final event in h.connectionHandler.events) {
    if (event == _nf5ReconnectStarted) {
      expect(pending, isFalse);
      pending = true;
    } else if (event == _nf5ReconnectSucceeded || event == _nf5ReconnectFailed) {
      expect(pending, isTrue);
      pending = false;
    } else if (event == _nf5Connected) {
      expect(pending, isFalse);
    }
  }
  expect(pending, isFalse);
  expect(h.fixture.connection.reconnectNotificationPending, isFalse);
  for (var index = _none; index < h.connectionHandler.reconnectOwners.length; index += _two) {
    expect(h.connectionHandler.reconnectOwners[index + _one],
        h.connectionHandler.reconnectOwners[index]);
  }
}

Future<void> _nf7CompletePublicLogin(_Nf5Harness h, WidgetTester tester) async {
  final connection = h.fixture.connection;
  final returns = <bool>[];
  final connecting = connection.connect(_userId).then((user) {
    returns.add(connection.hasAuthenticatedTransport);
    return user;
  });
  await _flush(tester);
  await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
  await _flush(tester);
  expect((await connecting).userId, _userId);
  expect(returns, [true]);
  _nf7ExpectNotifications(h);
}

void _registerNf7Tests() {
  _registerNf9Tests();
  _registerNf8Tests();
  _registerNf7DatabaseMatrix();
  for (final stage in _Nf7Stage.values) {
    for (final event in _Nf7Event.values) {
      for (final initial in _Nf7Initial.values) {
        final completed = initial != _Nf7Initial.pending;
        final automatic = initial == _Nf7Initial.automatic;
        testWidgets('NF7-C ${stage.name}/${event.name} initial=${initial.name}', (tester) async {
          final h = _Nf5Harness(tester);
          final connection = h.fixture.connection;
          if (completed) await _nf7CompletePublicLogin(h, tester);
          if (automatic) {
            h.fixture.sockets.last.closed();
            await tester.pump(_legacyReconnectDelay);
            await _flush(tester);
            expect(connection.reconnectNotificationPending, isTrue);
          }
          final results = <User>[];
          final failures = <Object>[];
          final authenticated = <bool>[];
          final opened = <bool>[];
          Future<void>? connecting;
          if (!completed) {
            connecting = connection.connect(_userId).then<void>((user) {
              results.add(user);
              authenticated.add(connection.connectionSnapshot.authenticated);
              opened.add(connection.webSocketClient.isConnected());
            }, onError: (Object e) { failures.add(e); });
            await _flush(tester);
          }
          final gate = Completer<void>();
          final db = _CachedDB();
          final sessions = _Nf6SessionContinuation(h.fixture.chat);
          Future<void>? refresh;
          final refreshFailures = <Object>[];
          switch (stage) {
            case _Nf7Stage.loginPrefs:
              h.fixture.deviceTokens.barrier = gate;
              break;
            case _Nf7Stage.loginDatabase:
              db.returnBarrier = gate;
              h.fixture.chat.dbManager = db;
              break;
            case _Nf7Stage.loginDispatcher:
              h.fixture.dispatcher.barrier = gate;
              break;
            case _Nf7Stage.correlatedSave:
            case _Nf7Stage.httpSave:
              h.fixture.chat.sessionManager = sessions;
              sessions.gate = gate;
              break;
          }
          if (stage == _Nf7Stage.httpSave) {
            refresh = sessions.updateSessionKey().then<void>((_) {},
                onError: (Object e) { refreshFailures.add(e); });
            await _flush(tester);
            h.api.response.complete({_sessionKeyField: _nf2StaleKey});
          } else {
            await h.packet(_loginCommand, {
              if (stage != _Nf7Stage.correlatedSave) ..._loginPayload,
              if (stage == _Nf7Stage.correlatedSave) _requestIdField: _ackRequestId,
              _sessionKeyField: _nf2StaleKey});
          }
          await _flush(tester);
          h.fixture.deviceTokens.barrier = null;
          h.fixture.dispatcher.barrier = null;
          db.returnBarrier = null;
          Future<void>? nextConnect;
          Future<TransportRecoveryResult>? recovery;
          final nextResults = <User>[];
          final nextFailures = <Object>[];
          final recoveryResults = <TransportRecoveryResult>[];
          switch (event) {
            case _Nf7Event.close:
              h.fixture.sockets.last.closed();
              break;
            case _Nf7Event.error:
              h.fixture.sockets.last.connected = false;
              h.fixture.sockets.last.error(WebSocketFailedException());
              break;
            case _Nf7Event.correlatedLogin:
              await h.packet(_loginCommand, {_requestIdField: _ackRequestId,
                _sessionKeyField: _nextSessionKey});
              break;
            case _Nf7Event.login:
              await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
              break;
            case _Nf7Event.revoke:
              await h.packet(_nf4SessionCommand, {_nf4ReasonField: SendbirdError.accessTokenRevoked});
              break;
            case _Nf7Event.differentConnect:
              nextConnect = connection.connect(_nf3OtherUser).then<void>((user) {
                nextResults.add(user);
                authenticated.add(connection.connectionSnapshot.authenticated);
                opened.add(connection.webSocketClient.isConnected());
              }, onError: (Object e) { nextFailures.add(e); });
              await _flush(tester);
              await h.packet(_loginCommand, {..._loginPayload, _userIdField: _nf3OtherUser,
                _sessionKeyField: _nextSessionKey});
              break;
            case _Nf7Event.replaceTransport:
              recovery = connection.recoverTransport().then((result) {
                recoveryResults.add(result);
                if (result == TransportRecoveryResult.authenticated) {
                  authenticated.add(connection.connectionSnapshot.authenticated);
                  opened.add(connection.webSocketClient.isConnected());
                }
                return result;
              });
              await _flush(tester);
              await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
              break;
          }
          gate.complete();
          await _flush(tester);
          if ((stage == _Nf7Stage.correlatedSave || stage == _Nf7Stage.httpSave) &&
              event == _Nf7Event.correlatedLogin && (!completed || automatic)) {
            expect(results, isEmpty);
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            await _flush(tester);
          }
          if (refresh != null) await refresh;
          expect(refreshFailures, everyElement(isA<ConnectionCanceledException>()));
          if (nextConnect != null) {
            expect(nextResults, hasLength(_one));
            expect(nextFailures, isEmpty);
            expect(h.connectionHandler.connectedUsers.where((user) => user == _nf3OtherUser),
                [_nf3OtherUser]);
            await nextConnect;
          }
          if (recovery != null) {
            expect(recoveryResults, [TransportRecoveryResult.authenticated]);
            await recovery;
          }
          if (!completed) {
            expect(results.length + failures.length, _one);
            if (event == _Nf7Event.correlatedLogin || event == _Nf7Event.login) {
              expect(results, hasLength(_one));
              expect(failures, isEmpty);
            } else if (event == _Nf7Event.replaceTransport) {
              expect(failures, everyElement(isA<ConnectionCanceledException>()));
            } else {
              expect(failures, [isA<SendbirdException>()]);
              expect(results, isEmpty);
            }
            await connecting;
          }
          expect(authenticated, everyElement(isTrue));
          expect(opened, everyElement(isTrue));
          if (event == _Nf7Event.correlatedLogin) {
            expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
          }
          if (event == _Nf7Event.close || event == _Nf7Event.error) {
            await tester.pump(_nf3BusyWait);
            await tester.pump(_statSettlingTick);
            await _flush(tester);
            if (connection.reconnectNotificationPending) {
              await h.packet(_loginCommand, {..._loginPayload,
                _sessionKeyField: _nextSessionKey});
              await _flush(tester);
              _nf6ExpectAuthenticated(h);
            }
          }
          _nf7ExpectNotifications(h);
          connection.cancelReconnectTimers();
          await _flush(tester);
        });
      }
    }
  }
  testWidgets('NF7-A3 real DB getLogin stale account keeps READ', (tester) async {
    final h = _Nf5Harness(tester);
    final chat = h.fixture.chat;
    final trace = audit.Trace(_appId, _userId, FakeAsync());
    final isar = _Nf7Isar(trace);
    final db = _Nf7DBManager(chat, trace, isar);
    chat.dbManager = db;
    chat.collectionManager = CollectionManager(chat: chat);
    final failures = <Object>[];
    final old = h.fixture.connection.connect(_userId).then<void>((_) {},
        onError: (Object e) { failures.add(e); });
    await _flush(tester);
    final gate = Completer<void>();
    db.actual.gate = gate;
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nf2StaleKey});
    await _flush(tester);
    expect(db.actual.entered, isTrue);
    final latest = h.fixture.connection.connect(_nf3OtherUser);
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload, _userIdField: _nf3OtherUser,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect((await latest).userId, _nf3OtherUser);
    final channel = GroupChannel.fromJson(audit.channelJson(audit.A.warmRoom))..set(chat);
    await db.upsertGroupChannels([channel]);
    chat.channelCache.insert(channelKey: channel.channelUrl, data: channel);
    await h.packet(CommandString.read, {...audit.readPayload(_two),
      audit.A.channelUrl: audit.A.warmRoom});
    await tester.pump(audit.A.local);
    gate.complete();
    await _flush(tester);
    await old;
    expect(failures, [isA<ConnectionCanceledException>()]);
    final restored = await DB(chat: Chat(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false)), isar: isar)
        .getGroupChannel(audit.A.warmRoom);
    expect(restored, isNotNull);
    expect(restored!.getCachedReadStatus(audit.A.warmRoom)[audit.A.peer], _two);
    expect(isar.logins.keys, [_nf3OtherUser]);
    _nf7ExpectNotifications(h);
  });
  for (final failRequester in _hookModes) {
    testWidgets('NF7-A4 auth rejection closes reconnect failRequester=$failRequester', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      h.fixture.sockets.last.closed();
      await tester.pump(_legacyReconnectDelay);
      await _flush(tester);
      expect(h.fixture.connection.reconnectNotificationPending, isTrue);
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.accessTokenNotValid});
      await _flush(tester);
      if (failRequester) await h.handler.requester!.onFail();
      _nf7ExpectNotifications(h);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectSucceeded,
        _nf5ReconnectStarted, _nf5ReconnectFailed]);
      final latest = h.fixture.connection.connect(_userId);
      await _flush(tester);
      await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      expect((await latest).userId, _userId);
      _nf6ExpectAuthenticated(h);
      expect(h.connectionHandler.events.last, _nf5Connected);
      _nf7ExpectNotifications(h);
    });
  }
}


enum _Nf7DBStage {
  getLogin, clearQueue, clearTransaction, clearReturn, userTransaction, userReturn,
  loginTransaction, loginReturn,
}
const _nf7LoginTransaction = 3;

void _registerNf7DatabaseMatrix() {
  testWidgets('NF7-DB immutable login snapshot survives shared context mutation', (tester) async {
    final h = _Nf5Harness(tester);
    final chat = h.fixture.chat;
    final trace = audit.Trace(_appId, _userId, FakeAsync());
    final isar = _Nf7Isar(trace);
    final db = _Nf7DBManager(chat, trace, isar);
    chat.dbManager = db;
    final connecting = h.fixture.connection.connect(_userId);
    await _flush(tester);
    final gate = Completer<void>();
    db.actual.gate = gate;
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey,
      _nf6ApplicationAttributes: [_chatService]});
    await _flush(tester);
    expect(db.actual.entered, isTrue);
    chat.chatContext.services.clear();
    chat.chatContext.lastConnectedAt = _two;
    chat.chatContext.appInfo!.attributesInUse.add(_nextNickname);
    chat.chatContext.currentUser!.nickname = _nextNickname;
    gate.complete();
    await _flush(tester);
    expect((await connecting).userId, _userId);
    final restored = await db.actual.getLogin(_userId);
    expect(restored!.services, [Service.chat]);
    expect(restored.lastConnectedAt, _one);
    expect(restored.appInfo!.attributesInUse, [_chatService]);
    expect((await db.actual.getUser(_userId))!.nickname, _userId);
    _nf6ExpectAuthenticated(h);
    _nf7ExpectNotifications(h);
  });
  for (final stage in _Nf7DBStage.values) {
    for (final differentAccount in _hookModes) {
      for (final completed in _hookModes) {
        testWidgets('NF7-DB ${stage.name} differentAccount=$differentAccount completed=$completed', (tester) async {
          final h = _Nf5Harness(tester);
          final chat = h.fixture.chat;
          final connection = h.fixture.connection;
          if (completed) await _nf7CompletePublicLogin(h, tester);
          final trace = audit.Trace(_appId, _userId, FakeAsync());
          final isar = _Nf7Isar(trace);
          final db = _Nf7DBManager(chat, trace, isar);
          chat.dbManager = db;
          chat.collectionManager = CollectionManager(chat: chat);
          final failures = <Object>[];
          final results = <User>[];
          final authenticated = <bool>[];
          final opened = <bool>[];
          Future<void>? first;
          if (!completed) {
            first = connection.connect(_userId).then<void>((user) {
              results.add(user);
              authenticated.add(connection.connectionSnapshot.authenticated);
              opened.add(connection.webSocketClient.isConnected());
            }, onError: (Object e) { failures.add(e); });
            await _flush(tester);
          }
          final gate = Completer<void>();
          switch (stage) {
            case _Nf7DBStage.getLogin:
              db.actual.gate = gate;
              break;
            case _Nf7DBStage.clearQueue:
            case _Nf7DBStage.clearTransaction:
            case _Nf7DBStage.clearReturn:
              isar.gateAt = isar.transactions + _one;
              break;
            case _Nf7DBStage.userTransaction:
            case _Nf7DBStage.userReturn:
              isar.gateAt = isar.transactions + _two;
              break;
            case _Nf7DBStage.loginTransaction:
            case _Nf7DBStage.loginReturn:
              isar.gateAt = isar.transactions + _nf7LoginTransaction;
              break;
          }
          isar.transactionGate = gate;
          isar.afterTransaction = stage == _Nf7DBStage.clearReturn ||
              stage == _Nf7DBStage.userReturn || stage == _Nf7DBStage.loginReturn;
          Future<void>? queuedClear;
          if (stage == _Nf7DBStage.clearQueue) {
            queuedClear = db.actual.clear();
            await _flush(tester);
          }
          final clearsBeforeLogin = db.actual.clearCalls;
          await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nf2StaleKey});
          await _flush(tester);
          if (stage == _Nf7DBStage.clearQueue) {
            expect(db.actual.clearCalls, clearsBeforeLogin + _one);
          }
          expect(stage == _Nf7DBStage.getLogin ? db.actual.entered : isar.transactionEntered, isTrue);
          final userId = differentAccount ? _nf3OtherUser : _userId;
          Future<void>? latest;
          final latestResults = <User>[];
          final latestFailures = <Object>[];
          if (differentAccount) {
            latest = connection.connect(userId).then<void>((user) {
              latestResults.add(user);
              authenticated.add(connection.connectionSnapshot.authenticated);
              opened.add(connection.webSocketClient.isConnected());
            }, onError: (Object e) { latestFailures.add(e); });
            await _flush(tester);
          }
          final serialClear = stage == _Nf7DBStage.clearQueue ||
              stage == _Nf7DBStage.clearTransaction ||
              stage == _Nf7DBStage.clearReturn;
          if (serialClear) {
            if (!differentAccount) {
              await h.packet(_loginCommand, {..._loginPayload,
                _sessionKeyField: _nextSessionKey, _loginTsField: _two});
              await _flush(tester);
            }
            gate.complete();
            await _flush(tester);
            if (queuedClear != null) await queuedClear;
          }
          if (differentAccount || !serialClear) {
            await h.packet(_loginCommand, {..._loginPayload, _userIdField: userId,
              _sessionKeyField: _nextSessionKey, _loginTsField: _two});
            await _flush(tester);
          }
          if (latest != null) {
            expect(latestResults.map((user) => user.userId), [userId]);
            expect(latestFailures, isEmpty);
            await latest;
          }
          final channel = GroupChannel.fromJson(audit.channelJson(audit.A.warmRoom))..set(chat);
          await db.upsertGroupChannels([channel]);
          chat.channelCache.insert(channelKey: channel.channelUrl, data: channel);
          await h.packet(CommandString.read, {...audit.readPayload(_two),
            audit.A.channelUrl: audit.A.warmRoom});
          await tester.pump(audit.A.local);
          final rowsBeforeRelease = isar.savedLogins.length;
          if (!serialClear) gate.complete();
          await _flush(tester);
          if (!completed) {
            expect(results.length + failures.length, _one);
            expect(failures, differentAccount ? [isA<ConnectionCanceledException>()] : isEmpty);
            await first;
          }
          expect(authenticated, everyElement(isTrue));
          expect(opened, everyElement(isTrue));
          expect(isar.savedLogins.length, rowsBeforeRelease);
          final restoredDb = DB(chat: Chat(appId: _appId,
              options: SendbirdChatOptions(useCollectionCaching: false)), isar: isar);
          final restored = await restoredDb.getGroupChannel(audit.A.warmRoom);
          expect(restored, isNotNull);
          expect(restored!.getCachedReadStatus(audit.A.warmRoom)[audit.A.peer], _two);
          final restoredLogin = await restoredDb.getLogin(userId);
          expect(restoredLogin!.lastConnectedAt, _two);
          expect(restoredLogin.services, [Service.chat]);
          expect(chat.dbManager, same(db));
          _nf6ExpectAuthenticated(h);
          _nf7ExpectNotifications(h);
        });
      }
    }
  }
}

void _registerNf8Tests() {
  for (final sameUser in _hookModes) {
    testWidgets('NF8-A1 public connect during parameters sameUser=$sameUser', (tester) async {
      final h = _Nf5Harness(tester);
      final connection = h.fixture.connection;
      connection.changeState(DisconnectedState(chat: h.fixture.chat));
      final initialResults = <User>[];
      final initialFailures = <Object>[];
      connection.connect(_userId).then<void>(initialResults.add,
          onError: (Object e) { initialFailures.add(e); });
      final initialLogin = h.fixture.chat.chatContext.loginCompleter!;
      final latestResults = <User>[];
      final latestFailures = <Object>[];
      final latestUser = sameUser ? _userId : _nf3OtherUser;
      connection.connect(latestUser).then<void>(latestResults.add,
          onError: (Object e) { latestFailures.add(e); });
      await _flush(tester);
      if (!sameUser) {
        expect(initialLogin.isCompleted, isTrue);
        expect(initialFailures, [isA<ConnectionCanceledException>()]);
      }
      await h.packet(_loginCommand, {..._loginPayload, _userIdField: latestUser,
        _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      expect(latestResults.map((user) => user.userId), [latestUser]);
      expect(latestFailures, isEmpty);
      expect(initialResults.map((user) => user.userId), sameUser ? [_userId] : isEmpty);
      expect(initialLogin.isCompleted, isTrue);
      _nf6ExpectAuthenticated(h);
      _nf7ExpectNotifications(h);
    });
  }
  testWidgets('NF8-A1 final disconnected callback public connect owns login', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf7CompletePublicLogin(h, tester);
    final connection = h.fixture.connection;
    final latestResults = <User>[];
    final latestFailures = <Object>[];
    final oldResults = <User>[];
    final oldFailures = <Object>[];
    Completer<User>? latestLogin;
    h.connectionHandler.disconnected = (userId) {
      h.connectionHandler.disconnected = null;
      connection.connect(_userId).then<void>(latestResults.add,
          onError: (Object e) { latestFailures.add(e); });
      latestLogin = h.fixture.chat.chatContext.loginCompleter;
    };
    connection.connect(_nf3OtherUser).then<void>(oldResults.add,
        onError: (Object e) { oldFailures.add(e); });
    await _flush(tester);
    expect(latestLogin, isNotNull);
    expect(h.fixture.chat.chatContext.loginCompleter, same(latestLogin));
    expect(h.fixture.chat.chatContext.currentUserId, _userId);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(latestResults.map((user) => user.userId), [_userId]);
    expect(latestFailures, isEmpty);
    expect(oldResults, isEmpty);
    expect(oldFailures, [isA<ConnectionCanceledException>()]);
    expect(latestLogin!.isCompleted, isTrue);
    _nf6ExpectAuthenticated(h);
    _nf7ExpectNotifications(h);
  });

  testWidgets('NF8-A2 authenticated socket reuse without another LOGI ends notification', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf7CompletePublicLogin(h, tester);
    final connection = h.fixture.connection;
    h.fixture.sockets.last.closed();
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    final snapshot = connection.connectionSnapshot;
    final starts = h.fixture.starts;
    await connection.reconnect(reset: true);
    await _flush(tester);
    expect(h.fixture.starts, starts);
    expect(connection.connectionSnapshot.key, same(snapshot.key));
    _nf6ExpectAuthenticated(h);
    _nf7ExpectNotifications(h);
    expect(h.connectionHandler.events, [_nf5Connected,
      _nf5ReconnectStarted, _nf5ReconnectSucceeded,
      _nf5ReconnectStarted, _nf5ReconnectSucceeded]);
  });

  for (final background in _hookModes) {
    testWidgets('NF8-A3 automatic loginDispatcher interruption background=$background', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf7CompletePublicLogin(h, tester);
      final connection = h.fixture.connection;
      h.fixture.sockets.last.closed();
      await tester.pump(_legacyReconnectDelay);
      await _flush(tester);
      final gate = Completer<void>();
      h.fixture.dispatcher.barrier = gate;
      await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      expect(connection.isConnected(), isTrue);
      if (background) {
        h.fixture.chat.isBackground = true;
        await connection.enterBackground();
      } else {
        await connection.disconnect(logout: false);
      }
      gate.complete();
      await _flush(tester);
      expect(connection.webSocketClient.isConnected(), isFalse);
      _nf7ExpectNotifications(h);
      expect(h.connectionHandler.connectedUsers, [_userId]);
      connection.cancelReconnectTimers();
    });
  }

  for (final stage in _Nf5ClearStage.values) {
    for (final completed in _hookModes) {
    for (final sameUser in _hookModes) {
    testWidgets('NF8-clear final callback reentry await=${stage.name} completed=$completed sameUser=$sameUser', (tester) async {
      final h = _Nf5Harness(tester);
      if (completed) await _nf7CompletePublicLogin(h, tester);
      final connection = h.fixture.connection;
      final initialResults = <User>[];
      final initialFailures = <Object>[];
      if (!completed) {
        connection.connect(_userId).then<void>(initialResults.add,
            onError: (Object e) { initialFailures.add(e); });
        await _flush(tester);
      }
      final chat = h.fixture.chat;
      final close = Completer<bool>();
      final collections = _Nf5Collections(chat);
      final dispatcher = _Nf5LogoutDispatcher(chat);
      final db = _Nf5ClearDB();
      final tokens = _Nf5ClearTokens();
      final prefs = _Nf5Preferences();
      final previousPrefs = SharedPreferencesStorePlatform.instance;
      switch (stage) {
        case _Nf5ClearStage.close:
          h.fixture.sockets.last.closeBarrier = close;
          break;
        case _Nf5ClearStage.checkpoints:
          chat.collectionManager = collections;
          break;
        case _Nf5ClearStage.logout:
          chat.eventDispatcher = dispatcher;
          break;
        case _Nf5ClearStage.database:
          chat.dbManager = db;
          break;
        case _Nf5ClearStage.device:
          chat.deviceTokenManager = tokens;
          break;
        case _Nf5ClearStage.retention:
          SharedPreferencesStorePlatform.instance = prefs;
          addTearDown(() { SharedPreferencesStorePlatform.instance = previousPrefs; });
          break;
      }
      final nextUser = sameUser ? _userId : _nf3OtherUser;
      final results = <User>[];
      final failures = <Object>[];
      h.connectionHandler.disconnected = (userId) {
        h.connectionHandler.disconnected = null;
        connection.connect(nextUser).then<void>(results.add,
            onError: (Object e) { failures.add(e); });
      };
      final clearing = connection.doDisconnect(clear: true, logout: true);
      await _flush(tester);
      expect(results, isEmpty);
      expect(h.connectionHandler.events, completed ? [_nf5Connected] : isEmpty);
      close.complete(true);
      collections.gate.complete();
      dispatcher.gate.complete();
      db.gate.complete();
      tokens.gate.complete();
      prefs.gate.complete();
      await clearing;
      await _flush(tester);
      await h.packet(_loginCommand, {..._loginPayload, _userIdField: nextUser,
        _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      expect(results.map((user) => user.userId), [nextUser]);
      expect(failures, isEmpty);
      _nf6ExpectAuthenticated(h);
      _nf7ExpectNotifications(h);
      expect(h.connectionHandler.connectedUsers, [if (completed) _userId, nextUser]);
      expect(initialResults, isEmpty);
      expect(initialFailures, completed ? isEmpty : [isA<ConnectionCanceledException>()]);
    });
  }
    }
    }
}

enum _Nf9Context { publicConnect, automatic, recovery, clear }
const _nf9Callbacks = [_nf5Connected, _nf5ReconnectStarted,
  _nf5ReconnectSucceeded, _nf5ReconnectFailed, _nf5Disconnected];
const _nf9PublicNotApplicable = 'Public login completes or replaces a user; reconnect callbacks require a reconnect';
const _nf9ReconnectNotApplicable = 'Transport reconnect retains the user; terminal logout is covered by clear';
const _nf9ClearNotApplicable = 'Clear terminates a reconnect or disconnects; it cannot authenticate';

String? _nf9NotApplicable(_Nf9Context context, String callback) {
  switch (context) {
    case _Nf9Context.publicConnect:
      return callback == _nf5Connected || callback == _nf5Disconnected ? null :
          _nf9PublicNotApplicable;
    case _Nf9Context.automatic:
    case _Nf9Context.recovery:
      return callback == _nf5Connected || callback == _nf5Disconnected ?
          _nf9ReconnectNotApplicable : null;
    case _Nf9Context.clear:
      return callback == _nf5Disconnected || callback == _nf5ReconnectFailed ?
          null : _nf9ClearNotApplicable;
  }
}

void _registerNf9Tests() {
  _registerNf10Tests();
  _registerNf9DatabaseMatrix();
  for (final context in _Nf9Context.values) {
    for (final callback in _nf9Callbacks) {
      for (final sameUser in _hookModes) {
        testWidgets('NF9-callback ${context.name}/$callback sameUser=$sameUser', (tester) async {
          final h = _Nf5Harness(tester);
          final connection = h.fixture.connection;
          final chat = h.fixture.chat;
          final initialResults = <User>[];
          final initialFailures = <Object>[];
          final oldResults = <User>[];
          final oldFailures = <Object>[];
          final results = <User>[];
          final failures = <Object>[];
          final authenticated = <bool>[];
          final pending = <Future<void>>[];
          final logins = <Completer<User>>[];
          final recoveries = <TransportRecoveryResult>[];
          final latestUser = sameUser ? _userId : _nf3OtherUser;
          var calls = _none;
          var previousStarts = _none;
          OnWebSocketData? staleData;
          void connect(String userId, List<User> successes, List<Object> errors) {
            pending.add(connection.connect(userId).then<void>((user) {
              successes.add(user);
              authenticated.add(connection.hasAuthenticatedTransport);
            }, onError: (Object error) { errors.add(error); }));
            final login = chat.chatContext.loginCompleter;
            if (login != null) logins.add(login);
          }
          if (context != _Nf9Context.publicConnect || callback == _nf5Disconnected) {
            await _nf7CompletePublicLogin(h, tester);
          }
          h.connectionHandler.callback = (event) {
            if (event != callback) return;
            h.connectionHandler.callback = null;
            calls++;
            previousStarts = h.fixture.starts;
            staleData = h.fixture.sockets.last.data;
            connect(latestUser, results, failures);
          };
          if (context == _Nf9Context.publicConnect) {
            if (callback == _nf5Disconnected) {
              connect(_nf3OtherUser, oldResults, oldFailures);
            } else {
              connect(_userId, initialResults, initialFailures);
              await _flush(tester);
              await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            }
          } else if (context == _Nf9Context.automatic) {
            h.fixture.sockets.last.closed();
            await tester.pump(_legacyReconnectDelay);
            await _flush(tester);
            if (callback == _nf5ReconnectSucceeded) {
              await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            } else if (callback == _nf5ReconnectFailed) {
              connect(_userId, oldResults, oldFailures);
            }
          } else if (context == _Nf9Context.recovery || callback == _nf5ReconnectFailed) {
            pending.add(connection.recoverTransport().then<void>(recoveries.add));
            await _flush(tester);
            if (context == _Nf9Context.clear) {
              pending.add(connection.doDisconnect(clear: true, logout: true));
            } else if (callback == _nf5ReconnectSucceeded) {
              await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            } else if (callback == _nf5ReconnectFailed) {
              connect(_userId, oldResults, oldFailures);
            }
          } else {
            pending.add(connection.doDisconnect(clear: true, logout: true));
          }
          await _flush(tester);
          expect(calls, _one);
          expect(failures, isEmpty);
          expect(chat.chatContext.currentUserId, latestUser);
          expect(connection.webSocketClient.isConnected(), isTrue);
          final latestLogin = chat.chatContext.loginCompleter;
          if (latestLogin != null) logins.add(latestLogin);
          if (results.isEmpty) {
            await h.packet(_loginCommand, {..._loginPayload, _userIdField: latestUser,
              _sessionKeyField: _nextSessionKey});
            await _flush(tester);
          }
          expect(results.map((user) => user.userId), [latestUser]);
          expect(failures, isEmpty);
          expect(authenticated, everyElement(isTrue));
          expect(logins.every((login) => login.isCompleted), isTrue);
          if (context == _Nf9Context.publicConnect && callback == _nf5Connected) {
            expect(initialResults.map((user) => user.userId), [_userId]);
            expect(initialFailures, isEmpty);
          }
          if (((context == _Nf9Context.recovery || context == _Nf9Context.automatic) &&
              callback == _nf5ReconnectFailed) ||
              (context == _Nf9Context.publicConnect && callback == _nf5Disconnected)) {
            expect(oldResults, isEmpty);
            expect(oldFailures, [isA<ConnectionCanceledException>()]);
          }
          if (context == _Nf9Context.recovery ||
              (context == _Nf9Context.clear && callback == _nf5ReconnectFailed)) {
            expect(recoveries, [callback == _nf5ReconnectSucceeded ?
              TransportRecoveryResult.authenticated : TransportRecoveryResult.cancelled]);
          }
          await Future.wait(pending);
          final reuse = sameUser &&
              (callback == _nf5Connected || callback == _nf5ReconnectSucceeded);
          expect(h.fixture.starts - previousStarts, reuse ? _none : _one);
          if (!reuse) {
            final activeKey = connection.connectionSnapshot.key;
            await staleData!('$_loginCommand${jsonEncode({..._loginPayload,
              _sessionKeyField: _nf2StaleKey})}');
            await _flush(tester);
            expect(connection.connectionSnapshot.key, same(activeKey));
            expect(chat.chatContext.currentUserId, latestUser);
            expect(chat.chatContext.sessionKey, _nextSessionKey);
            expect(calls, _one);
          }
          _nf6ExpectAuthenticated(h);
          _nf7ExpectNotifications(h);
          connection.cancelReconnectTimers();
        }, skip: _nf9NotApplicable(context, callback) != null);
      }
    }
  }
}

enum _Nf10Path { automatic, recovery, foreground }
enum _Nf10Failure { network, sessionExpired, invalidToken, httpToken }
enum _Nf10Terminal {
  logiRevoked, logiUnauthorized, exprRevoked, exprExpired,
  httpNetwork, requesterFail, requesterNull, requesterHttpReject,
}
const _nf10InitialAutomaticNotApplicable =
    'A pre-LOGI close has no currentUser and does not schedule automatic reconnect; foreground/recovery cover it';

String? _nf10NotApplicable(_Nf10Path path, bool authenticated) =>
    path == _Nf10Path.automatic && !authenticated ?
      _nf10InitialAutomaticNotApplicable : null;

Future<void> _nf10Prepare(_Nf5Harness h, WidgetTester tester,
    bool authenticated) async {
  final connection = h.fixture.connection;
  await connection.doDisconnect(clear: true, logout: true);
  final results = <User>[];
  final failures = <Object>[];
  final initial = connection.connect(_userId).then<void>(results.add,
      onError: (Object error) { failures.add(error); });
  final login = h.fixture.chat.chatContext.loginCompleter!;
  await _flush(tester);
  if (authenticated) {
    await h.packet(_loginCommand,
        {..._loginPayload, _sessionKeyField: _nextSessionKey});
  } else {
    h.fixture.sockets.last.closed();
  }
  await _flush(tester);
  expect(login.isCompleted, isTrue);
  await initial;
  expect(results.length, authenticated ? _one : _none);
  expect(failures, authenticated ? isEmpty : [isA<WebSocketFailedException>()]);
  if (!authenticated) {
    expect(h.fixture.chat.chatContext.currentUser, isNull);
    expect(h.fixture.chat.chatContext.sessionKey, isNull);
    expect(h.fixture.chat.chatContext.loginCompleter, isNull);
    expect(h.fixture.chat.chatContext.currentUserId, _userId);
  }
  h.connectionHandler.events.clear();
  h.connectionHandler.reconnectOwners.clear();
}

Future<void> _nf10Start(_Nf5Harness h, WidgetTester tester, _Nf10Path path,
    List<Future<void>> pending, List<TransportRecoveryResult> recoveries) async {
  switch (path) {
    case _Nf10Path.automatic:
      h.fixture.sockets.last.closed();
      await tester.pump(_legacyReconnectDelay);
      break;
    case _Nf10Path.recovery:
      pending.add(h.fixture.connection.recoverTransport().then<void>(recoveries.add));
      break;
    case _Nf10Path.foreground:
      if (h.fixture.chat.chatContext.currentUser != null) {
        await h.fixture.connection.doDisconnect(clear: false,
            timeForDelayedConnectingState:
                h.fixture.connection.now.millisecondsSinceEpoch,
            retryAfterForDelayedConnectingState: _none);
      }
      await h.fixture.connection.enterForeground();
      break;
  }
  await _flush(tester);
}

Future<void> _nf10ExerciseRequester(_Nf5Harness h, WidgetTester tester,
    String userId, bool success) async {
  final connection = h.fixture.connection;
  await h.packet(_loginCommand, {_errorField: true,
    _codeField: SendbirdError.accessTokenNotValid});
  await _flush(tester);
  expect(h.handler.events, [_nf2SessionRequired]);
  expect(connection.getConnectionAttempt().authRequired, isTrue);
  final requester = h.handler.requester!;
  final beforeRequests = h.api.requests;
  if (success) {
    final response = requester.onSuccess(_nextAccessToken);
    await _flush(tester);
    expect(h.api.requests, beforeRequests + _one);
    h.api.responses.last.complete({_sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await response;
    expect(h.handler.events, [_nf2SessionRequired, _nf2SessionRefreshed]);
    await h.packet(_loginCommand, {..._loginPayload,
      _userIdField: userId, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
  } else {
    await requester.onFail();
    expect(h.api.requests, beforeRequests);
    expect(h.handler.events, [_nf2SessionRequired, _nf2SessionError]);
    expect(connection.getConnectionAttempt().authRequired, isTrue);
    final results = <User>[];
    final authenticated = <bool>[];
    final reconnect = connection.connect(userId).then<void>((user) {
      results.add(user);
      authenticated.add(connection.hasAuthenticatedTransport);
    });
    final login = h.fixture.chat.chatContext.loginCompleter!;
    await _flush(tester);
    await h.packet(_loginCommand, {..._loginPayload,
      _userIdField: userId, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(login.isCompleted, isTrue);
    expect(results.map((user) => user.userId), [userId]);
    expect(authenticated, [true]);
    await reconnect;
  }
  final requests = h.api.requests;
  final key = connection.connectionSnapshot.key;
  await requester.onFail();
  await requester.onSuccess(_nextAccessToken);
  expect(h.handler.events.length, _two);
  expect(h.api.requests, requests);
  expect(connection.connectionSnapshot.key, same(key));
  expect(h.fixture.chat.chatContext.currentUserId, userId);
  expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
  _nf6ExpectAuthenticated(h);
  _nf7ExpectNotifications(h);
}

void _registerNf10Tests() {
  _registerNf11Tests();
  _registerNf10Terminals();
  for (final sameUser in _hookModes) {
    testWidgets('NF10-delayed-entry sameUser=$sameUser', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf10Prepare(h, tester, false);
      final connection = h.fixture.connection;
      final nextUser = sameUser ? _userId : _nf3OtherUser;
      final results = <User>[];
      final failures = <Object>[];
      final oldFailures = <Object>[];
      final pending = <Future<void>>[];
      final recoveries = <TransportRecoveryResult>[];
      h.connectionHandler.callback = (event) {
        if (event != _nf5ReconnectStarted) return;
        h.connectionHandler.callback = null;
        pending.add(connection.connect(nextUser).then<void>(results.add,
            onError: (Object error) { failures.add(error); }));
        final latestLogin = h.fixture.chat.chatContext.loginCompleter;
        pending.add(connection.doConnect(_userId, isDelayedConnecting: true)
            .then<void>((_) {},
                onError: (Object error) { oldFailures.add(error); }));
        expect(h.fixture.chat.chatContext.loginCompleter, same(latestLogin));
      };
      await _nf10Start(h, tester, _Nf10Path.foreground, pending, recoveries);
      expect(oldFailures, [isA<ConnectionCanceledException>()]);
      final login = h.fixture.chat.chatContext.loginCompleter!;
      await h.packet(_loginCommand, {..._loginPayload,
        _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      expect(results.map((user) => user.userId), [nextUser]);
      expect(failures, isEmpty);
      expect(login.isCompleted, isTrue);
      await Future.wait(pending);
      _nf6ExpectAuthenticated(h);
      _nf7ExpectNotifications(h);
    });
  }
  for (final path in _Nf10Path.values) {
    for (final authenticated in _hookModes) {
      for (final sameUser in _hookModes) {
        testWidgets('NF10-started ${path.name} authenticated=$authenticated sameUser=$sameUser', (tester) async {
          final h = _Nf5Harness(tester);
          await _nf10Prepare(h, tester, authenticated);
          final connection = h.fixture.connection;
          final nextUser = sameUser ? _userId : _nf3OtherUser;
          final pending = <Future<void>>[];
          final recoveries = <TransportRecoveryResult>[];
          final results = <User>[];
          final failures = <Object>[];
          final logins = <Completer<User>>[];
          final authenticatedReturns = <bool>[];
          var calls = _none;
          h.connectionHandler.callback = (event) {
            if (event != _nf5ReconnectStarted) return;
            h.connectionHandler.callback = null;
            calls++;
            pending.add(connection.connect(nextUser).then<void>((user) {
              results.add(user);
              authenticatedReturns.add(connection.hasAuthenticatedTransport);
            }, onError: (Object error) { failures.add(error); }));
            final login = h.fixture.chat.chatContext.loginCompleter;
            if (login != null) logins.add(login);
          };
          await _nf10Start(h, tester, path, pending, recoveries);
          expect(calls, _one);
          final login = h.fixture.chat.chatContext.loginCompleter;
          if (login != null) logins.add(login);
          await h.packet(_loginCommand, {..._loginPayload,
            _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect(results.map((user) => user.userId), [nextUser]);
          expect(failures, isEmpty);
          expect(authenticatedReturns, [true]);
          expect(logins, isNotEmpty);
          expect(logins.every((login) => login.isCompleted), isTrue);
          expect(h.handler.events, isEmpty);
          expect(h.handler.requester, isNull);
          if (path == _Nf10Path.recovery) {
            expect(recoveries, [TransportRecoveryResult.cancelled]);
          }
          await Future.wait(pending);
          _nf6ExpectAuthenticated(h);
          _nf7ExpectNotifications(h);
        }, skip: _nf10NotApplicable(path, authenticated) != null);
      }
    }
  }

  for (final path in _Nf10Path.values) {
    for (final authenticated in _hookModes) {
      for (final cause in _Nf10Failure.values) {
        for (final sameUser in _hookModes) {
          for (final success in _hookModes) {
            testWidgets('NF10-failed ${path.name}/${cause.name} authenticated=$authenticated sameUser=$sameUser success=$success', (tester) async {
              final h = _Nf5Harness(tester);
              await _nf10Prepare(h, tester, authenticated);
              final connection = h.fixture.connection;
              final nextUser = sameUser ? _userId : _nf3OtherUser;
              final pending = <Future<void>>[];
              final recoveries = <TransportRecoveryResult>[];
              final results = <User>[];
              final failures = <Object>[];
              final authenticatedReturns = <bool>[];
              final oldFailures = <Object>[];
              final refreshFailures = <Object>[];
              final refreshResults = <bool>[];
              final logins = <Completer<User>>[];
              await _nf10Start(h, tester, path, pending, recoveries);
              expect(h.connectionHandler.events, [_nf5ReconnectStarted]);
              final previousLogin = h.fixture.chat.chatContext.loginCompleter;
              if (previousLogin != null) logins.add(previousLogin);
              final staleData = h.fixture.sockets.last.data;
              var calls = _none;
              h.connectionHandler.callback = (event) {
                if (event != _nf5ReconnectFailed) return;
                h.connectionHandler.callback = null;
                calls++;
                pending.add(connection.connect(nextUser).then<void>((user) {
                  results.add(user);
                  authenticatedReturns.add(connection.hasAuthenticatedTransport);
                }, onError: (Object error) { failures.add(error); }));
                final login = h.fixture.chat.chatContext.loginCompleter;
                if (login != null) logins.add(login);
              };
              switch (cause) {
                case _Nf10Failure.network:
                  h.fixture.sockets.last.closed();
                  await _flush(tester);
                  pending.add(connection.connect(_userId).then<void>((_) {},
                      onError: (Object error) { oldFailures.add(error); }));
                  break;
                case _Nf10Failure.sessionExpired:
                case _Nf10Failure.invalidToken:
                  await h.packet(_loginCommand, {_errorField: true,
                    _codeField: cause == _Nf10Failure.sessionExpired ?
                      SendbirdError.sessionKeyExpired : SendbirdError.accessTokenNotValid});
                  if (cause == _Nf10Failure.sessionExpired) {
                    await _flush(tester);
                    expect(h.handler.events, isEmpty);
                    expect(calls, _none);
                    h.api.response.completeError(
                        SendbirdException(code: SendbirdError.accessTokenNotValid));
                  }
                  break;
                case _Nf10Failure.httpToken:
                  for (var index = _none; index < _two; index++) {
                    pending.add(h.sessions.updateSessionKey().then<void>((_) {
                      refreshResults.add(true);
                    }, onError: (Object error) { refreshFailures.add(error); }));
                  }
                  await _flush(tester);
                  expect(h.api.requests, _one);
                  h.api.response.completeError(
                      SendbirdException(code: SendbirdError.accessTokenNotValid));
                  break;
              }
              await _flush(tester);
              expect(calls, _one);
              final abandoned = h.handler.requester;
              if (abandoned != null) {
                if (success) {
                  final response = abandoned.onSuccess(_nextAccessToken);
                  await _flush(tester);
                  for (final request in h.api.responses) {
                    if (!request.isCompleted) request.complete({_sessionKeyField: _nf2StaleKey});
                  }
                  await _flush(tester);
                  await response;
                } else {
                  await abandoned.onFail();
                }
              }
              await _flush(tester);
              expect(h.handler.events, isEmpty);
              expect(h.handler.requester, isNull);
              expect(h.api.requests, cause == _Nf10Failure.httpToken ||
                  cause == _Nf10Failure.sessionExpired ? _one : _none);
              expect(failures, isEmpty);
              if (cause == _Nf10Failure.httpToken) {
                expect(refreshResults, isEmpty);
                expect(refreshFailures, [isA<ConnectionCanceledException>(),
                  isA<ConnectionCanceledException>()]);
              }
              final latestLogin = h.fixture.chat.chatContext.loginCompleter;
              if (latestLogin != null) logins.add(latestLogin);
              await h.packet(_loginCommand, {..._loginPayload,
                _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
              await _flush(tester);
              expect(results.map((user) => user.userId), [nextUser]);
              expect(authenticatedReturns, [true]);
              expect(failures, isEmpty);
              expect(logins.every((login) => login.isCompleted), isTrue);
              if (cause == _Nf10Failure.network) {
                expect(oldFailures, [isA<ConnectionCanceledException>()]);
              }
              if (path == _Nf10Path.recovery) {
                expect(recoveries, [cause == _Nf10Failure.network ?
                  TransportRecoveryResult.cancelled : TransportRecoveryResult.authRequired]);
              }
              await Future.wait(pending);
              final key = connection.connectionSnapshot.key;
              await staleData('$_loginCommand${jsonEncode({..._loginPayload,
                _sessionKeyField: _nf2StaleKey})}');
              await _flush(tester);
              expect(connection.connectionSnapshot.key, same(key));
              expect(h.fixture.chat.chatContext.currentUserId, nextUser);
              expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
              _nf6ExpectAuthenticated(h);
              _nf7ExpectNotifications(h);
              await _nf10ExerciseRequester(h, tester, nextUser, success);
            }, skip: _nf10NotApplicable(path, authenticated) != null);
          }
        }
      }
    }
  }
}

void _registerNf10Terminals() {
  for (final terminal in _Nf10Terminal.values) {
    for (final sameUser in _hookModes) {
      testWidgets('NF10-terminal ${terminal.name} sameUser=$sameUser', (tester) async {
        final h = _Nf5Harness(tester);
        await _nf10Prepare(h, tester, true);
        final connection = h.fixture.connection;
        final recovery = connection.recoverTransport();
        await _flush(tester);
        final nextUser = sameUser ? _userId : _nf3OtherUser;
        final results = <User>[];
        final failures = <Object>[];
        final authenticated = <bool>[];
        Future<void>? latest;
        h.connectionHandler.callback = (event) {
          if (event != _nf5ReconnectFailed) return;
          h.connectionHandler.callback = null;
          latest = connection.connect(nextUser).then<void>((user) {
            results.add(user);
            authenticated.add(connection.hasAuthenticatedTransport);
          }, onError: (Object error) { failures.add(error); });
        };
        final refreshFailures = <Object>[];
        Future<void>? refresh;
        Future<void>? response;
        AccessTokenRequester? requester;
        switch (terminal) {
          case _Nf10Terminal.logiRevoked:
          case _Nf10Terminal.logiUnauthorized:
            await h.packet(_loginCommand, {_errorField: true,
              _codeField: terminal == _Nf10Terminal.logiRevoked ?
                SendbirdError.accessTokenRevoked : SendbirdError.nonAuthorized});
            break;
          case _Nf10Terminal.exprRevoked:
          case _Nf10Terminal.exprExpired:
            await h.packet(_nf4SessionCommand, {
              if (terminal == _Nf10Terminal.exprRevoked)
                _nf4ReasonField: SendbirdError.accessTokenRevoked,
              if (terminal == _Nf10Terminal.exprExpired)
                _nf4ExpiresField: _nf4Expired,
            });
            break;
          case _Nf10Terminal.httpNetwork:
            refresh = h.sessions.updateSessionKey().then<void>((_) {},
                onError: (Object error) { refreshFailures.add(error); });
            await _flush(tester);
            h.api.response.completeError(NetworkErrorException());
            break;
          case _Nf10Terminal.requesterFail:
          case _Nf10Terminal.requesterNull:
          case _Nf10Terminal.requesterHttpReject:
            h.fixture.chat.eventManager.notifyAccessTokenRequired();
            expect(h.handler.events, [_nf2SessionRequired]);
            requester = h.handler.requester!;
            h.handler.events.clear();
            if (terminal == _Nf10Terminal.requesterFail) {
              response = requester.onFail();
            } else if (terminal == _Nf10Terminal.requesterNull) {
              response = requester.onSuccess(null);
            } else {
              response = requester.onSuccess(_nextAccessToken);
              await _flush(tester);
              h.api.response.completeError(
                  SendbirdException(code: SendbirdError.accessTokenNotValid));
            }
            break;
        }
        await _flush(tester);
        if (_u5TransientTerminal(terminal)) {
          expect(latest, isNull);
          await _u5CompleteTransient(h, tester);
          expect(await recovery, TransportRecoveryResult.authenticated);
        } else {
          expect(await recovery, TransportRecoveryResult.authRequired);
          expect(latest, isNotNull);
          expect(h.handler.events, isEmpty);
          expect(failures, isEmpty);
          final login = h.fixture.chat.chatContext.loginCompleter!;
          await h.packet(_loginCommand, {..._loginPayload,
            _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect(results.map((user) => user.userId), [nextUser]);
          expect(authenticated, [true]);
          expect(login.isCompleted, isTrue);
          await latest;
        }
        if (refresh != null) {
          await refresh;
          expect(refreshFailures, [isA<SessionKeyRefreshFailedException>()]);
        }
        if (response != null) await response;
        if (requester != null) {
          final requests = h.api.requests;
          await requester.onFail();
          await requester.onSuccess(_nextAccessToken);
          expect(h.api.requests, requests);
        }
        expect(h.handler.events, isEmpty);
        expect(failures, isEmpty);
        _nf6ExpectAuthenticated(h);
        _nf7ExpectNotifications(h);
      });
    }
  }
}

void _registerNf9DatabaseMatrix() {
  for (final stage in _Nf7DBStage.values) {
    for (final event in [_Nf7Event.close, _Nf7Event.error]) {
      for (final initial in _Nf7Initial.values) {
        for (final differentAccount in _hookModes) {
          testWidgets('NF9-DB ${stage.name}/${event.name} initial=${initial.name} differentAccount=$differentAccount', (tester) async {
            final h = _Nf5Harness(tester);
            final connection = h.fixture.connection;
            final chat = h.fixture.chat;
            if (initial != _Nf7Initial.pending) {
              await _nf7CompletePublicLogin(h, tester);
            }
            if (initial == _Nf7Initial.automatic) {
              h.fixture.sockets.last.closed();
              await tester.pump(_legacyReconnectDelay);
              await _flush(tester);
              expect(connection.reconnectNotificationPending, isTrue);
            }
            final trace = audit.Trace(_appId, _userId, FakeAsync());
            final isar = _Nf7Isar(trace);
            final db = _Nf7DBManager(chat, trace, isar);
            chat.dbManager = db;
            chat.collectionManager = CollectionManager(chat: chat);
            final results = <User>[];
            final failures = <Object>[];
            final authenticated = <bool>[];
            final pending = <Future<void>>[];
            Completer<User>? initialLogin;
            if (initial == _Nf7Initial.pending) {
              pending.add(connection.connect(_userId).then<void>(results.add,
                onError: (Object error) { failures.add(error); }));
              await _flush(tester);
              initialLogin = chat.chatContext.loginCompleter!;
            }
            final gate = Completer<void>();
            switch (stage) {
              case _Nf7DBStage.getLogin:
                db.actual.gate = gate;
                break;
              case _Nf7DBStage.clearQueue:
              case _Nf7DBStage.clearTransaction:
              case _Nf7DBStage.clearReturn:
                isar.gateAt = isar.transactions + _one;
                break;
              case _Nf7DBStage.userTransaction:
              case _Nf7DBStage.userReturn:
                isar.gateAt = isar.transactions + _two;
                break;
              case _Nf7DBStage.loginTransaction:
              case _Nf7DBStage.loginReturn:
                isar.gateAt = isar.transactions + _nf7LoginTransaction;
                break;
            }
            isar.transactionGate = gate;
            isar.afterTransaction = stage == _Nf7DBStage.clearReturn ||
                stage == _Nf7DBStage.userReturn || stage == _Nf7DBStage.loginReturn;
            if (stage == _Nf7DBStage.clearQueue) {
              pending.add(db.actual.clear());
              await _flush(tester);
            }
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nf2StaleKey});
            await _flush(tester);
            expect(stage == _Nf7DBStage.getLogin ? db.actual.entered : isar.transactionEntered, isTrue);
            final oldSocket = h.fixture.sockets.last;
            final oldData = oldSocket.data;
            if (event == _Nf7Event.close) {
              oldSocket.closed();
            } else {
              final failing = oldSocket.error(StateError(_pingFailure));
              await tester.pump(_statSettlingTick);
              await failing;
            }
            await _flush(tester);
            expect(connection.connectionSnapshot.authenticated, isFalse);
            if (initialLogin != null) {
              expect(initialLogin.isCompleted, isTrue);
              expect(results, isEmpty);
              expect(failures, [isA<WebSocketFailedException>()]);
            }
            final latestUser = differentAccount ? _nf3OtherUser : _userId;
            final latestResults = <User>[];
            final latestFailures = <Object>[];
            pending.add(connection.connect(latestUser).then<void>((user) {
              latestResults.add(user);
              authenticated.add(connection.hasAuthenticatedTransport);
            }, onError: (Object error) { latestFailures.add(error); }));
            await _flush(tester);
            final latestLogin = chat.chatContext.loginCompleter;
            final serialClear = stage == _Nf7DBStage.clearQueue ||
                stage == _Nf7DBStage.clearTransaction || stage == _Nf7DBStage.clearReturn;
            if (serialClear) {
              gate.complete();
              await _flush(tester);
            }
            await h.packet(_loginCommand, {..._loginPayload, _userIdField: latestUser,
              _sessionKeyField: _nextSessionKey, _loginTsField: _two});
            await _flush(tester);
            expect(latestFailures, isEmpty);
            expect(latestResults.map((user) => user.userId), [latestUser]);
            expect(authenticated, [true]);
            expect(latestLogin, isNotNull);
            expect(latestLogin!.isCompleted, isTrue);
            final channel = GroupChannel.fromJson(audit.channelJson(audit.A.warmRoom))..set(chat);
            await db.upsertGroupChannels([channel]);
            chat.channelCache.insert(channelKey: channel.channelUrl, data: channel);
            await h.packet(CommandString.read, {...audit.readPayload(_two),
              audit.A.channelUrl: audit.A.warmRoom});
            await tester.pump(audit.A.local);
            final rowsBeforeRelease = isar.savedLogins.length;
            if (!serialClear) gate.complete();
            await _flush(tester);
            expect(isar.savedLogins.length, rowsBeforeRelease);
            final activeSocket = connection.socketIdentity;
            await oldData('$_loginCommand${jsonEncode({..._loginPayload,
              _sessionKeyField: _nf2StaleKey})}');
            await _flush(tester);
            expect(connection.socketIdentity, same(activeSocket));
            expect(chat.chatContext.currentUserId, latestUser);
            expect(chat.chatContext.sessionKey, _nextSessionKey);
            expect(isar.savedLogins.length, rowsBeforeRelease);
            final restoredDb = DB(chat: Chat(appId: _appId,
              options: SendbirdChatOptions(useCollectionCaching: false)), isar: isar);
            final restoredLogin = await restoredDb.getLogin(latestUser);
            expect(restoredLogin!.lastConnectedAt, _two);
            final restored = await restoredDb.getGroupChannel(audit.A.warmRoom);
            expect(restored!.getCachedReadStatus(audit.A.warmRoom)[audit.A.peer], _two);
            await Future.wait(pending);
            _nf6ExpectAuthenticated(h);
            _nf7ExpectNotifications(h);
            connection.cancelReconnectTimers();
          });
        }
      }
    }
  }
}

enum _Nf11JoinTime { beforeLogin, parameters, socketStarted }
const _nf11JoinLabel = 'NF11-join';
const _nf11PreparingLabel = 'NF11-preparing-without-login';
const _nf11TerminalLabel = 'NF11-terminal';
const _nf11ExhaustedLabel = 'NF11-exhausted';
const _nf11NoLogin =
    'Normal reconnect and recovery use _reconnect without creating a login completer';

String? _nf11NotApplicable(_Nf10Path path, bool authenticated,
    _Nf11JoinTime time) => _nf10NotApplicable(path, authenticated) ??
    (time == _Nf11JoinTime.parameters && path != _Nf10Path.foreground
        ? _nf11NoLogin : null);

void _registerNf11Tests() {
  _registerNf12Tests();
  _registerNf11JoinTests();
  _registerNf11JoinTests(withoutLogin: true);
  _registerNf11Terminals();
  _registerNf11Exhaustion();
}

const _nf12TerminalLabel = 'NF12-unauthenticated-foreground-terminal';
const _nf12NetworkTerminals = [_Nf5Event.close, _Nf5Event.error];

void _registerNf12Tests() {
  for (final terminal in _nf12NetworkTerminals) {
    testWidgets('$_nf12TerminalLabel ${terminal.name}', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf10Prepare(h, tester, false);
      final connection = h.fixture.connection;
      final context = h.fixture.chat.chatContext;
      final starts = h.fixture.starts;
      final pending = <Future<void>>[];
      final recoveries = <TransportRecoveryResult>[];
      await _nf10Start(h, tester, _Nf10Path.foreground, pending, recoveries);
      expect(connection.isReconnecting(), isTrue);
      expect(connection.hasAuthenticatedTransport, isFalse);
      expect(context.currentUser, isNull);
      expect(context.currentUserId, _userId);
      expect(h.fixture.starts, starts + _one);
      expect(h.fixture.sockets.last.isConnected(), isTrue);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted]);
      expect(connection.reconnectNotificationPending, isTrue);
      final deadline = connection.getConnectionAttempt().deadline!;
      final login = context.loginCompleter!;
      expect(login.isCompleted, isFalse);
      final results = <User>[];
      final failures = <Object>[];
      pending.add(login.future.then<void>(results.add,
          onError: (Object error) { failures.add(error); }));
      final socket = h.fixture.sockets.last;
      if (terminal == _Nf5Event.close) {
        socket.closed();
      } else {
        socket.connected = false;
        socket.error(NetworkErrorException());
      }
      await _flush(tester);
      expect(login.isCompleted, isTrue);
      await Future.wait(pending);
      expect(results, isEmpty);
      expect(failures, [isA<WebSocketFailedException>()]);
      expect(context.loginCompleter, isNull);
      await tester.pump(deadline.difference(connection.now) + _legacyReconnectDelay);
      await _flush(tester);
      expect(connection.now.isAfter(deadline), isTrue);
      expect(h.fixture.starts, starts + _one);
      expect(context.currentUser, isNull);
      expect(context.currentUserId, _userId);
      expect(connection.hasAuthenticatedTransport, isFalse);
      expect(h.connectionHandler.events,
          [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      expect(connection.isDisconnected(), isTrue);
      expect(connection.getConnectionAttempt().attemptId, isNull);
      expect(connection.getConnectionAttempt().retryAt, isNull);
      expect(h.handler.events, isEmpty);
      expect(h.handler.requester, isNull);
      _nf7ExpectNotifications(h);
      socket.closed();
      socket.error(NetworkErrorException());
      await tester.pump(context.options.reconnectAttemptDeadline + _legacyReconnectDelay);
      await _flush(tester);
      expect(h.connectionHandler.events,
          [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      expect(connection.isDisconnected(), isTrue);
      expect(h.fixture.starts, starts + _one);
      _nf7ExpectNotifications(h);
    });
  }
}

void _registerNf11JoinTests({bool withoutLogin = false}) {
  for (final path in _Nf10Path.values) {
    for (final authenticated in _hookModes) {
      for (final time in _Nf11JoinTime.values) {
        for (final sameUser in _hookModes) {
          if (withoutLogin && (time != _Nf11JoinTime.parameters ||
              path == _Nf10Path.foreground ||
              _nf10NotApplicable(path, authenticated) != null)) continue;
          final label = withoutLogin ? _nf11PreparingLabel : _nf11JoinLabel;
          testWidgets('$label ${path.name}/${time.name} authenticated=$authenticated sameUser=$sameUser', (tester) async {
            final h = _Nf5Harness(tester);
            await _nf10Prepare(h, tester, authenticated);
            final connection = h.fixture.connection;
            final context = h.fixture.chat.chatContext;
            final nextUser = sameUser ? _userId : _nf3OtherUser;
            final pending = <Future<void>>[];
            final recoveries = <TransportRecoveryResult>[];
            final results = <User>[];
            final failures = <Object>[];
            final previousResults = <User>[];
            final previousFailures = <Object>[];
            final authenticatedReturns = <bool>[];
            final logins = <Completer<User>>[];
            final starts = h.fixture.starts;
            final staleData = h.fixture.sockets.last.data;
            var calls = _none;
            Completer<User>? previousLogin;
            void connectLatest() {
              calls++;
              expectSync(connection.isReconnecting(), isTrue);
              expectSync(connection.hasAuthenticatedTransport, isFalse);
              previousLogin = context.loginCompleter;
              if (time == _Nf11JoinTime.beforeLogin) {
                expectSync(previousLogin, isNull);
              } else if (path == _Nf10Path.foreground) {
                expectSync(previousLogin, isNotNull);
                expectSync(previousLogin!.isCompleted, isFalse);
              } else {
                expectSync(previousLogin, isNull);
              }
              expectSync(h.fixture.starts, time == _Nf11JoinTime.socketStarted
                  ? starts + _one : starts);
              final previous = previousLogin;
              if (previous != null) {
                logins.add(previous);
                pending.add(previous.future.then<void>(previousResults.add,
                    onError: (Object error) { previousFailures.add(error); }));
              }
              pending.add(connection.connect(nextUser).then<void>((user) {
                results.add(user);
                authenticatedReturns.add(connection.hasAuthenticatedTransport);
              }, onError: (Object error) { failures.add(error); }));
              if (sameUser && path == _Nf10Path.foreground && previous != null) {
                expectSync(context.loginCompleter, same(previous));
              }
            }
            if (time != _Nf11JoinTime.socketStarted) {
              h.connectionHandler.callback = (event) {
                if (event != _nf5ReconnectStarted) return;
                h.connectionHandler.callback = null;
                if (time == _Nf11JoinTime.parameters) {
                  scheduleMicrotask(connectLatest);
                } else {
                  connectLatest();
                }
              };
            }
            await _nf10Start(h, tester, path, pending, recoveries);
            if (time == _Nf11JoinTime.socketStarted) {
              connectLatest();
              await _flush(tester);
            }
            expect(calls, _one);
            expect(failures, isEmpty);
            expect(results, isEmpty);
            final login = context.loginCompleter;
            expect(login, isNotNull);
            expect(login!.isCompleted, isFalse);
            logins.add(login);
            expect(connection.hasAuthenticatedTransport, isFalse);
            expect(h.fixture.sockets.last.isConnected(), isTrue);
            expect(Uri.parse(h.fixture.sockets.last._url!).queryParameters[_userIdField], nextUser);
            await h.packet(_loginCommand, {..._loginPayload,
              _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
            await _flush(tester);
            expect(results.map((user) => user.userId), [nextUser]);
            expect(failures, isEmpty);
            expect(authenticatedReturns, [true]);
            expect(logins.every((login) => login.isCompleted), isTrue);
            if (previousLogin != null) {
              expect(previousResults.map((user) => user.userId),
                  sameUser ? [nextUser] : isEmpty);
              expect(previousFailures, sameUser ? isEmpty : [isA<ConnectionCanceledException>()]);
            }
            if (path == _Nf10Path.recovery) {
              expect(recoveries, [TransportRecoveryResult.cancelled]);
            }
            await Future.wait(pending);
            final key = connection.connectionSnapshot.key;
            await staleData('$_loginCommand${jsonEncode({..._loginPayload,
              _sessionKeyField: _nf2StaleKey})}');
            await _flush(tester);
            expect(connection.connectionSnapshot.key, same(key));
            expect(context.currentUserId, nextUser);
            expect(context.sessionKey, _nextSessionKey);
            expect(h.handler.events, isEmpty);
            expect(h.handler.requester, isNull);
            _nf6ExpectAuthenticated(h);
            _nf7ExpectNotifications(h);
          }, skip: !withoutLogin && _nf11NotApplicable(path, authenticated, time) != null);
        }
      }
    }
  }
}

void _registerNf11Terminals() {
  for (final path in _Nf10Path.values) {
    for (final initiallyAuthenticated in _hookModes) {
      if (path == _Nf10Path.recovery && initiallyAuthenticated) continue;
      for (final terminal in _Nf10Terminal.values) {
        for (final sameUser in _hookModes) {
          testWidgets('$_nf11TerminalLabel ${path.name}/${terminal.name} authenticated=$initiallyAuthenticated sameUser=$sameUser', (tester) async {
            final h = _Nf5Harness(tester);
            await _nf10Prepare(h, tester, initiallyAuthenticated);
            final connection = h.fixture.connection;
            final pending = <Future<void>>[];
            final recoveries = <TransportRecoveryResult>[];
            await _nf10Start(h, tester, path, pending, recoveries);
            final previousLogin = h.fixture.chat.chatContext.loginCompleter;
            final staleData = h.fixture.sockets.last.data;
            final nextUser = sameUser ? _userId : _nf3OtherUser;
            final results = <User>[];
            final failures = <Object>[];
            final authenticated = <bool>[];
            Future<void>? latest;
            h.connectionHandler.callback = (event) {
              if (event != _nf5ReconnectFailed) return;
              h.connectionHandler.callback = null;
              latest = connection.connect(nextUser).then<void>((user) {
                results.add(user);
                authenticated.add(connection.hasAuthenticatedTransport);
              }, onError: (Object error) { failures.add(error); });
            };
            final refreshFailures = <Object>[];
            Future<void>? refresh;
            Future<void>? response;
            AccessTokenRequester? requester;
            switch (terminal) {
              case _Nf10Terminal.logiRevoked:
              case _Nf10Terminal.logiUnauthorized:
                await h.packet(_loginCommand, {_errorField: true,
                  _codeField: terminal == _Nf10Terminal.logiRevoked ?
                    SendbirdError.accessTokenRevoked : SendbirdError.nonAuthorized});
                break;
              case _Nf10Terminal.exprRevoked:
              case _Nf10Terminal.exprExpired:
                await h.packet(_nf4SessionCommand, {
                  if (terminal == _Nf10Terminal.exprRevoked)
                    _nf4ReasonField: SendbirdError.accessTokenRevoked,
                  if (terminal == _Nf10Terminal.exprExpired)
                    _nf4ExpiresField: _nf4Expired,
                });
                break;
              case _Nf10Terminal.httpNetwork:
                refresh = h.sessions.updateSessionKey().then<void>((_) {},
                    onError: (Object error) { refreshFailures.add(error); });
                await _flush(tester);
                h.api.response.completeError(NetworkErrorException());
                break;
              case _Nf10Terminal.requesterFail:
              case _Nf10Terminal.requesterNull:
              case _Nf10Terminal.requesterHttpReject:
                h.fixture.chat.eventManager.notifyAccessTokenRequired();
                expect(h.handler.events, [_nf2SessionRequired]);
                requester = h.handler.requester!;
                h.handler.events.clear();
                if (terminal == _Nf10Terminal.requesterFail) {
                  response = requester.onFail();
                } else if (terminal == _Nf10Terminal.requesterNull) {
                  response = requester.onSuccess(null);
                } else {
                  response = requester.onSuccess(_nextAccessToken);
                  await _flush(tester);
                  h.api.response.completeError(
                      SendbirdException(code: SendbirdError.accessTokenNotValid));
                }
                break;
            }
            await _flush(tester);
            if (_u5TransientTerminal(terminal)) {
              expect(latest, isNull);
              await _u5CompleteTransient(h, tester);
            } else {
              expect(latest, isNotNull);
              expect(h.handler.events, isEmpty);
              expect(failures, isEmpty);
              final login = h.fixture.chat.chatContext.loginCompleter!;
              await h.packet(_loginCommand, {..._loginPayload,
                _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
              await _flush(tester);
              expect(results.map((user) => user.userId), [nextUser]);
              expect(authenticated, [true]);
              expect(login.isCompleted, isTrue);
              await latest;
            }
            if (path == _Nf10Path.recovery) {
              expect(recoveries, [_u5TransientTerminal(terminal)
                  ? TransportRecoveryResult.authenticated
                  : TransportRecoveryResult.authRequired]);
            }
            await Future.wait(pending);
            if (previousLogin != null) expect(previousLogin.isCompleted, isTrue);
            if (refresh != null) {
              await refresh;
              expect(refreshFailures, [isA<SessionKeyRefreshFailedException>()]);
            }
            if (response != null) await response;
            if (requester != null) {
              final requests = h.api.requests;
              await requester.onFail();
              await requester.onSuccess(_nextAccessToken);
              expect(h.api.requests, requests);
            }
            expect(h.handler.events, isEmpty);
            expect(failures, isEmpty);
            final key = connection.connectionSnapshot.key;
            await staleData('$_loginCommand${jsonEncode({..._loginPayload,
              _sessionKeyField: _nf2StaleKey})}');
            await _flush(tester);
            expect(connection.connectionSnapshot.key, same(key));
            expect(h.fixture.chat.chatContext.currentUserId,
                _u5TransientTerminal(terminal) ? _userId : nextUser);
            expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
            _nf6ExpectAuthenticated(h);
            _nf7ExpectNotifications(h);
          }, skip: _nf10NotApplicable(path, initiallyAuthenticated) != null);
        }
      }
    }
  }
}

void _registerNf11Exhaustion() {
  for (final path in [_Nf10Path.automatic, _Nf10Path.foreground]) {
    for (final sameUser in _hookModes) {
      testWidgets('$_nf11ExhaustedLabel ${path.name} sameUser=$sameUser', (tester) async {
        final h = _Nf5Harness(tester);
        await _nf10Prepare(h, tester, true);
        final connection = h.fixture.connection;
        final context = h.fixture.chat.chatContext;
        final task = context.reconnectTask!;
        final nextUser = sameUser ? _userId : _nf3OtherUser;
        final pending = <Future<void>>[];
        final recoveries = <TransportRecoveryResult>[];
        final results = <User>[];
        final failures = <Object>[];
        final authenticated = <bool>[];
        final previousLogins = <Completer<User>>[];
        final previousFailures = <Object>[];
        final previousResults = <User>[];
        final starts = h.fixture.starts;
        var callbacks = _none;
        h.connectionHandler.callback = (event) {
          if (event != _nf5ReconnectFailed) return;
          h.connectionHandler.callback = null;
          callbacks++;
          expectSync(task.exceedRetryCount, isTrue);
          expectSync(task.hasRetriedLastChance, isTrue);
          expectSync(h.fixture.starts, starts + task.config.maximumRetryCount);
          pending.add(connection.connect(nextUser).then<void>((user) {
            results.add(user);
            authenticated.add(connection.hasAuthenticatedTransport);
          }, onError: (Object error) { failures.add(error); }));
        };
        await _nf10Start(h, tester, path, pending, recoveries);
        for (var index = _none; index < task.config.maximumRetryCount; index++) {
          expect(callbacks, _none);
          expect(task.retryCount, index + _one);
          expect(h.fixture.sockets.last.isConnected(), isTrue);
          final login = context.loginCompleter;
          if (login != null) {
            previousLogins.add(login);
            pending.add(login.future.then<void>(previousResults.add,
                onError: (Object error) { previousFailures.add(error); }));
          }
          h.fixture.sockets.last.closed();
          await tester.pump(_legacyReconnectDelay);
          await tester.pump(_statSettlingTick);
          await tester.pump(Duration(seconds: task.backOffPeriod));
          await _flush(tester);
        }
        expect(callbacks, _one);
        expect(previousLogins.every((login) => login.isCompleted), isTrue);
        expect(previousResults, isEmpty);
        expect(previousFailures.length, previousLogins.length);
        expect(previousFailures.every((error) => error is WebSocketFailedException), isTrue);
        expect(failures, isEmpty);
        final login = context.loginCompleter!;
        await h.packet(_loginCommand, {..._loginPayload,
          _userIdField: nextUser, _sessionKeyField: _nextSessionKey});
        await _flush(tester);
        expect(login.isCompleted, isTrue);
        expect(results.map((user) => user.userId), [nextUser]);
        expect(authenticated, [true]);
        expect(failures, isEmpty);
        expect(context.currentUserId, nextUser);
        expect(context.sessionKey, _nextSessionKey);
        expect(h.handler.events, isEmpty);
        await Future.wait(pending);
        _nf6ExpectAuthenticated(h);
        _nf7ExpectNotifications(h);
      });
    }
  }
}


bool _u5TransientTerminal(_Nf10Terminal terminal) =>
    terminal == _Nf10Terminal.logiUnauthorized ||
    terminal == _Nf10Terminal.httpNetwork;

Future<void> _u5CompleteTransient(_Nf5Harness h, WidgetTester tester) async {
  final connection = h.fixture.connection;
  final starts = h.fixture.starts;
  final sessionKey = h.fixture.chat.chatContext.sessionKey;
  expect(h.handler.events, isEmpty);
  expect(connection.getConnectionAttempt().authRequired, isFalse);
  final retryAt = connection.getConnectionAttempt().retryAt;
  expect(retryAt, isNotNull);
  await tester.pump(retryAt!.difference(connection.now));
  await _flush(tester);
  expect(h.fixture.starts, starts + _one);
  expect(h.fixture.sockets.last.loginSessionKey, sessionKey);
  expect(h.fixture.sockets.last.isConnected(), isTrue);
  expect(connection.hasAuthenticatedTransport, isFalse);
  await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
  await _flush(tester);
  expect(connection.hasAuthenticatedTransport, isTrue);
  expect(h.handler.events, isEmpty);
}


const _u5TimeoutMessage = 'session refresh timed out';
const _u5RefreshedKey = 'test-session-key-refreshed-u5b';
const _u5InfiniteRetries = -1;
const _u5Deadline = Duration(seconds: 10);
const _u5ShortDeadline = Duration(seconds: 3);
const _u5RetryAfter = Duration(seconds: 3);
const _u5Tick = Duration(milliseconds: 1);
final _u5TransientCodes = {
  SendbirdError.nonAuthorized,
  SendbirdError.tokenExpired,
  SendbirdError.authUnknownError,
};
final _u5TerminalCodes = {
  SendbirdError.accessTokenRevoked,
  SendbirdError.userDeactivated,
  SendbirdError.userNotExist,
};
enum _U5RestFailure { network, server, timeout, rateLimit, unauthorized,
  expired, unknown, invalid, revoked, deactivated, missing }

Object _u5RestError(_U5RestFailure failure) {
  switch (failure) {
    case _U5RestFailure.network: return NetworkErrorException();
    case _U5RestFailure.server: return InternalServerException();
    case _U5RestFailure.timeout: return TimeoutException(_u5TimeoutMessage);
    case _U5RestFailure.rateLimit:
      return RateLimitExceededException(retryAfter: _u5RetryAfter);
    case _U5RestFailure.unauthorized:
      return SendbirdException(code: SendbirdError.nonAuthorized);
    case _U5RestFailure.expired:
      return SendbirdException(code: SendbirdError.tokenExpired);
    case _U5RestFailure.unknown:
      return SendbirdException(code: SendbirdError.authUnknownError);
    case _U5RestFailure.invalid:
      return SendbirdException(code: SendbirdError.accessTokenNotValid);
    case _U5RestFailure.revoked:
      return SendbirdException(code: SendbirdError.accessTokenRevoked);
    case _U5RestFailure.deactivated:
      return SendbirdException(code: SendbirdError.userDeactivated);
    case _U5RestFailure.missing:
      return SendbirdException(code: SendbirdError.userNotExist);
  }
}

void _registerU5Tests() {
  _registerU5dTests();
  _registerU5cTests();
  _registerU5bTests();
  for (final recovery in _hookModes) {
    for (final correlated in _hookModes) {
      for (final code in {..._u5TransientCodes, ..._u5TerminalCodes,
          SendbirdError.accessTokenNotValid, SendbirdError.sessionKeyExpired}) {
        testWidgets('U5 LOGI code=$code recovery=$recovery correlated=$correlated', (tester) async {
          final h = _Nf5Harness(tester);
          await h.login(tester);
          final connection = h.fixture.connection;
          final results = <TransportRecoveryResult>[];
          Future<void>? pending;
          if (recovery) {
            pending = connection.recoverTransport(deadline: _u5Deadline)
                .then<void>(results.add);
            await _flush(tester);
          }
          final before = connection.getConnectionAttempt();
          final oldSocket = h.fixture.sockets.last;
          final starts = h.fixture.starts;
          await h.packet(_loginCommand, {
            if (correlated) _requestIdField: _ackRequestId,
            _errorField: true, _codeField: code,
          });
          await _flush(tester);
          if (_u5TransientCodes.contains(code)) {
            expect(h.handler.events, isEmpty);
            expect(connection.getConnectionAttempt().authRequired, isFalse);
            expect(connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
            expect(connection.getConnectionAttempt().retryAt, isNotNull);
            expect(results, isEmpty);
            if (recovery) {
              expect(connection.getConnectionAttempt().attemptId, before.attemptId);
              expect(connection.getConnectionAttempt().deadline, before.deadline);
            }
            final socket = connection.socketIdentity;
            oldSocket.closed();
            await _flush(tester);
            expect(connection.socketIdentity, same(socket));
            expect(await connection.advanceReconnect(), isTrue);
            await _flush(tester);
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
            await _flush(tester);
            expect(connection.hasAuthenticatedTransport, isTrue);
            expect(h.handler.events, isEmpty);
            if (pending != null) {
              await pending;
              expect(results, [TransportRecoveryResult.authenticated]);
            }
          } else if (code == SendbirdError.sessionKeyExpired) {
            expect(h.api.requests, _one);
            expect(h.handler.events, isEmpty);
            expect(connection.getConnectionAttempt().authRequired, isFalse);
            h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
            await _flush(tester);
            expect(h.handler.events, [_nf2SessionRefreshed]);
            expect(h.fixture.starts, starts + _one);
            expect(h.fixture.sockets.last, isNot(same(oldSocket)));
            expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
            expect(connection.hasAuthenticatedTransport, isFalse);
            if (recovery) {
              expect(connection.getConnectionAttempt().attemptId, before.attemptId);
              expect(connection.getConnectionAttempt().deadline, before.deadline);
            }
            await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _u5RefreshedKey});
            await _flush(tester);
            expect(connection.hasAuthenticatedTransport, isTrue);
            if (pending != null) {
              await pending;
              expect(results, [TransportRecoveryResult.authenticated]);
            }
          } else {
            expect(connection.getConnectionAttempt().authRequired, isTrue);
            expect(connection.getConnectionAttempt().retryAt, isNull);
            expect(await connection.advanceReconnect(), isFalse);
            if (code == SendbirdError.accessTokenNotValid) {
              expect(h.handler.events, [_nf2SessionRequired]);
              await h.handler.requester!.onFail();
              await h.handler.requester!.onFail();
              expect(h.handler.events, [_nf2SessionRequired, _nf2SessionError]);
            } else {
              expect(h.handler.events, [code == SendbirdError.accessTokenRevoked
                  ? _nf2SessionClosed : _nf2SessionError]);
            }
            if (pending != null) {
              await pending;
              expect(results, [TransportRecoveryResult.authRequired]);
            }
          }
        });
      }
    }
  }
  for (final requester in _hookModes) {
    for (final recovery in requester ? [false] : _hookModes) {
    for (final failure in _U5RestFailure.values) {
      testWidgets('U5 refresh REST ${failure.name} requester=$requester recovery=$recovery', (tester) async {
        final h = _Nf5Harness(tester);
        await h.login(tester);
        final connection = h.fixture.connection;
        final errors = <Object>[];
        final results = <TransportRecoveryResult>[];
        Future<void>? transport;
        if (recovery) {
          transport = connection.recoverTransport(deadline: _u5Deadline)
              .then<void>(results.add);
          await _flush(tester);
        }
        final before = connection.getConnectionAttempt();
        Future<void> pending;
        if (requester) {
          await h.packet(_loginCommand, {_errorField: true,
            _codeField: SendbirdError.accessTokenNotValid});
          await _flush(tester);
          expect(h.handler.events, [_nf2SessionRequired]);
          h.handler.events.clear();
          pending = h.handler.requester!.onSuccess(_nextAccessToken);
        } else {
          pending = h.sessions.updateSessionKey().then<void>((_) {},
              onError: (Object error) { errors.add(error); });
        }
        await _flush(tester);
        final error = _u5RestError(failure);
        h.api.response.completeError(error);
        await _flush(tester);
        if (failure == _U5RestFailure.invalid && !requester) {
          expect(h.handler.events, [_nf2SessionRequired]);
          await h.handler.requester!.onFail();
          await h.handler.requester!.onFail();
          expect(h.handler.events, [_nf2SessionRequired, _nf2SessionError]);
        } else if (error is SendbirdException &&
            (_u5TerminalCodes.contains(error.code) ||
                error.code == SendbirdError.accessTokenNotValid)) {
          expect(h.handler.events, [failure == _U5RestFailure.revoked
              ? _nf2SessionClosed : _nf2SessionError]);
        } else {
          expect(h.handler.events, isEmpty);
          expect(connection.getConnectionAttempt().authRequired, isFalse);
          expect(connection.getConnectionAttempt().retryAt, isNotNull);
          if (recovery) {
            expect(results, isEmpty);
            expect(connection.getConnectionAttempt().attemptId, before.attemptId);
            expect(connection.getConnectionAttempt().deadline, before.deadline);
          }
          if (failure == _U5RestFailure.rateLimit) {
            expect(connection.getConnectionAttempt().retryAt,
                connection.now.add(_u5RetryAfter));
            expect(await connection.advanceReconnect(), isFalse);
            final starts = h.fixture.starts;
            await tester.pump(_u5RetryAfter - _u5Tick);
            expect(h.fixture.starts, starts);
            await tester.pump(_u5Tick);
            await _flush(tester);
          }
          expect(await connection.advanceReconnect(), isTrue);
          await _flush(tester);
          expect(h.fixture.sockets.last.loginSessionKey, isNull);
          if (requester) expect(h.fixture.sockets.last.loginAccessToken, _nextAccessToken);
          await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect(connection.hasAuthenticatedTransport, isTrue);
          expect(h.handler.events, isEmpty);
        }
        await pending;
        if (!requester) expect(errors, [isA<SessionKeyRefreshFailedException>()]);
        if (h.handler.events.isNotEmpty) {
          expect(connection.getConnectionAttempt().authRequired, isTrue);
          expect(connection.getConnectionAttempt().retryAt, isNull);
        }
        if (transport != null) {
          await transport;
          expect(results, [h.handler.events.isEmpty
              ? TransportRecoveryResult.authenticated : TransportRecoveryResult.authRequired]);
        }
      });
    }
    }
  }
  for (final success in _hookModes) {
    testWidgets('U5 expired key refresh cannot invalidate newer LOGI success=$success', (tester) async {
      final h = _Nf5Harness(tester);
      await h.login(tester);
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.sessionKeyExpired});
      await _flush(tester);
      expect(h.api.requests, _one);
      await h.packet(_loginCommand, {_requestIdField: _ackRequestId,
        _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      final key = h.fixture.connection.connectionSnapshot.key;
      if (success) {
        h.api.response.complete({_sessionKeyField: _nf2StaleKey});
      } else {
        h.api.response.completeError(NetworkErrorException());
      }
      await _flush(tester);
      expect(h.fixture.connection.connectionSnapshot.key, same(key));
      expect(h.fixture.connection.hasAuthenticatedTransport, isTrue);
      expect(h.fixture.chat.chatContext.sessionKey, _nextSessionKey);
      expect(h.handler.events, [_nf2SessionRefreshed]);
      expect(h.fixture.events.where((event) =>
          event.kind == SocketEventKind.authenticationFailed), isEmpty);
    });
  }
  for (final code in _u5TransientCodes) {
    for (final infinite in _hookModes) {
      testWidgets('U5 transient error keeps recovery deadline code=$code infinite=$infinite', (tester) async {
        final h = _Nf5Harness(tester);
        await h.login(tester);
        final connection = h.fixture.connection;
        final task = h.fixture.chat.chatContext.reconnectTask!;
        if (infinite) task.config.maximumRetryCount = _u5InfiniteRetries;
        final results = <TransportRecoveryResult>[];
        final recovery = connection.recoverTransport(deadline: _u5Deadline)
            .then<void>(results.add);
        await _flush(tester);
        final deadline = connection.getConnectionAttempt().deadline;
        await h.packet(_loginCommand, {_errorField: true, _codeField: code});
        await _flush(tester);
        expect(await connection.advanceReconnect(), isTrue);
        await _flush(tester);
        await h.packet(_loginCommand, {_errorField: true, _codeField: code});
        await _flush(tester);
        expect(connection.getConnectionAttempt().deadline, deadline);
        await tester.pump(_u5Deadline);
        await _flush(tester);
        await recovery;
        expect(results, [TransportRecoveryResult.timeout]);
        expect(h.handler.events, isEmpty);
        expect(connection.getConnectionAttempt().authRequired, isFalse);
        expect(h.fixture.chat.chatContext.reconnectTask, same(task));
        expect(h.fixture.chat.chatContext.currentUserId, _userId);
        if (infinite) {
          expect(connection.getConnectionAttempt().retryAt, isNotNull);
          expect(await connection.advanceReconnect(), isTrue);
          await _flush(tester);
          await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect(connection.hasAuthenticatedTransport, isTrue);
        } else {
          expect(connection.getConnectionAttempt().retryAt, isNull);
          expect(connection.isDisconnected(), isTrue);
          expect(h.connectionHandler.events.where((event) =>
              event == _nf5ReconnectFailed).length, _one);
        }
        _nf7ExpectNotifications(h);
      });
    }
  }
}

enum _U5bRefreshPath { initial, automatic, foreground, recovery }
enum _U5bRestart { advance, recovery, foreground, network }

const _u5cLoginTimeoutSeconds = 30;
const _u5cAttemptDeadline = Duration(seconds: 20);

class _U5dDispatcher extends _Dispatcher {
  _U5dDispatcher(super.chat);
  int logouts = _none;
  @override
  Future<void> onLogout() async { logouts++; }
}

void _registerU5dTests() {
  for (final late in _hookModes) {
    testWidgets('U5d automatic final retry preserves account REST late=$late', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf10Prepare(h, tester, true);
      final connection = h.fixture.connection;
      final context = h.fixture.chat.chatContext;
      final user = context.currentUser;
      final owner = connection.authenticatedSessionIdentity;
      final task = context.reconnectTask!;
      final channel = OpenChannel(channelUrl: _retainedChannel,
          participantCount: _none, operators: [])..set(h.fixture.chat);
      h.fixture.chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
      final dispatcher = _U5dDispatcher(h.fixture.chat);
      h.fixture.chat.eventDispatcher = dispatcher;
      task.config.maximumRetryCount = _one;
      await _nf10Start(h, tester, _Nf10Path.automatic, [], []);
      expect(task.retryCount, _one);
      final before = connection.getConnectionAttempt();
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.sessionKeyExpired});
      await _flush(tester);
      expect(h.api.requests, _one);
      final starts = h.fixture.starts;
      if (!late) {
        h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
        await _flush(tester);
        expect(h.fixture.starts, starts + _one);
        expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
        expect(connection.getConnectionAttempt().attemptId, before.attemptId);
        expect(connection.getConnectionAttempt().deadline, before.deadline);
        expect(connection.hasAuthenticatedTransport, isFalse);
      }
      await tester.pump(before.deadline!.difference(connection.now));
      await _flush(tester);
      expect(context.currentUser, same(user));
      expect(context.currentUserId, _userId);
      expect(connection.authenticatedSessionIdentity, same(owner));
      expect(h.fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), same(channel));
      expect(dispatcher.logouts, _none);
      expect(connection.isDisconnected(), isTrue);
      expect(connection.reconnectNotificationPending, isFalse);
      expect(connection.getConnectionAttempt().retryAt, isNull);
      expect(connection.getConnectionAttempt().attemptId, isNull);
      expect(context.reconnectTask, same(task));
      expect(h.connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      final stoppedStarts = h.fixture.starts;
      if (late) {
        h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
        await _flush(tester);
      }
      expect(context.sessionKey, _u5RefreshedKey);
      expect(await h.sessions.getSessionKey(), _u5RefreshedKey);
      expect(h.handler.events, [_nf2SessionRefreshed]);
      await tester.pump(_u5Deadline);
      expect(h.fixture.starts, stoppedStarts);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      expect(await connection.advanceReconnect(), isTrue);
      await _flush(tester);
      expect(context.reconnectTask, isNot(same(task)));
      expect(context.reconnectTask!.config.maximumRetryCount, _one);
      expect(h.fixture.starts, stoppedStarts + _one);
      expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
      await h.packet(_loginCommand, {..._loginPayload,
        _sessionKeyField: _u5RefreshedKey});
      await _flush(tester);
      expect(connection.hasAuthenticatedTransport, isTrue);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted,
        _nf5ReconnectFailed, _nf5ReconnectStarted, _nf5ReconnectSucceeded]);
      _nf7ExpectNotifications(h);
    });
  }
  for (final successBeforeClose in _hookModes) {
    testWidgets('U5d background final REST success beforeClose=$successBeforeClose', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf10Prepare(h, tester, true);
      final connection = h.fixture.connection;
      final context = h.fixture.chat.chatContext;
      final user = context.currentUser;
      final owner = connection.authenticatedSessionIdentity;
      final task = context.reconnectTask!;
      task.config.maximumRetryCount = _one;
      await _nf10Start(h, tester, _Nf10Path.automatic, [], []);
      expect(task.retryCount, _one);
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.sessionKeyExpired});
      await _flush(tester);
      final starts = h.fixture.starts;
      final socket = h.fixture.sockets.last;
      final close = Completer<bool>();
      socket.closeBarrier = close;
      h.fixture.chat.isBackground = true;
      final paused = connection.enterBackground();
      await _flush(tester);
      if (!successBeforeClose) {
        close.complete(true);
        await paused;
      }
      h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
      await _flush(tester);
      if (successBeforeClose) {
        close.complete(true);
        await paused;
      }
      expect(context.currentUser, same(user));
      expect(connection.authenticatedSessionIdentity, same(owner));
      expect(context.sessionKey, _u5RefreshedKey);
      expect(context.reconnectTask, same(task));
      expect(connection.isDisconnected(), isTrue);
      expect(connection.reconnectNotificationPending, isFalse);
      expect(connection.getConnectionAttempt().retryAt, isNull);
      expect(connection.getConnectionAttempt().attemptId, isNull);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      expect(h.handler.events, [_nf2SessionRefreshed]);
      await tester.pump(_u5Deadline);
      expect(h.fixture.starts, starts);
      h.fixture.chat.isBackground = false;
      await connection.enterForeground();
      await _flush(tester);
      expect(context.reconnectTask, isNot(same(task)));
      expect(h.fixture.starts, starts + _one);
      expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
      await h.packet(_loginCommand, {..._loginPayload,
        _sessionKeyField: _u5RefreshedKey});
      await _flush(tester);
      expect(connection.hasAuthenticatedTransport, isTrue);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted,
        _nf5ReconnectFailed, _nf5ReconnectStarted, _nf5ReconnectSucceeded]);
      _nf7ExpectNotifications(h);
    });
  }
  testWidgets('U5e foreground before pending REST restarts at once', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    final user = context.currentUser;
    final task = context.reconnectTask!;
    task.config.maximumRetryCount = _one;
    await _nf10Start(h, tester, _Nf10Path.automatic, [], []);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(h.api.requests, _one);
    final starts = h.fixture.starts;
    h.fixture.chat.isBackground = true;
    await connection.enterBackground();
    await _flush(tester);
    h.fixture.chat.isBackground = false;
    await connection.enterForeground();
    await _flush(tester);
    expect(context.reconnectTask, isNot(same(task)));
    expect(h.fixture.starts, starts + _one);
    expect(context.currentUser, same(user));
    h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    expect(context.sessionKey, _u5RefreshedKey);
    expect(await h.sessions.getSessionKey(), _u5RefreshedKey);
    expect(h.handler.events, [_nf2SessionRefreshed]);
    expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
    expect(context.currentUserId, _userId);
  });
  testWidgets('U5d automatic pending REST deadline settles with remaining budget', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    final user = context.currentUser;
    final owner = connection.authenticatedSessionIdentity;
    final task = context.reconnectTask!;
    task.config.maximumRetryCount = _two;
    await _nf10Start(h, tester, _Nf10Path.automatic, [], []);
    expect(task.retryCount, _one);
    final before = connection.getConnectionAttempt();
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(h.api.requests, _one);
    expect(context.sessionKey, isNull);
    final starts = h.fixture.starts;
    await tester.pump(before.deadline!.difference(connection.now));
    await _flush(tester);
    expect(h.api.response.isCompleted, isFalse);
    expect(context.currentUser, same(user));
    expect(connection.authenticatedSessionIdentity, same(owner));
    expect(connection.isDisconnected(), isTrue);
    expect(connection.reconnectNotificationPending, isFalse);
    expect(connection.getConnectionAttempt().retryAt, isNull);
    expect(connection.getConnectionAttempt().attemptId, isNull);
    expect(context.reconnectTask, same(task));
    expect(task.retryCount, _one);
    expect(task.exceedRetryCount, isFalse);
    expect(h.connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectFailed]);
    expect(h.handler.events, isEmpty);
    await tester.pump(_u5Deadline);
    expect(h.fixture.starts, starts);
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(context.reconnectTask, same(task));
    expect(task.retryCount, _two);
    expect(h.fixture.starts, starts + _one);
    expect(h.fixture.sockets.last.loginSessionKey, isNull);
    expect(connection.hasAuthenticatedTransport, isFalse);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    h.api.response.complete({_sessionKeyField: _nf2StaleKey});
    await _flush(tester);
    expect(context.sessionKey, _nextSessionKey);
    expect(h.fixture.starts, starts + _one);
    expect(connection.hasAuthenticatedTransport, isTrue);
    expect(h.connectionHandler.events, [_nf5ReconnectStarted,
      _nf5ReconnectFailed, _nf5ReconnectStarted, _nf5ReconnectSucceeded]);
    _nf7ExpectNotifications(h);
  });
}

void _registerU5cTests() {
  for (final late in _hookModes) {
    testWidgets('U5c final retry REST success late=$late', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf10Prepare(h, tester, true);
      final connection = h.fixture.connection;
      final context = h.fixture.chat.chatContext;
      final user = context.currentUser;
      final task = context.reconnectTask!;
      task.config.maximumRetryCount = _one;
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.nonAuthorized});
      await _flush(tester);
      expect(await connection.advanceReconnect(), isTrue);
      await _flush(tester);
      final before = connection.getConnectionAttempt();
      final starts = h.fixture.starts;
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.sessionKeyExpired});
      await _flush(tester);
      expect(h.api.requests, _one);
      if (late) {
        await tester.pump(before.deadline!.difference(connection.now));
        await _flush(tester);
        expect(connection.isDisconnected(), isTrue);
        expect(connection.reconnectNotificationPending, isFalse);
        expect(h.connectionHandler.events,
            [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      }
      h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
      await _flush(tester);
      expect(context.sessionKey, _u5RefreshedKey);
      expect(context.currentUser, same(user));
      expect(context.reconnectTask, same(task));
      expect(h.handler.events, [_nf2SessionRefreshed]);
      if (late) {
        expect(h.fixture.starts, starts);
        expect(connection.isDisconnected(), isTrue);
        expect(connection.getConnectionAttempt().retryAt, isNull);
        expect(connection.getConnectionAttempt().attemptId, isNull);
        await tester.pump(_u5cAttemptDeadline);
        expect(h.fixture.starts, starts);
        expect(await connection.advanceReconnect(), isTrue);
        await _flush(tester);
        expect(context.reconnectTask, isNot(same(task)));
      } else {
        expect(connection.getConnectionAttempt().attemptId, before.attemptId);
        expect(connection.getConnectionAttempt().deadline, before.deadline);
      }
      expect(h.fixture.starts, starts + _one);
      expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
      expect(connection.hasAuthenticatedTransport, isFalse);
      await h.packet(_loginCommand, {..._loginPayload,
        _sessionKeyField: _u5RefreshedKey});
      await _flush(tester);
      expect(connection.hasAuthenticatedTransport, isTrue);
      _nf7ExpectNotifications(h);
    });
  }
  testWidgets('U5c recovery deadline settles while REST is pending', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    final user = context.currentUser;
    final task = context.reconnectTask!;
    task.config.maximumRetryCount = _one;
    task.increaseRetryCount();
    expect(task.exceedRetryCount, isTrue);
    final recovery = connection.recoverTransport(deadline: _u5Deadline);
    await _flush(tester);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(context.sessionKey, isNull);
    final starts = h.fixture.starts;
    await tester.pump(_u5Deadline);
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.timeout);
    expect(h.api.response.isCompleted, isFalse);
    expect(connection.reconnectNotificationPending, isFalse);
    expect(connection.isDisconnected(), isTrue);
    expect(connection.getConnectionAttempt().retryAt, isNull);
    expect(connection.getConnectionAttempt().attemptId, isNull);
    expect(context.reconnectTask, same(task));
    expect(context.currentUser, same(user));
    expect(h.handler.events, isEmpty);
    expect(h.connectionHandler.events,
        [_nf5ReconnectStarted, _nf5ReconnectFailed]);
    await tester.pump(_u5Deadline);
    expect(h.fixture.starts, starts);
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    expect(context.reconnectTask, isNot(same(task)));
    expect(h.fixture.sockets.last.loginSessionKey, isNull);
    expect(connection.hasAuthenticatedTransport, isFalse);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    h.api.response.complete({_sessionKeyField: _nf2StaleKey});
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    expect(context.sessionKey, _nextSessionKey);
    expect(connection.hasAuthenticatedTransport, isTrue);
    expect(h.handler.events, isEmpty);
    _nf7ExpectNotifications(h);
  });
  for (final failBeforeClose in _hookModes) {
    testWidgets('U5c background final retry resumes failBeforeClose=$failBeforeClose', (tester) async {
      final h = _Nf5Harness(tester);
      await _nf10Prepare(h, tester, true);
      final connection = h.fixture.connection;
      final context = h.fixture.chat.chatContext;
      final task = context.reconnectTask!;
      task.config.maximumRetryCount = _one;
      await _nf10Start(h, tester, _Nf10Path.automatic, [], []);
      expect(task.exceedRetryCount, isTrue);
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.sessionKeyExpired});
      await _flush(tester);
      final socket = h.fixture.sockets.last;
      final close = Completer<bool>();
      socket.closeBarrier = close;
      final starts = h.fixture.starts;
      h.fixture.chat.isBackground = true;
      final paused = connection.enterBackground();
      await _flush(tester);
      if (!failBeforeClose) {
        close.complete(true);
        await paused;
      }
      h.api.response.completeError(NetworkErrorException());
      await _flush(tester);
      if (failBeforeClose) {
        close.complete(true);
        await paused;
      }
      expect(connection.isDisconnected(), isTrue);
      expect(connection.reconnectNotificationPending, isFalse);
      expect(connection.getConnectionAttempt().retryAt, isNull);
      expect(h.connectionHandler.events,
          [_nf5ReconnectStarted, _nf5ReconnectFailed]);
      expect(h.handler.events, isEmpty);
      expect(context.currentUserId, _userId);
      await tester.pump(_u5Deadline);
      expect(h.fixture.starts, starts);
      h.fixture.chat.isBackground = false;
      await connection.enterForeground();
      await _flush(tester);
      expect(h.fixture.starts, starts + _one);
      expect(context.reconnectTask, isNot(same(task)));
      expect(h.fixture.sockets.last.loginSessionKey, isNull);
      expect(connection.hasAuthenticatedTransport, isFalse);
      await h.packet(_loginCommand, {..._loginPayload,
        _sessionKeyField: _nextSessionKey});
      await _flush(tester);
      expect(connection.hasAuthenticatedTransport, isTrue);
      expect(h.connectionHandler.events, [_nf5ReconnectStarted,
        _nf5ReconnectFailed, _nf5ReconnectStarted, _nf5ReconnectSucceeded]);
      _nf7ExpectNotifications(h);
    });
  }
  testWidgets('U5c refreshed initial login survives bounded deadline', (tester) async {
    final h = _Nf5Harness(tester);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    context.options.connectionTimeout = _u5cLoginTimeoutSeconds;
    context.options.reconnectAttemptDeadline = _u5cAttemptDeadline;
    await connection.doDisconnect(clear: true, logout: true);
    final failures = <Object>[];
    final users = <User>[];
    final pending = <Future<void>>[];
    pending.add(connection.connect(_userId).then<void>(users.add,
        onError: (Object error) { failures.add(error); }));
    await _flush(tester);
    final login = context.loginCompleter!;
    pending.add(connection.connect(_userId).then<void>(users.add,
        onError: (Object error) { failures.add(error); }));
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    final socket = h.fixture.sockets.last;
    final starts = h.fixture.starts;
    final before = connection.getConnectionAttempt();
    expect(socket.loginSessionKey, _u5RefreshedKey);
    await tester.pump(_u5cAttemptDeadline);
    await _flush(tester);
    expect(failures, isEmpty);
    expect(users, isEmpty);
    expect(login.isCompleted, isFalse);
    expect(context.loginCompleter, same(login));
    expect(connection.getConnectionAttempt().retryAt, isNotNull);
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    expect(h.fixture.sockets.last, isNot(same(socket)));
    expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
    expect(connection.getConnectionAttempt().attemptId, isNot(before.attemptId));
    expect(connection.hasAuthenticatedTransport, isFalse);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    await Future.wait(pending);
    expect(users.map((user) => user.userId), [_userId, _userId]);
    expect(failures, isEmpty);
    expect(connection.hasAuthenticatedTransport, isTrue);
    expect(h.handler.events, [_nf2SessionRefreshed]);
    _nf7ExpectNotifications(h);
  });
}

void _registerU5bTests() {
  testWidgets('U5b refreshed recovery respects pending Retry-After', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final recovery = connection.recoverTransport(deadline: _u5Deadline);
    await _flush(tester);
    final before = connection.getConnectionAttempt();
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    await h.packet(_busyCommand, {_retryAfterField: _u5RetryAfter.inSeconds});
    await _flush(tester);
    final starts = h.fixture.starts;
    h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    expect(h.fixture.starts, starts);
    expect(connection.getConnectionAttempt().attemptId, before.attemptId);
    expect(connection.getConnectionAttempt().deadline, before.deadline);
    expect(await connection.advanceReconnect(), isFalse);
    await tester.pump(_u5RetryAfter - _u5Tick);
    expect(h.fixture.starts, starts);
    await tester.pump(_u5Tick);
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.authenticated);
    expect(h.handler.events, [_nf2SessionRefreshed]);
    _nf7ExpectNotifications(h);
  });
  for (final restart in _U5bRestart.values) {
    for (final rest in _hookModes) {
      testWidgets('U5b exhausted budget restarts ${restart.name} REST=$rest', (tester) async {
        final h = _Nf5Harness(tester);
        await _nf10Prepare(h, tester, true);
        final connection = h.fixture.connection;
        final context = h.fixture.chat.chatContext;
        final task = context.reconnectTask!;
        task.config.maximumRetryCount = _one;
        if (rest) {
          final errors = <Object>[];
          final refresh = h.sessions.updateSessionKey().then<void>((_) {},
              onError: (Object error) { errors.add(error); });
          await _flush(tester);
          h.api.response.completeError(NetworkErrorException());
          await _flush(tester);
          await refresh;
          expect(errors, [isA<SessionKeyRefreshFailedException>()]);
        } else {
          await h.packet(_loginCommand, {_errorField: true,
            _codeField: SendbirdError.nonAuthorized});
          await _flush(tester);
        }
        expect(await connection.advanceReconnect(), isTrue);
        await _flush(tester);
        h.fixture.sockets.last.error(NetworkErrorException());
        await _flush(tester);
        expect(connection.isDisconnected(), isTrue);
        expect(connection.getConnectionAttempt().retryAt, isNull);
        expect(context.reconnectTask, same(task));
        expect(h.handler.events, isEmpty);
        expect(h.connectionHandler.events,
            [_nf5ReconnectStarted, _nf5ReconnectFailed]);
        _nf7ExpectNotifications(h);
        final starts = h.fixture.starts;
        await tester.pump(_u5Deadline);
        expect(h.fixture.starts, starts);
        Future<TransportRecoveryResult>? recovery;
        switch (restart) {
          case _U5bRestart.advance:
            expect(await connection.advanceReconnect(), isTrue);
            break;
          case _U5bRestart.recovery:
            recovery = connection.recoverTransport(deadline: _u5Deadline);
            break;
          case _U5bRestart.foreground:
            h.fixture.chat.isBackground = true;
            await connection.enterBackground();
            h.fixture.chat.isBackground = false;
            await connection.enterForeground();
            break;
          case _U5bRestart.network:
            await h.fixture.chat.handleConnectivityResults([ConnectivityResult.wifi]);
            break;
        }
        await _flush(tester);
        expect(h.fixture.starts, starts + _one);
        expect(context.reconnectTask, isNot(same(task)));
        expect(context.reconnectTask!.config.maximumRetryCount, _one);
        expect(h.connectionHandler.events,
            [_nf5ReconnectStarted, _nf5ReconnectFailed, _nf5ReconnectStarted]);
        await h.packet(_loginCommand, {..._loginPayload,
          _sessionKeyField: _nextSessionKey});
        await _flush(tester);
        if (recovery != null) {
          expect(await recovery, TransportRecoveryResult.authenticated);
        }
        expect(connection.hasAuthenticatedTransport, isTrue);
        expect(context.currentUserId, _userId);
        expect(h.handler.events, isEmpty);
        expect(h.connectionHandler.events, [_nf5ReconnectStarted,
          _nf5ReconnectFailed, _nf5ReconnectStarted, _nf5ReconnectSucceeded]);
        _nf7ExpectNotifications(h);
      });
    }
  }
  testWidgets('U5b recovery retry observes background and closes notifications', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final recovery = connection.recoverTransport(deadline: _u5Deadline);
    await _flush(tester);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.nonAuthorized});
    await _flush(tester);
    final retryAt = connection.getConnectionAttempt().retryAt!;
    final starts = h.fixture.starts;
    h.fixture.chat.isBackground = true;
    await tester.pump(retryAt.difference(connection.now));
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.cancelled);
    expect(h.fixture.starts, starts);
    expect(connection.isDisconnected(), isTrue);
    expect(connection.getConnectionAttempt().retryAt, isNull);
    expect(h.handler.events, isEmpty);
    expect(h.connectionHandler.events,
        [_nf5ReconnectStarted, _nf5ReconnectFailed]);
    _nf7ExpectNotifications(h);
  });
  for (final path in _U5bRefreshPath.values) {
    for (final correlated in _hookModes) {
      testWidgets('U5b refreshed transport ${path.name} correlated=$correlated', (tester) async {
        final h = _Nf5Harness(tester);
        final connection = h.fixture.connection;
        final context = h.fixture.chat.chatContext;
        final users = <User>[];
        final failures = <Object>[];
        final pending = <Future<void>>[];
        final recoveries = <TransportRecoveryResult>[];
        if (path == _U5bRefreshPath.initial) {
          await connection.doDisconnect(clear: true, logout: true);
          pending.add(connection.connect(_userId).then<void>(users.add,
              onError: (Object error) { failures.add(error); }));
          await _flush(tester);
          await h.sessions.setSessionKey(_nextSessionKey);
          pending.add(connection.connect(_userId).then<void>(users.add,
              onError: (Object error) { failures.add(error); }));
        } else {
          await _nf10Prepare(h, tester, true);
          await _nf10Start(h, tester, _Nf10Path.values.byName(path.name),
              pending, recoveries);
        }
        final login = context.loginCompleter;
        final previous = h.fixture.sockets.last;
        final staleData = previous.data;
        final before = connection.getConnectionAttempt();
        final starts = h.fixture.starts;
        expect(context.sessionKey, _nextSessionKey);
        await h.packet(_loginCommand, {
          if (correlated) _requestIdField: _ackRequestId,
          _errorField: true, _codeField: SendbirdError.sessionKeyExpired,
        });
        await _flush(tester);
        expect(h.api.requests, _one);
        expect(h.handler.events, isEmpty);
        if (login != null) expect(login.isCompleted, isFalse);
        await tester.pump(_u5Tick);
        h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
        await _flush(tester);
        expect(h.fixture.starts, starts + _one);
        expect(h.fixture.sockets.last, isNot(same(previous)));
        expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
        expect(connection.hasAuthenticatedTransport, isFalse);
        expect(context.loginCompleter, same(login));
        expect(users, isEmpty);
        expect(failures, isEmpty);
        expect(recoveries, isEmpty);
        if (path == _U5bRefreshPath.recovery) {
          expect(connection.getConnectionAttempt().attemptId, before.attemptId);
          expect(connection.getConnectionAttempt().deadline, before.deadline);
        }
        await staleData('$_loginCommand${jsonEncode({..._loginPayload,
          _sessionKeyField: _nf2StaleKey})}');
        await _flush(tester);
        expect(connection.hasAuthenticatedTransport, isFalse);
        expect(context.sessionKey, _u5RefreshedKey);
        await h.packet(_loginCommand, {..._loginPayload,
          _sessionKeyField: _u5RefreshedKey});
        await _flush(tester);
        await Future.wait(pending);
        expect(connection.hasAuthenticatedTransport, isTrue);
        expect(context.sessionKey, _u5RefreshedKey);
        expect(failures, isEmpty);
        if (path == _U5bRefreshPath.initial) {
          expect(users.map((user) => user.userId), [_userId, _userId]);
          expect(login!.isCompleted, isTrue);
        }
        if (path == _U5bRefreshPath.recovery) {
          expect(recoveries, [TransportRecoveryResult.authenticated]);
        }
        expect(h.handler.events, [_nf2SessionRefreshed]);
        _nf7ExpectNotifications(h);
      });
    }
  }
  for (final close in _hookModes) {
    testWidgets('U5b refreshed initial login settles close=$close', (tester) async {
      final h = _Nf5Harness(tester);
      final connection = h.fixture.connection;
      final context = h.fixture.chat.chatContext;
      await connection.doDisconnect(clear: true, logout: true);
      final failures = <Object>[];
      final initial = connection.connect(_userId).then<void>((_) {},
          onError: (Object error) { failures.add(error); });
      final login = context.loginCompleter!;
      await _flush(tester);
      await h.packet(_loginCommand, {_errorField: true,
        _codeField: SendbirdError.sessionKeyExpired});
      await _flush(tester);
      final starts = h.fixture.starts;
      h.api.response.complete({_sessionKeyField: _u5RefreshedKey});
      await _flush(tester);
      expect(h.fixture.starts, starts + _one);
      expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
      if (close) {
        h.fixture.sockets.last.closed();
      } else {
        await tester.pump(Duration(seconds: context.options.connectionTimeout));
      }
      await _flush(tester);
      await initial;
      expect(login.isCompleted, isTrue);
      expect(context.loginCompleter, isNull);
      expect(failures, [close ? isA<WebSocketFailedException>()
          : isA<ConnectionCanceledException>()]);
      expect(failures.whereType<LoginTimeoutException>(), isEmpty);
      expect(h.handler.events, [_nf2SessionRefreshed]);
    });
  }
  testWidgets('U5e repeated 400309 keeps shared initial login', (tester) async {
    final h = _Nf5Harness(tester);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    await connection.doDisconnect(clear: true, logout: true);
    context.options.reconnectAttemptDeadline = _u5ShortDeadline;
    final users = <User>[];
    final failures = <Object>[];
    final pending = <Future<void>>[];
    void connect() => pending.add(connection.connect(_userId).then<void>(
        users.add, onError: (Object error) { failures.add(error); }));
    connect();
    final login = context.loginCompleter!;
    await _flush(tester);
    connect();
    await _flush(tester);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(h.api.requests, _one);
    h.api.responses.first.complete({_sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    expect(h.fixture.sockets.last.loginSessionKey, _u5RefreshedKey);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(h.api.requests, _two);
    expect(context.loginCompleter, same(login));
    await tester.pump(_u5ShortDeadline);
    await _flush(tester);
    expect(login.isCompleted, isFalse);
    expect(context.loginCompleter, same(login));
    await connection.advanceReconnect();
    await _flush(tester);
    expect(context.loginCompleter, same(login));
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await Future.wait(pending);
    expect(login.isCompleted, isTrue);
    expect(failures, isEmpty);
    expect(users.map((user) => user.userId), [_userId, _userId]);
    expect(connection.hasAuthenticatedTransport, isTrue);
  });
  testWidgets('U5f active attempt is not extended by reset reconnect', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    final task = context.reconnectTask!;
    task.config.maximumRetryCount = _one;
    await _nf10Start(h, tester, _Nf10Path.automatic, [], []);
    final starts = h.fixture.starts;
    expect(task.exceedRetryCount, isTrue);
    expect(await connection.doReconnect(reset: true), isTrue);
    expect(await connection.doReconnect(reset: true, foregroundOnly: true), isTrue);
    await connection.enterForeground();
    await _flush(tester);
    expect(context.reconnectTask, same(task));
    expect(h.fixture.starts, starts);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
  });
  testWidgets('U5f public reconnect does not renew an exhausted budget', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    final task = context.reconnectTask!;
    task.config.maximumRetryCount = _one;
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.nonAuthorized});
    await _flush(tester);
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    h.fixture.sockets.last.error(NetworkErrorException());
    await _flush(tester);
    expect(connection.isDisconnected(), isTrue);
    final starts = h.fixture.starts;
    final events = List<String>.of(h.connectionHandler.events);
    expect(await connection.reconnect(reset: true), isFalse);
    await _flush(tester);
    expect(context.reconnectTask, same(task));
    expect(h.fixture.starts, starts);
    expect(h.connectionHandler.events, events);
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(context.reconnectTask, isNot(same(task)));
    expect(h.fixture.starts, starts + _one);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
  });
  testWidgets('U5f initial connect timeout with pending REST preserves and restarts', (tester) async {
    final h = _Nf5Harness(tester);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    await connection.doDisconnect(clear: true, logout: true);
    final users = <User>[];
    final failures = <Object>[];
    context.options.reconnectAttemptDeadline = _u5ShortDeadline;
    final pending = connection.connect(_userId).then<void>(
        users.add, onError: (Object error) { failures.add(error); });
    await _flush(tester);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(h.api.requests, _one);
    h.api.responses.first.complete({_sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    await tester.pump(_u5ShortDeadline);
    await _flush(tester);
    expect(context.loginCompleter, isNotNull);
    await tester.pump(Duration(seconds: context.options.connectionTimeout + _one));
    await _flush(tester);
    await pending;
    expect(users, isEmpty);
    expect(failures, [isA<ConnectionCanceledException>()]);
    expect(failures.whereType<LoginTimeoutException>(), isEmpty);
    expect(context.currentUserId, _userId);
    final starts = h.fixture.starts;
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
  });
  testWidgets('R7 default deadline: connectionTimeout fires before the attempt deadline', (tester) async {
    final h = _Nf5Harness(tester);
    final connection = h.fixture.connection;
    final context = h.fixture.chat.chatContext;
    await connection.doDisconnect(clear: true, logout: true);
    final users = <User>[];
    final failures = <Object>[];
    final pending = connection.connect(_userId).then<void>(
        users.add, onError: (Object error) { failures.add(error); });
    await _flush(tester);
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    expect(h.api.requests, _one);
    h.api.responses.first.complete({_sessionKeyField: _u5RefreshedKey});
    await _flush(tester);
    expect(context.loginCompleter, isNotNull);
    await tester.pump(Duration(seconds: context.options.connectionTimeout + _one));
    await _flush(tester);
    await pending;
    expect(users, isEmpty);
    expect(failures, [isA<ConnectionCanceledException>()]);
    expect(failures.whereType<LoginTimeoutException>(), isEmpty);
    expect(context.currentUserId, _userId);
    final starts = h.fixture.starts;
    expect(await connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    await h.packet(_loginCommand, {..._loginPayload,
      _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
  });
  for (final rest in _hookModes) {
    for (final infinite in _hookModes) {
      testWidgets('U5b transient retry budget REST=$rest infinite=$infinite', (tester) async {
        final h = _Nf5Harness(tester);
        await _nf10Prepare(h, tester, true);
        final connection = h.fixture.connection;
        final context = h.fixture.chat.chatContext;
        final user = context.currentUser;
        final task = context.reconnectTask!;
        final limit = task.config.maximumRetryCount;
        if (infinite) task.config.maximumRetryCount = _u5InfiniteRetries;
        final starts = h.fixture.starts;
        final errors = <Object>[];
        if (rest) {
          final refresh = h.sessions.updateSessionKey().then<void>((_) {},
              onError: (Object error) { errors.add(error); });
          await _flush(tester);
          h.api.response.completeError(NetworkErrorException());
          await _flush(tester);
          await refresh;
          expect(errors, [isA<SessionKeyRefreshFailedException>()]);
        } else {
          await h.packet(_loginCommand, {_errorField: true,
            _codeField: SendbirdError.nonAuthorized});
          await _flush(tester);
        }
        for (var index = _none; index < limit; index++) {
          expect(context.reconnectTask, same(task));
          expect(connection.getConnectionAttempt().retryAt, isNotNull);
          expect(await connection.advanceReconnect(), isTrue);
          await _flush(tester);
          expect(h.fixture.starts, starts + index + _one);
          h.fixture.sockets.last.error(NetworkErrorException());
          await tester.pump(_statSettlingTick);
          await _flush(tester);
        }
        expect(context.currentUser, same(user));
        expect(context.currentUserId, _userId);
        expect(context.reconnectTask, same(task));
        expect(h.handler.events, isEmpty);
        expect(connection.getConnectionAttempt().authRequired, isFalse);
        if (infinite) {
          expect(connection.getConnectionAttempt().retryAt, isNotNull);
          expect(await connection.advanceReconnect(), isTrue);
          await _flush(tester);
          expect(h.fixture.starts, starts + limit + _one);
          await h.packet(_loginCommand, {..._loginPayload,
            _sessionKeyField: _nextSessionKey});
          await _flush(tester);
          expect(connection.hasAuthenticatedTransport, isTrue);
          expect(h.connectionHandler.events,
              [_nf5ReconnectStarted, _nf5ReconnectSucceeded]);
        } else {
          expect(connection.getConnectionAttempt().retryAt, isNull);
          expect(connection.isDisconnected(), isTrue);
          await tester.pump(_u5Deadline);
          expect(h.fixture.starts, starts + limit);
          expect(h.connectionHandler.events,
              [_nf5ReconnectStarted, _nf5ReconnectFailed]);
        }
        _nf7ExpectNotifications(h);
      });
    }
  }
  for (final recovery in _hookModes) {
    for (final failBeforeClose in _hookModes) {
      testWidgets('U5b background late REST recovery=$recovery failBeforeClose=$failBeforeClose', (tester) async {
        final h = _Nf5Harness(tester);
        await _nf10Prepare(h, tester, true);
        final connection = h.fixture.connection;
        final pending = <Future<void>>[];
        final recoveries = <TransportRecoveryResult>[];
        await _nf10Start(h, tester, recovery ? _Nf10Path.recovery
            : _Nf10Path.automatic, pending, recoveries);
        expect(h.connectionHandler.events, [_nf5ReconnectStarted]);
        final errors = <Object>[];
        final refresh = h.sessions.updateSessionKey().then<void>((_) {},
            onError: (Object error) { errors.add(error); });
        await _flush(tester);
        final socket = h.fixture.sockets.last;
        final close = Completer<bool>();
        socket.closeBarrier = close;
        final starts = h.fixture.starts;
        h.fixture.chat.isBackground = true;
        final paused = connection.enterBackground();
        await _flush(tester);
        if (!failBeforeClose) {
          close.complete(true);
          await paused;
        }
        h.api.response.completeError(NetworkErrorException());
        await _flush(tester);
        await refresh;
        if (failBeforeClose) {
          expect(h.connectionHandler.events,
              [_nf5ReconnectStarted, _nf5ReconnectFailed]);
          close.complete(true);
          await paused;
        }
        await Future.wait(pending);
        if (recovery) expect(recoveries, [TransportRecoveryResult.cancelled]);
        expect(errors, [isA<SessionKeyRefreshFailedException>()]);
        expect(h.handler.events, isEmpty);
        expect(h.fixture.chat.chatContext.currentUserId, _userId);
        expect(connection.getConnectionAttempt().authRequired, isFalse);
        expect(connection.getConnectionAttempt().retryAt, isNull);
        expect(connection.isDisconnected(), isTrue);
        expect(await connection.advanceReconnect(), isFalse);
        socket.closed();
        await tester.pump(_u5Deadline);
        expect(h.fixture.starts, starts);
        expect(h.connectionHandler.events,
            [_nf5ReconnectStarted, _nf5ReconnectFailed]);
        _nf7ExpectNotifications(h);
      });
    }
  }
}


const _u5gOldKey = 'u5g-old-session-key';
const _u5gNewKey = 'u5g-new-session-key';
const _u5gAccessToken = 'u5g-access-token';
const _u5gBackground = Duration(minutes: 10);
const _u5gRoundTrip = Duration(milliseconds: 50);
const _u5gReconnectToRest = Duration(milliseconds: 148);
const _u5gTick = Duration(milliseconds: 1);
const _u5gSettleLimit = Duration(seconds: 120);
const _u5gRestCalls = 3;
const _u5gSessionKeyPath = '/session_key';
const _u5gSessionKeyHeader = 'Session-Key';
const _u5gHttpOk = 200;
const _u5gHttpBadRequest = 400;
const _u5gExpiredCode = 400309;

class _U5gListRequest extends ApiRequest {
  _U5gListRequest({required super.chat}) {
    url = 'group_channels';
  }

  @override
  Future response(Map<String, dynamic> res) async => res;
}

class _U5gHttp {
  final requests = <http.Request>[];

  int get sessionKeyRequests =>
      requests.where((r) => r.url.path.endsWith(_u5gSessionKeyPath)).length;
  int get listRequests => requests.length - sessionKeyRequests;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    await Future<void>.delayed(_u5gRoundTrip);
    if (request.url.path.endsWith(_u5gSessionKeyPath)) {
      return _json({'key': _u5gNewKey}, _u5gHttpOk);
    }
    return request.headers[_u5gSessionKeyHeader] == _u5gNewKey
        ? _json({'ok': true}, _u5gHttpOk)
        : _json({'error': true, 'code': _u5gExpiredCode, 'message': 'expired'},
            _u5gHttpBadRequest);
  }

  static http.Response _json(Map<String, dynamic> body, int status) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});
}

class _U5gResult {
  bool done = false;
  Object? value;
  Object? error;
}

_U5gHttp _u5gInstallHttp(_Nf5Harness h) {
  final rest = _U5gHttp();
  final chat = h.fixture.chat;
  chat.chatContext.accessToken = _u5gAccessToken;
  chat.apiClient = ApiClient(
    chatContext: chat.chatContext,
    sessionManager: h.sessions,
    client: MockClient(rest.handle),
  );
  return rest;
}

_U5gResult _u5gSendList(_Nf5Harness h) {
  final result = _U5gResult();
  h.fixture.chat.apiClient.send<dynamic>(_U5gListRequest(chat: h.fixture.chat))
      .then((value) {
    result..done = true..value = value;
  }, onError: (Object error) {
    result..done = true..error = error;
  });
  return result;
}

Future<Duration> _u5gElapsed(WidgetTester tester, _U5gResult result) async {
  var elapsed = Duration.zero;
  await tester.pump();
  while (!result.done && elapsed < _u5gSettleLimit) {
    await tester.pump(_u5gTick);
    elapsed += _u5gTick;
  }
  return elapsed;
}

void _registerU5gTests() {
  testWidgets('U5g normal path adds no wait beyond the REST round trips', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final rest = _u5gInstallHttp(h);
    final result = _u5gSendList(h);
    final elapsed = await _u5gElapsed(tester, result);
    expect(result.error, isNull);
    expect(result.value, {'ok': true});
    expect(rest.sessionKeyRequests, _one);
    expect(rest.listRequests, _two);
    expect(elapsed, _u5gRoundTrip * _u5gRestCalls);
  });

  testWidgets('U5g background, foreground reconnect, REST 400309 keeps the healthy socket', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final chat = h.fixture.chat;
    h.sessions.setSessionKey(_u5gOldKey);
    final rest = _u5gInstallHttp(h);
    chat.isBackground = true;
    await connection.enterBackground();
    await tester.pump(_u5gBackground);
    chat.isBackground = false;
    final starts = h.fixture.starts;
    await connection.enterForeground();
    await _flush(tester);
    expect(h.fixture.starts, starts + _one);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _u5gOldKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
    await tester.pump(_u5gReconnectToRest);
    final socket = h.fixture.sockets.last;
    final startsAfterForeground = h.fixture.starts;
    h.connectionHandler.events.clear();
    h.handler.events.clear();

    final result = _u5gSendList(h);
    final elapsed = await _u5gElapsed(tester, result);
    await tester.pump(_u5gSettleLimit);

    expect(result.error, isNull);
    expect(result.value, {'ok': true});
    expect(elapsed, _u5gRoundTrip * _u5gRestCalls);
    expect(rest.sessionKeyRequests, _one);
    expect(rest.listRequests, _two);
    expect(h.handler.events, [_nf2SessionRefreshed]);
    expect(h.fixture.starts, startsAfterForeground);
    expect(h.fixture.sockets.last, same(socket));
    expect(connection.hasAuthenticatedTransport, isTrue);
    expect(h.connectionHandler.events, isEmpty);
    expect(chat.chatContext.sessionKey, _u5gNewKey);
  });

  testWidgets('U5g socket rejected with 400309 is replaced after the refresh', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    final rest = _u5gInstallHttp(h);
    final starts = h.fixture.starts;
    await h.packet(_loginCommand, {_errorField: true,
      _codeField: SendbirdError.sessionKeyExpired});
    await _flush(tester);
    await tester.pump(_u5gRoundTrip);
    await _flush(tester);
    expect(rest.sessionKeyRequests, _one);
    expect(h.fixture.starts, starts + _one);
    expect(h.fixture.sockets.last.loginSessionKey, _u5gNewKey);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _nextSessionKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
    await tester.pump(_u5gSettleLimit);
  });

  testWidgets('U5g healthy socket rejected by WS 400309 is replaced after the refresh', (tester) async {
    final h = _Nf5Harness(tester);
    await _nf10Prepare(h, tester, true);
    final connection = h.fixture.connection;
    h.sessions.setSessionKey(_u5gOldKey);
    final rest = _u5gInstallHttp(h);
    expect(connection.hasAuthenticatedTransport, isTrue);
    final starts = h.fixture.starts;
    await h.packet(CommandString.error, {
      _errorField: true, _codeField: SendbirdError.sessionKeyExpired,
    });
    await _flush(tester);
    await tester.pump(_u5gRoundTrip);
    await _flush(tester);
    expect(rest.sessionKeyRequests, _one);
    expect(h.fixture.starts, starts + _one);
    expect(h.fixture.sockets.last.loginSessionKey, _u5gNewKey);
    await h.packet(_loginCommand, {..._loginPayload, _sessionKeyField: _u5gNewKey});
    await _flush(tester);
    expect(connection.hasAuthenticatedTransport, isTrue);
    final result = _u5gSendList(h);
    await _u5gElapsed(tester, result);
    expect(result.error, isNull);
    expect(result.value, {'ok': true});
    await tester.pump(_u5gSettleLimit);
  });
}
