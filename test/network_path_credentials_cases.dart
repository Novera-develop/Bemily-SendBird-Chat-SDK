part of 'network_path_reconnect_test.dart';

const _thirdAccessToken = 'test-access-token-third';
const _connectedPhase = 'connected';
const _connectingPhase = 'connecting';
const _reconnectingPhase = 'reconnecting';
const _connectionPhases = [
  _connectedPhase, _connectingPhase, _reconnectingPhase,
];
const _three = 3;
const _transportCredentialFields = ['accessToken', 'apiHost', 'wsHost'];
const _accessTokenField = 'accessToken';
const _apiHostField = 'apiHost';
const _wsHostField = 'wsHost';
const _cacheModes = [false, true];
const _sessionKeyField = 'key';
const _beforeSessionWrite = 'device';
const _beforeLoginCompletion = 'dispatcher';
const _loginBarriers = [_beforeSessionWrite, _beforeLoginCompletion];
const _loginTimeout = Duration(seconds: SendbirdChatOptions.defaultConnectionTimeout);

void registerNetworkCredentialsTests() {
  _registerCredentialRaceTests();
  for (final phase in _connectionPhases) {
    for (final nickname in <String?>[null, _nextNickname]) {
      testWidgets('same credentials preserve $phase nickname=$nickname',
          (tester) async {
        final fixture = _Fixture();
        fixture.chat.chatContext.accessToken = _firstAccessToken;
        final pending = _setCredentialPhase(fixture, phase);
        final current = fixture.chat.chatContext.currentUser!;
        var completed = false;
        final joined = fixture.chat.connect(_userId,
            accessToken: _firstAccessToken, nickname: nickname).then((user) {
          completed = true;
          return user;
        });
        await _flush(tester);
        expect(completed, phase == _connectedPhase);
        expect(fixture.starts, _none);
        expect(fixture.sockets.single.closes, _none);
        expect(fixture.chat.chatContext.accessToken, _firstAccessToken);
        pending?.complete(current);
        await _flush(tester);
        expect(await joined, same(current));
        fixture.dispose();
        await _flush(tester);
      });
    }

    for (final field in _transportCredentialFields) {
      testWidgets('changed $field replaces $phase credentials',
          (tester) async {
        final fixture = _Fixture();
        fixture.chat.chatContext.accessToken = _firstAccessToken;
        final pending = _setCredentialPhase(fixture, phase);
        final cancelled = pending == null ? null : expectLater(pending.future,
            throwsA(isA<ConnectionCanceledException>()));
        final previous = fixture.sockets.single;
        final closeBarrier = Completer<bool>();
        previous.closeBarrier = closeBarrier;
        final replacement = fixture.chat.connect(_userId,
            accessToken: field == _accessTokenField
                ? _thirdAccessToken : _firstAccessToken,
            apiHost: field == _apiHostField ? _nextApiHost : null,
            wsHost: field == _wsHostField ? _nextWsHost : null);
        await _flush(tester);
        expect(previous.closes, _one);
        expect(fixture.starts, _none);
        closeBarrier.complete(true);
        await _flush(tester);
        if (cancelled != null) await cancelled;
        expect(fixture.starts, _one);
        expect(fixture.sockets.last.loginAccessToken,
            field == _accessTokenField ? _thirdAccessToken : _firstAccessToken);
        expect(fixture.sockets.last.loginSessionKey, isNull);
        if (field == _apiHostField) {
          expect(fixture.chat.chatContext.apiHost, _nextApiHost);
        }
        if (field == _wsHostField) {
          expect(Uri.parse(fixture.sockets.last._url!).host,
              Uri.parse(_nextWsHost).host);
        }
        await fixture.sockets.last.login();
        await _flush(tester);
        expect((await replacement).userId, _userId);
        expect(fixture.connection.isConnected(), isTrue);
        fixture.dispose();
        await _flush(tester);
      });
    }
  }

  test('successive token changes reach loopback',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4, _ephemeralPort);
      final tokens = <String?>[];
      final sessionKeys = <String?>[];
      final peers = <WebSocket>[];
      final peerClosures = <Future<void>>[];
      final subscription = server.listen((request) async {
        tokens.add(request.headers.value(_tokenHeader));
        sessionKeys.add(request.headers.value(_authHeader));
        final peer = await WebSocketTransformer.upgrade(request);
        peers.add(peer);
        final closed = Completer<void>();
        peerClosures.add(closed.future);
        peer.listen((_) {}, onDone: closed.complete);
        peer.add('$_loginCommand${jsonEncode(_loginPayload)}');
      });
      final sdk = SendbirdChat.create();
      await sdk.init(appId: _appId,
          options: SendbirdChatOptions(useCollectionCaching: false));
      final fixture = _Fixture(chat: sdk.chat, useLocalServer: true);
      final wsHost = Uri(scheme: _localSocketScheme,
          host: server.address.address, port: server.port).toString();
      try {
        await sdk.connect(_userId, accessToken: _firstAccessToken, wsHost: wsHost);
        final first = fixture.chat.chatContext.currentUser;
        expect(await sdk.connect(_userId,
            accessToken: _firstAccessToken, wsHost: wsHost), same(first));
        expect(tokens.length, _one);
        expect(tokens.single, _firstAccessToken);
        expect(sessionKeys.single, null);

        await sdk.connect(_userId,
            accessToken: _nextAccessToken, wsHost: wsHost);
        await peerClosures.first.timeout(_budget);
        expect(tokens.length, _two);
        expect(tokens.last, _nextAccessToken);
        expect(sessionKeys.last, isNull);
        final second = fixture.chat.chatContext.currentUser;
        expect(await sdk.connect(_userId,
            accessToken: _nextAccessToken, wsHost: wsHost), same(second));
        expect(tokens.length, _two);

        await sdk.connect(_userId,
            accessToken: _thirdAccessToken, wsHost: wsHost);
        await peerClosures[_one].timeout(_budget);
        expect(tokens.length, _three);
        expect(tokens.last, _thirdAccessToken);
        expect(sessionKeys.last, isNull);
        expect(fixture.chat.chatContext.accessToken, _thirdAccessToken);
        final third = fixture.chat.chatContext.currentUser;
        expect(await sdk.connect(_userId,
            accessToken: _thirdAccessToken, wsHost: wsHost), same(third));
        expect(tokens.length, _three);
      } finally {
        await fixture.connection.disconnect(logout: false);
        fixture.dispose();
        for (final peer in peers) {
          await peer.close();
        }
        await subscription.cancel();
        await server.close(force: true);
      }
    }, _LocalHttpOverrides());
  });
}

