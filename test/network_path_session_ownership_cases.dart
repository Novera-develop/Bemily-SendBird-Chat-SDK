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

final _replacementLoginPayload = {
  ..._loginPayload, _userIdField: _cachedUserId, _sessionKeyField: _nextSessionKey,
};

void _registerSessionOwnershipTests() {
  for (final stage in _cacheStages) {
    for (final action in _cacheActions) {
      testWidgets('cache recovery rejects stale $stage $action',
          (tester) async {
        final fixture = _Fixture(useCache: true);
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
