part of 'network_path_reconnect_test.dart';

const _cacheLoginStage = 'login';
const _cacheUserStage = 'user';
const _cacheSessionStage = 'session';
const _cacheStages = [_cacheLoginStage, _cacheUserStage, _cacheSessionStage];
const _replaceSession = 'replace';
const _clearSession = 'clear';
const _replaceAuthenticated = 'replace-authenticated';
const _cacheActions = [
  _replaceSession, _replaceAuthenticated, _clearSession, _logoutAction,
];
const _cachedUserId = 'cached-user';
const _busyCommand = 'BUSY';
const _retryAfterField = 'retry_after';
const _beforeRetry = 'before-retry';
const _duringPreparation = 'preparation';
const _sessionCancelStages = [_beforeRetry, _duringPreparation];

final _replacementLoginPayload = {
  ..._loginPayload, _userIdField: _cachedUserId, _sessionKeyField: _nextSessionKey,
};

void _registerSessionOwnershipTests() {
  for (final hooks in _hookModes) {
    for (final stage in _cacheStages) {
      for (final action in _cacheActions) {
        testWidgets('cache recovery rejects stale $stage $action hooks=$hooks',
            (tester) async {
          final fixture = _Fixture(useCache: true);
          if (hooks) fixture.chat.networkPathHooks = _Hooks();
          final context = fixture.chat.chatContext;
          final storage = _RecoveryDB(fixture.chat, stage);
          fixture.chat.dbManager = _RecoveryManager(fixture.chat, storage);
          fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
          final first = expectLater(fixture.chat.connect(_userId,
              accessToken: _firstAccessToken),
              throwsA(isA<ConnectionCanceledException>()));
          await _flush(tester);
          final firstLogin = context.loginCompleter!;
          if (stage == _cacheSessionStage) {
            fixture.sessions.barrier = Completer<String?>();
          }
          fixture.sockets.last.failConnect(WebSocketFailedException());
          await _flush(tester);
          expect(storage.loginReads, _one);
          expect(storage.userReads, stage == _cacheLoginStage ? _none : _one);
          Future<User>? replacement;
          if (action == _replaceSession || action == _replaceAuthenticated) {
            replacement = fixture.chat.connect(_cachedUserId,
                accessToken: _nextAccessToken);
            await _flush(tester);
            context.currentUser = User(userId: _cachedUserId, nickname: _cachedUserId);
            context.sessionKey = _nextSessionKey;
            if (action == _replaceAuthenticated) {
              await fixture.sockets.last.data(
                  '$_loginCommand${jsonEncode(_replacementLoginPayload)}');
              await _flush(tester);
              await replacement;
            }
          } else {
            await fixture.connection.doDisconnect(clear: action == _clearSession,
                logout: action == _logoutAction);
            await first;
            expect(firstLogin.isCompleted, isTrue);
          }
          final activeLogin = context.loginCompleter;
          final before = _recoveryContext(context);
          final resets = (fixture.connection as _Connection).reconnectResets.length;
          if (stage == _cacheSessionStage) {
            fixture.sessions.barrier!.complete(_userId);
          } else {
            storage.barrier.complete();
          }
          await _flush(tester);
          expect(_recoveryContext(context), before);
          expect((fixture.connection as _Connection).reconnectResets.length, resets);
          expect(context.loginCompleter, same(activeLogin));
          if (replacement != null) {
            if (action == _replaceSession) {
              expect(activeLogin!.isCompleted, isFalse);
            }
            expect(context.currentUser!.userId, _cachedUserId);
            expect(context.sessionKey, _nextSessionKey);
            if (action == _replaceSession) {
              await fixture.sockets.last.data(
                  '$_loginCommand${jsonEncode(_replacementLoginPayload)}');
              await _flush(tester);
              await replacement;
            }
            firstLogin.completeError(ConnectionCanceledException());
            await _flush(tester);
            await first;
          } else {
            expect(fixture.connection.isDisconnected(), isTrue);
            expect(firstLogin.isCompleted, isTrue);
          }
          fixture.dispose();
          await _flush(tester);
        });
      }
    }
    for (final cache in _cacheModes) {
      for (final stage in _sessionCancelStages) {
        testWidgets('BUSY retains guard at $stage cache=$cache hooks=$hooks',
            (tester) async {
          var allowed = true;
          var infos = _none;
          Completer<User>? delayedLogin;
          Object? delayedError;
          late _Fixture fixture;
          fixture = _Fixture(useCache: cache, onLoginInfo: () {
            infos++;
            if (infos == _two && stage == _duringPreparation) {
              delayedLogin = fixture.chat.chatContext.loginCompleter;
              delayedLogin!.future.then<void>((_) {},
                  onError: (Object error) { delayedError = error; });
              scheduleMicrotask(() { allowed = false; });
            }
          });
          if (hooks) fixture.chat.networkPathHooks = _Hooks();
          await _enterBusy(tester, fixture, () => allowed);
          if (stage == _beforeRetry) allowed = false;
          await tester.pump(_legacyReconnectDelay);
          await _flush(tester);
          await tester.pump(_legacyReconnectDelay);
          await _flush(tester);
          expect(fixture.starts, _one);
          expect(fixture.connection.isDisconnected(), isTrue);
          expect(infos, stage == _beforeRetry ? _one : _two);
          if (delayedLogin != null) {
            expect(delayedLogin!.isCompleted, isTrue);
            expect(delayedError, isA<ConnectionCanceledException>());
          }
          fixture.dispose();
          await _flush(tester);
        });
      }
      testWidgets('BUSY relogin retains guard for late LOGI cache=$cache hooks=$hooks',
          (tester) async {
        var allowed = true;
        var evaluations = _none;
        final fixture = _Fixture(useCache: cache);
        if (hooks) fixture.chat.networkPathHooks = _Hooks();
        await _enterBusy(tester, fixture, () { evaluations++; return allowed; });
        await tester.pump(_legacyReconnectDelay);
        await _flush(tester);
        await tester.pump(_legacyReconnectDelay);
        await _flush(tester);
        expect(fixture.starts, _two);
        await fixture.sockets.last.login();
        await _flush(tester);
        expect(fixture.connection.isConnected(), isTrue);
        final barrier = Completer<void>();
        fixture.deviceTokens.barrier = barrier;
        final delayed = fixture.sockets.last.data('$_loginCommand${jsonEncode({
          ..._loginPayload, _sessionKeyField: _nextSessionKey,
        })}');
        await _flush(tester);
        final writes = fixture.sessions.writtenKeys.length;
        final session = fixture.chat.chatContext.sessionKey;
        final checks = evaluations;
        allowed = false;
        barrier.complete();
        await _flush(tester);
        await delayed;
        expect(evaluations, greaterThan(checks));
        expect(fixture.sessions.writtenKeys.length, writes);
        expect(fixture.chat.chatContext.sessionKey, session);
        fixture.dispose();
        await _flush(tester);
      });
    }
  }

  for (final replaceGuard in <bool?>[null, false, true]) {
    testWidgets('public connect replaces session guard replacement=$replaceGuard',
        (tester) async {
      var allowed = true;
      var replacementAllowed = true;
      final fixture = _Fixture();
      fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
      final first = fixture.chat.connect(_userId, accessToken: _firstAccessToken,
          shouldProceed: () => allowed);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      await first;
      await fixture.chat.connect(_userId, accessToken: _firstAccessToken,
          shouldProceed: replaceGuard == null ? null : () => replacementAllowed);
      allowed = false;
      replacementAllowed = replaceGuard ?? true;
      expect(fixture.connection.isCallbackCurrent(null, null),
          replaceGuard != false);
      fixture.dispose();
      await _flush(tester);
    });
  }

  for (final logout in _cacheModes) {
    testWidgets('session guard survives socket creation and clears at logout=$logout',
        (tester) async {
      var allowed = true;
      final fixture = _Fixture();
      fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
      final first = fixture.chat.connect(_userId, accessToken: _firstAccessToken,
          shouldProceed: () => allowed);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      await first;
      fixture.connection.webSocketClient =
          fixture.connection.createWebSocketClient(null);
      allowed = false;
      expect(fixture.connection.isCallbackCurrent(null, null), isFalse);
      await expectLater(fixture.connection.doConnect(_userId),
          throwsA(isA<ConnectionCanceledException>()));
      expect(fixture.starts, _one);
      await fixture.connection.doDisconnect(clear: !logout, logout: logout);
      expect(fixture.connection.isCallbackCurrent(null, null), isTrue);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('ordinary reconnect retains guard during session key await',
      (tester) async {
    var allowed = true;
    final fixture = _Fixture();
    fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
    final first = fixture.chat.connect(_userId, accessToken: _firstAccessToken,
        shouldProceed: () => allowed);
    await _flush(tester);
    await fixture.sockets.last.data('$_loginCommand${jsonEncode({
      ..._loginPayload, _sessionKeyField: _nextSessionKey,
    })}');
    await _flush(tester);
    await first;
    fixture.sessions.barrier = Completer<String?>();
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    allowed = false;
    fixture.sessions.barrier!.complete(_nextSessionKey);
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(fixture.connection.isCallbackCurrent(null, null), isFalse);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('session key decrypt cannot write after its owner is cancelled',
      (tester) async {
    final fixture = _Fixture();
    final sessions = SessionManager(chat: fixture.chat);
    await sessions.setSessionKey(_nextSessionKey);
    fixture.chat.chatContext.sessionKey = null;
    var allowed = true;
    final pending = sessions.getSessionKey(shouldProceed: () => allowed);
    allowed = false;
    expect(await pending, isNull);
    expect(fixture.chat.chatContext.sessionKey, isNull);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('current cache recovery still completes its own login', (tester) async {
    final fixture = _Fixture(useCache: true);
    final storage = _RecoveryDB(fixture.chat, _cacheUserStage);
    fixture.chat.dbManager = _RecoveryManager(fixture.chat, storage);
    fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
    final pending = fixture.chat.connect(_userId, accessToken: _firstAccessToken);
    await _flush(tester);
    fixture.sockets.last.failConnect(WebSocketFailedException());
    await _flush(tester);
    storage.barrier.complete();
    await _flush(tester);
    expect(await pending, same(storage.user));
    expect(fixture.chat.chatContext.currentUser, same(storage.user));
    expect((fixture.connection as _Connection).reconnectResets, [true]);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('token error clears cache only while recovery is current', (tester) async {
    final fixture = _Fixture(useCache: true);
    final storage = _RecoveryDB(fixture.chat, _cacheLoginStage);
    fixture.chat.dbManager = _RecoveryManager(fixture.chat, storage);
    var allowed = false;
    final error = SendbirdException(code: SendbirdError.accessTokenNotValid);
    await fixture.chat.dbManager.getLoginInfoByException(_userId, error,
        shouldProceed: () => allowed);
    expect(storage.clears, _none);
    allowed = true;
    await fixture.chat.dbManager.getLoginInfoByException(_userId, error,
        shouldProceed: () => allowed);
    expect(storage.clears, _one);
    expect(storage.loginReads, _none);
    fixture.dispose();
    await _flush(tester);
  });
}

Future<void> _enterBusy(WidgetTester tester, _Fixture fixture,
    bool Function() guard) async {
  fixture.chat.chatContext
    ..currentUser = null
    ..sessionKey = null
    ..reconnectTask = ReconnectTask(
        LoginEvent.fromJson(_loginPayload).reconnectConfiguration);
  fixture.connection.changeState(DisconnectedState(chat: fixture.chat));
  final pending = expectLater(fixture.chat.connect(_userId,
      accessToken: _firstAccessToken, shouldProceed: guard),
      throwsA(isA<ServerOverloadedException>()));
  await _flush(tester);
  await fixture.sockets.last.data('$_busyCommand${jsonEncode({
    _retryAfterField: _one,
  })}');
  await _flush(tester);
  await pending;
}

List<Object?> _recoveryContext(ChatContext context) => [
  context.currentUser, context.currentUserId, context.services,
  context.appInfo, context.uploadSizeLimit, context.maxUnreadCountOnSuperGroup,
  context.lastConnectedAt, context.reconnectConfig, context.sessionKey,
  context.reconnectTask,
];

class _RecoveryManager extends DBManager {
  final _RecoveryDB storage;
  _RecoveryManager(Chat chat, this.storage) : super(chat: chat);
  @override
  bool isEnabled() => true;
  @override
  DB getDB() => storage;
  @override
  Future<void> setLoginInfo(ChatContext context, User user) async {}
  @override
  Future<void> clear() async {}
}

class _RecoveryDB implements DB {
  final String stage;
  final Completer<void> barrier = Completer<void>();
  final User user = User(userId: _userId, nickname: _userId);
  final Login login;
  int loginReads = _none;
  int userReads = _none;
  int clears = _none;
  _RecoveryDB(Chat chat, this.stage) : login = Login(userId: _userId,
      chat: chat, services: [Service.chat],
      reconnectConfig: LoginEvent.fromJson(_loginPayload).reconnectConfiguration);
  @override
  Future<Login?> getLogin(String userId) async {
    loginReads++;
    if (stage == _cacheLoginStage) await barrier.future;
    return login;
  }
  @override
  Future<User?> getUser(String userId) async {
    userReads++;
    if (stage == _cacheUserStage) await barrier.future;
    return user;
  }
  @override
  Future<void> clear() async { clears++; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
