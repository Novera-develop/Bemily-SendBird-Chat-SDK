part of '../network_path_reconnect_test.dart';

const _appId = 'network-path-test';
const _userId = 'network-path-user';
const _none = 0;
const _one = 1;
const _two = 2;
const _budget = Duration(seconds: 5);
const _legacyReconnectDelay = Duration(seconds: 1);
const _socketUrl = 'wss://localhost';
const _loginCommand = 'LOGI';
const _logoutAction = 'logout';
const _pingFailure = 'ping sink failed';
const _pingTick = Duration(seconds: 1);
const _hookModes = [false, true];
const _ackRequestId = 'retained-transport-ack';
const _requestIdField = 'req_id';
const _statSettlingTick = Duration(milliseconds: 1);
const _firstAccessToken = 'test-access-token-first';
const _nextAccessToken = 'test-access-token-next';
const _nextSessionKey = 'test-session-key-next';
const _nextApiHost = 'next-api.localhost';
const _nextWsHost = 'wss://next.localhost';
const _nextNickname = 'next-nickname';
const _tokenHeader = 'SENDBIRD-WS-TOKEN';
const _authHeader = 'SENDBIRD-WS-AUTH';
const _ephemeralPort = 0;
const _localSocketScheme = 'ws';
const _userIdField = 'user_id';
const _nicknameField = 'nickname';
const _loginTsField = 'login_ts';
const _reconnectField = 'reconnect';
const _intervalField = 'interval';
const _maxIntervalField = 'max_interval';
const _multiplierField = 'mul';
const _retryCountField = 'retry_cnt';
const _pingIntervalField = 'ping_interval';
const _pongTimeoutField = 'pong_timeout';
const _emojiHashField = 'emoji_hash';
const _useReactionField = 'use_reaction';
const _servicesField = 'services';
const _chatService = 'chat';
const _loginPayload = {
  _userIdField: _userId,
  _nicknameField: _userId,
  _loginTsField: _one,
  _reconnectField: {
    _intervalField: _one,
    _maxIntervalField: _two,
    _multiplierField: _two,
    _retryCountField: _two,
  },
  _pingIntervalField: _one,
  _pongTimeoutField: _one,
  _emojiHashField: _appId,
  _useReactionField: false,
  _servicesField: [_chatService],
};

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(Duration.zero);
  await tester.pump(Duration.zero);
}

class _Fixture {
  final Chat chat;
  final sockets = <_Socket>[];
  final channels = <_Channel>[];
  final events = <SocketEvent>[];
  late final ConnectionManager connection;
  late final _Dispatcher dispatcher;
  late final _Handler handler;
  late final _Sessions sessions;
  late final _DeviceTokens deviceTokens;
  late final StreamSubscription<SocketEvent> subscription;

  _Fixture({Duration Function()? clock, DateTime Function()? wallClock,
      Chat? chat, bool useTransport = false,
      bool useLocalServer = false, bool useCache = false,
      void Function()? onLoginInfo})
      : chat = chat ?? Chat(appId: _appId,
            options: SendbirdChatOptions(useCollectionCaching: useCache)) {
    final chat = this.chat;
    if (useCache) chat.dbManager = _CachedDB();
    chat.chatContext
      ..currentUser = User(userId: _userId, nickname: _userId)
      ..currentUserId = _userId
      ..sessionKey = _userId
      ..wsHost = _socketUrl;
    chat.chatContext.services.add(Service.chat);
    chat.statManager = _Stats();
    chat.deviceTokenManager = deviceTokens = _DeviceTokens();
    chat.sessionManager = sessions = _Sessions();
    dispatcher = _Dispatcher(chat);
    chat.eventDispatcher = dispatcher;
    connection = _Connection(chat: chat, reconnectClock: clock, wallClock: wallClock,
        onLoginInfo: onLoginInfo,
        socketFactory: (data, closed, error) {
      if (useTransport || useLocalServer) {
        return WebSocketClient(
          chat: chat,
          chatContext: chat.chatContext,
          onWebSocketConnected: () {},
          onWebSocketData: data,
          onWebSocketClosed: closed,
          onWebSocketError: error,
          channelFactory: useLocalServer ? null : (_) {
            final channel = _Channel();
            channels.add(channel);
            return channel;
          },
        );
      }
      final socket = _Socket(data, closed, error);
      sockets.add(socket);
      return socket;
    });
    chat.connectionManager = connection;
    handler = _Handler(connection);
    chat.eventManager.addConnectionHandler(_appId, handler);
    connection.changeState(ConnectedState(chat: chat));
    subscription = adapter.events.listen(events.add);
  }

  SocketTracker get adapter => connection.socketTracker;
  int get starts => sockets.fold(_none, (total, socket) => total + socket.starts);
  Iterable<SocketEvent> get authenticated => events.where(
      (event) => event.kind == SocketEventKind.authenticated);
  void dispose() {
    connection.cancelReconnectTimers();
    subscription.cancel();
  }
}

class _LocalHttpOverrides extends HttpOverrides {}