Completer<User>? _setCredentialPhase(_Fixture fixture, String phase) {
  if (phase == _connectedPhase) return null;
  final pending = Completer<User>();
  fixture.chat.chatContext.loginCompleter = pending;
  fixture.connection.changeState(phase == _connectingPhase
      ? ConnectingState(chat: fixture.chat)
      : ReconnectingState(chat: fixture.chat));
  return pending;
}

void _registerCredentialRaceTests() {
  for (final cache in _cacheModes) {
    testWidgets('replacement cancels old login timeout cache=$cache',
        (tester) async {
      final fixture = _Fixture(useCache: cache);
      fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
      final timers = <Timer>[];
      Object? firstError;
      final first = runZoned(() => fixture.chat.connect(_userId,
          accessToken: _firstAccessToken), zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (duration == _loginTimeout) timers.add(timer);
          return timer;
        },
      )).then<void>((_) {}, onError: (Object error) { firstError = error; });
      await _flush(tester);
      expect(fixture.chat.dbManager.isEnabled(), cache);
      expect(timers, hasLength(_one));
      expect(timers.single.isActive, isTrue);
      final previous = fixture.sockets.last;
      final replacement = fixture.chat.connect(_userId,
          accessToken: _nextAccessToken);
      await _flush(tester);
      expect(firstError, isA<ConnectionCanceledException>());
      expect(timers.single.isActive, isFalse);
      expect(previous.closes, _one);
      final closes = previous.closes;
      await fixture.sockets.last.login();
      await _flush(tester);
      expect((await replacement).userId, _userId);
      await tester.pump(_loginTimeout);
      await first;
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.sockets.last.connected, isTrue);
      expect(fixture.sockets.last.closes, closes);
      fixture.dispose();
      await _flush(tester);
    });

    for (final barrierStage in _loginBarriers) {
      testWidgets('replacement rejects paused LOGI $barrierStage cache=$cache',
          (tester) async {
        final barrier = Completer<void>();
        var loginInfos = _none;
        Completer<User>? newLogin;
        late _Fixture fixture;
        fixture = _Fixture(useCache: cache, onLoginInfo: () {
          loginInfos++;
          if (loginInfos == _two) {
            newLogin = fixture.chat.chatContext.loginCompleter;
            barrier.complete();
          }
        });
        final first = expectLater(fixture.chat.connect(_userId,
            accessToken: _firstAccessToken),
            throwsA(isA<ConnectionCanceledException>()));
        await _flush(tester);
        if (barrierStage == _beforeSessionWrite) {
          fixture.deviceTokens.barrier = barrier;
        } else {
          fixture.dispatcher.barrier = barrier;
        }
        var resumed = false;
        final previous = fixture.sockets.last;
        void onResumed() {
          resumed = true;
          expectSync(newLogin, isNotNull);
          expectSync(newLogin!.isCompleted, isFalse);
          expectSync(fixture.starts, _one);
        }
        if (barrierStage == _beforeSessionWrite) {
          fixture.deviceTokens.onResumed = onResumed;
        } else {
          fixture.dispatcher.onResumed = onResumed;
        }
        final oldLogin = previous.data('$_loginCommand${jsonEncode({
          ..._loginPayload, _sessionKeyField: _nextSessionKey,
        })}');
        await _flush(tester);
        expect(resumed, isFalse);
        final writesBefore = fixture.sessions.writtenKeys.length;
        final sessionBefore = fixture.chat.chatContext.sessionKey;
        final replacement = fixture.chat.connect(_userId,
            accessToken: _nextAccessToken);
        await _flush(tester);
        await first;
        await oldLogin;
        expect(resumed, isTrue);
        expect(fixture.sessions.writtenKeys.length, writesBefore);
        expect(fixture.chat.chatContext.sessionKey, sessionBefore);
        expect(newLogin!.isCompleted, isFalse);
        expect(fixture.handler.connectedUsers, isEmpty);
        if (barrierStage == _beforeSessionWrite) {
          expect(fixture.sessions.writtenKeys, isEmpty);
          if (cache) expect((fixture.chat.dbManager as _CachedDB).users, isEmpty);
        }
        fixture.deviceTokens.onResumed = null;
        fixture.dispatcher.onResumed = null;
        await fixture.sockets.last.login();
        await _flush(tester);
        expect((await replacement).userId, _userId);
        expect(fixture.handler.connectedUsers, [_userId]);
        fixture.dispose();
        await _flush(tester);
      });
    }
  }

  for (final phase in _connectionPhases) {
    for (final token in <String?>[_nextAccessToken, null]) {
      testWidgets('omitted hosts survive $phase tokenOmitted=${token == null}',
          (tester) async {
        final fixture = _Fixture();
        fixture.chat.chatContext
          ..accessToken = _firstAccessToken
          ..apiHost = _nextApiHost
          ..wsHost = _nextWsHost;
        final pending = _setCredentialPhase(fixture, phase);
        final cancelled = pending == null ? null : expectLater(pending.future,
            throwsA(isA<ConnectionCanceledException>()));
        final replacement = fixture.chat.connect(_userId, accessToken: token);
        await _flush(tester);
        if (cancelled != null) await cancelled;
        expect(fixture.starts, _one);
        expect(fixture.sockets.last.loginAccessToken, token);
        expect(fixture.chat.chatContext.apiHost, _nextApiHost);
        expect(fixture.chat.chatContext.wsHost, _nextWsHost);
        expect(fixture.sockets.last._url, startsWith(_nextWsHost));
        await fixture.sockets.last.login();
        await _flush(tester);
        final user = await replacement;
        expect(await fixture.chat.connect(_userId, accessToken: token), same(user));
        expect(fixture.starts, _one);
        fixture.dispose();
        await _flush(tester);
      });
    }


  }





  for (final replaceSocket in _cacheModes) {
    testWidgets('stale timeout checks request and socket identity socket=$replaceSocket',
        (tester) async {
      final fixture = _Fixture(useCache: true);
      final first = expectLater(fixture.chat.connect(_userId,
          accessToken: _firstAccessToken),
          throwsA(isA<ConnectionCanceledException>()));
      await _flush(tester);
      final pending = fixture.chat.chatContext.loginCompleter!;
      if (replaceSocket) {
        fixture.connection.webSocketClient =
            fixture.connection.createWebSocketClient();
      } else {
        fixture.chat.chatContext.loginCompleter = Completer<User>();
      }
      final closes = fixture.sockets.last.closes;
      await tester.pump(_loginTimeout);
      await first;
      expect(fixture.connection.isConnecting(), isTrue);
      expect(fixture.sockets.last.closes, closes);
      pending.complete(fixture.chat.chatContext.currentUser!);
      fixture.chat.chatContext.loginCompleter?.future
          .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      await fixture.connection.doDisconnect(clear: true);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('orphaned old timeout leaves authenticated replacement connected',
      (tester) async {
    final fixture = _Fixture(useCache: true);
    final first = expectLater(fixture.chat.connect(_userId,
        accessToken: _firstAccessToken),
        throwsA(isA<ConnectionCanceledException>()));
    await _flush(tester);
    final orphaned = fixture.chat.chatContext.loginCompleter!;
    fixture.chat.chatContext.loginCompleter = null;
    final replacement = fixture.chat.connect(_userId, accessToken: _nextAccessToken);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    final current = await replacement;
    final closes = fixture.sockets.last.closes;
    await tester.pump(_loginTimeout);
    await first;
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.sockets.last.connected, isTrue);
    expect(fixture.sockets.last.closes, closes);
    expect(fixture.chat.chatContext.currentUser, same(current));
    orphaned.complete(current);
    fixture.dispose();
    await _flush(tester);
  });

}
