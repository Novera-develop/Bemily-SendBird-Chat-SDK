part of 'network_path_reconnect_test.dart';

void registerNetworkReconnectLifecycleTests() {
  testWidgets('connection snapshot is synchronous and rejects superseded SDK authentication',
      (tester) async {
    final fixture = _Fixture();
    final manager = fixture.connection.socketTracker;
    final initial = fixture.adapter.connectionSnapshot;
    final first = manager.createSdkAttempt();
    first.started();
    final connecting = fixture.adapter.connectionSnapshot;
    expect(connecting.sequence, greaterThan(initial.sequence));
    expect(connecting.key, first.key);
    expect(connecting.reconnecting, isTrue);
    first.authenticated();
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    expect(fixture.adapter.connectionSnapshot.sequence, connecting.sequence);
    final second = manager.createSdkAttempt();
    second.started();
    final newer = fixture.adapter.connectionSnapshot;
    expect(newer.sequence, greaterThan(connecting.sequence));
    first.closed();
    first.authenticated();
    expect(fixture.adapter.connectionSnapshot.key, second.key);
    expect(fixture.adapter.connectionSnapshot.reconnecting, isTrue);
    second.authenticated();
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    second.closed(error: WebSocketFailedException());
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    expect(fixture.adapter.connectionSnapshot.reconnecting, isFalse);
    second.authenticated();
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    final superseded = manager.createSdkAttempt();
    superseded.started();
    final current = manager.createSdkAttempt();
    current.started();
    superseded.authenticated();
    expect(fixture.adapter.connectionSnapshot.key, current.key);
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    expect(fixture.adapter.connectionSnapshot.reconnecting, isTrue);
    fixture.dispose();
    await _flush(tester);
  });



  for (final logout in _hookModes) {
  testWidgets('SDK connection snapshot is invalidated before explicit disconnect awaits logout=$logout',
      (tester) async {
    final fixture = _Fixture();
    await fixture.connection.reconnectForNetworkChange();
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    final disconnect = fixture.connection.disconnect(logout: logout);
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    await disconnect;
    fixture.dispose();
    await _flush(tester);
  });
  }

  testWidgets('superseded SDK reservation cannot replace a newer transport after an await',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    final barrier = Completer<String?>();
    fixture.sessions.barrier = barrier;
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    expect(fixture.channels, isEmpty);
    fixture.sessions.barrier = null;
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final channel = fixture.channels.single;
    channel.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;
    barrier.complete(null);
    await _flush(tester);
    expect(fixture.channels.single, same(channel));
    expect(fixture.authenticated.single.key, key);
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.reconnectStarted).length, _one);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('public reconnect retains real transport ACK and close',
      (tester) async {
    final sdk = SendbirdChat.create();
    await sdk.init(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false));
    final fixture = _Fixture(chat: sdk.chat, useTransport: true);

    expect(await sdk.reconnect(), isTrue);
    await _flush(tester);
    final channel = fixture.channels.single;
    channel.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;
    expect(await sdk.reconnect(), isTrue);

    await _flush(tester);
    expect(fixture.channels.single, same(channel));
    expect(fixture.connection.webSocketClient.isConnected(), isTrue);
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.reconnectStarted).length, _one);
    final command = Command(cmd: CommandString.enter, requestId: _ackRequestId,
        payload: {_requestIdField: _ackRequestId});
    Command? received;
    final acknowledged = fixture.chat.commandManager.sendCommand(command)
        .then((value) => received = value);
    channel.controller.add(command.encode());
    await _flush(tester);
    expect(received?.requestId, _ackRequestId);
    await acknowledged;
    channel.controller.close();
    await _flush(tester);
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.websocketClosed)
        .single.key, key);
    await tester.pump(_legacyReconnectDelay);
    await tester.pump(_statSettlingTick);
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    expect(fixture.channels.length, _two);
    fixture.channels.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.authenticated.last.key, isNot(same(key)));
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('fake transport preserves callback Zone when same URL is reused',
      (tester) async {
    final fixture = _Fixture();
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final socket = fixture.sockets.single;
    await socket.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;
    expect(await fixture.connection.reconnect(reset: true), isTrue);
    await _flush(tester);
    expect(fixture.starts, _one);
    socket.closed();
    await _flush(tester);
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.websocketClosed).single.key, key);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary transport retains reservation identity at actual start',
      (tester) async {
    final fixture = _Fixture(useTransport: true, clock: () => Duration.zero);

    expect(await fixture.connection.doReconnect(), isTrue);
    await _flush(tester);
    expect(fixture.channels, isEmpty);
    final reservation = fixture.events.single;
    expect(reservation.kind, SocketEventKind.reconnectScheduled);

    await tester.pump(reservation.scheduledAt!);
    await _flush(tester);
    fixture.channels.single.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;
    expect(key, same(reservation.key));
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.reconnectStarted).single.key, key);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });



  testWidgets('ordinary socket retains identity through repeated close',
      (tester) async {
    final fixture = _Fixture();

    final connected = fixture.connection.doConnect(_userId);
    await _flush(tester);
    final socket = fixture.sockets.single;
    await socket.login();
    await _flush(tester);
    await connected;
    final authenticated = fixture.authenticated.single;

    socket.closed();
    socket.closed();
    await _flush(tester);
    final closed = fixture.events.where(
        (event) => event.kind == SocketEventKind.websocketClosed);
    expect(closed.length, _one);
    expect(closed.single.key, authenticated.key);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary socket emits reconnect scheduling with transport identity',
      (tester) async {
    final fixture = _Fixture();
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final socket = fixture.sockets.single;
    await socket.login();
    await _flush(tester);
    final event = fixture.authenticated.single;
    expect(fixture.events.map((event) => event.kind), containsAllInOrder([
      SocketEventKind.reconnectScheduled,
      SocketEventKind.reconnectStarted,
      SocketEventKind.authenticated,
    ]));
    expect(fixture.events.map((event) => event.key), everyElement(event.key));
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary transport error emits one terminal event with the captured key',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    fixture.chat.chatContext.pingInterval = _one;

    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final channel = fixture.channels.single;
    channel.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;

    channel.sink.failAdd = true;
    await tester.pump(_pingTick);
    await _flush(tester);
    final failures = fixture.events.where((event) =>
        event.kind == SocketEventKind.authenticationFailed);
    expect(failures.length, _one);
    expect(failures.single.key, key);
    fixture.dispose();
    fixture.connection.cancelReconnectTimers();
    await _flush(tester);
  });

  testWidgets('reused ordinary socket captures a new attempt and rejects old callbacks',
      (tester) async {
    final fixture = _Fixture();
    final connected = fixture.connection.doConnect(_userId);
    await _flush(tester);
    final socket = fixture.sockets.single;
    await socket.login();
    await _flush(tester);
    await connected;
    final oldClosed = socket.closed;
    final oldData = socket.data;
    final oldKey = fixture.authenticated.single.key;

    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    expect(fixture.sockets.single, same(socket));
    expect(fixture.starts, _two);
    final eventCount = fixture.events.length;
    oldClosed();
    await oldData('$_loginCommand${jsonEncode(_loginPayload)}');
    await _flush(tester);
    expect(fixture.events.length, eventCount);
    await socket.login();
    await _flush(tester);
    final key = fixture.authenticated.last.key;
    expect(key, isNot(same(oldKey)));
    socket.closed();
    socket.closed();
    await _flush(tester);
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.websocketClosed).single.key, key);
    fixture.dispose();
    await _flush(tester);
  });

}