class _Channel implements WebSocketChannel {
  final controller = StreamController<dynamic>();
  @override
  late final _Sink sink = _Sink(controller);
  @override
  Stream<dynamic> get stream => controller.stream;
  @override
  Future<void> get ready => Future.value();
  @override
  int? get closeCode => null;
  void login() => controller.add('$_loginCommand${jsonEncode(_loginPayload)}');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sink implements WebSocketSink {
  _Sink(this.controller);
  final StreamController<dynamic> controller;
  final writes = <dynamic>[];
  bool failAdd = false;
  @override
  void add(dynamic data) {
    writes.add(data);
    if (failAdd) throw StateError(_pingFailure);
  }
  @override
  Future<void> close([int? closeCode, String? closeReason]) => controller.close();
  @override
  Future<void> get done => controller.done;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Socket implements WebSocketClient {
  final OnWebSocketData _data;
  final OnWebSocketClosed _closed;
  final OnWebSocketError _error;
  Zone? _zone;
  String? _url;
  OnWebSocketData get data {
    final zone = _zone;
    return (value) => zone == null ? _data(value) : zone.run(() => _data(value));
  }
  OnWebSocketClosed get closed {
    final zone = _zone;
    return () {
      if (identical(zone, _zone)) connected = false;
      return zone == null ? _closed() : zone.run(_closed);
    };
  }
  OnWebSocketError get error {
    final zone = _zone;
    return (value) => zone == null ? _error(value) : zone.run(() => _error(value));
  }
  int starts = _none;
  int closes = _none;
  String? loginAccessToken;
  String? loginSessionKey;
  bool connected = false;
  final writes = <String>[];
  @override
  void send(String data) { writes.add(data); }
  Completer<bool>? closeBarrier;
  _Socket(this._data, this._closed, this._error);
  void failConnect(Object error) =>
      _zone!.handleUncaughtError(error, StackTrace.current);
  Future<void> login() => data('$_loginCommand${jsonEncode(_loginPayload)}');
  @override
  void connect({required String url, String? accessToken, String? sessionKey,
      bool reconnect = false, OnWebSocketTransportStart? onTransportStart}) {
    if (_url == url && connected) return;
    void start() {
      _url = url;
      loginAccessToken = accessToken;
      loginSessionKey = sessionKey;
      connected = true;
      _zone = Zone.current;
      starts++;
    }
    if (onTransportStart != null) {
      onTransportStart(start);
    } else {
      start();
    }
  }
  @override
  Future<bool> close({int? code, String? reason}) async {
    closes++;
    connected = false;
    closed();
    final barrier = closeBarrier;
    if (barrier != null) return barrier.future;
    return true;
  }
  @override
  bool isConnected() => connected;
  @override
  int? getCloseCode() => null;
  @override
  int? get connectedTs => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Dispatcher implements EventDispatcher {
  final Chat chat;
  Completer<void>? barrier;
  Completer<void>? disconnectBarrier;
  Completer<void>? reconnectingBarrier;
  void Function()? onResumed;
  final completedKeys = <Object?>[];
  _Dispatcher(this.chat);
  @override
  Future<void> onConnecting() async {}
  @override
  Future<void> onReconnecting() async { await reconnectingBarrier?.future; }
  @override
  Future<void> onDisconnected() async { await disconnectBarrier?.future; }
  @override
  Future<void> onLogout() async {}
  @override
  Future<void> onReconnected(LoginEvent event) async {
    await barrier?.future;
    onResumed?.call();
    completedKeys.add(chat.connectionManager.callbackSocket);
  }
  @override
  Future<void> onLogin(LoginEvent event) => onReconnected(event);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stats implements StatManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DeviceTokens implements DeviceTokenManager {
  Completer<void>? barrier;
  void Function()? onResumed;
  @override
  Future<void> cleanUp() async {}
  @override
  Future<void> checkLoginEvent(LoginEvent event) async {
    await barrier?.future;
    onResumed?.call();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sessions implements SessionManager {
  Completer<String?>? barrier;
  final writtenKeys = <String?>[];
  @override
  void cleanUp() {}
  @override
  void renotifyExpiredCredentials() {}
  @override
  Future<String?> getSessionKey() async {
    final pending = barrier;
    if (pending != null) return pending.future;
    return _userId;
  }
  @override
  Future<void> setSessionKey(String? sessionKey) async {
    writtenKeys.add(sessionKey);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handler extends ConnectionHandler {
  _Handler(this.connection);
  final ConnectionManager connection;
  final keys = <Object?>[];
  final connectedUsers = <String>[];
  @override
  void onConnected(String userId) {
    keys.add(connection.callbackSocket);
    connectedUsers.add(userId);
  }
  @override
  void onReconnectSucceeded() { keys.add(connection.callbackSocket); }
  @override
  void onDisconnected(String userId) {}
  @override
  void onReconnectStarted() {}
  @override
  void onReconnectFailed() {}
}

class _CachedDB implements DBManager {
  final users = <User>[];
  Completer<void>? saveBarrier;
  Completer<void>? returnBarrier;
  void Function()? beforeSave;
  void Function()? afterSave;
  @override
  bool isEnabled() => true;
  @override
  Future<void> setLoginInfo(ChatContext context, User user,
      {bool Function()? shouldPersist}) async {
    beforeSave?.call();
    if (saveBarrier != null) await saveBarrier!.future;
    users.add(user);
    afterSave?.call();
    if (returnBarrier != null) await returnBarrier!.future;
  }
  @override
  Future<void> clear() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection extends ConnectionManager {
  final reconnectResets = <bool>[];
  @override
  Future<bool> reconnect({required bool reset}) {
    reconnectResets.add(reset);
    return super.reconnect(reset: reset);
  }
  final void Function()? onLoginInfo;
  _Connection({required super.chat, super.reconnectClock, super.socketFactory,
      super.wallClock,
      this.onLoginInfo});

  @override
  void setLoginInfo({required bool fromWebSocket, required String userId,
      String? accessToken, String? nickname, String? apiHost, String? wsHost}) {
    super.setLoginInfo(fromWebSocket: fromWebSocket, userId: userId,
        accessToken: accessToken, nickname: nickname,
        apiHost: apiHost, wsHost: wsHost);
    onLoginInfo?.call();
  }
}
