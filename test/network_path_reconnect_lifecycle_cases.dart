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

const _attemptBudget = Duration(seconds: 3);
const _tapInterval = Duration(milliseconds: 100);
const _tapCount = 20;
const _busySeconds = 2;
const _busyBudget = Duration(seconds: 6);
const _busyCommand = 'BUSY';
const _retryAfterField = 'retry_after';
const _errorField = 'error';
const _codeField = 'code';
const _busyBefore = Duration(milliseconds: 1900);
const _recoveryBackoff = Duration(seconds: 2);
const _retainedChannel = 'nf-retained-channel';
enum _AdvanceBlocked { disconnected, background, auth, busy }
enum _RecoveryCancelled { logout, background, connect }

void _registerTransportRecoveryTests() {
  testWidgets('N6 preparing deadline releases gate and rejects late preparation', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.chat.chatContext.options.reconnectAttemptDeadline = _attemptBudget;
    final blocked = Completer<String?>();
    fixture.sessions.barrier = blocked;
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    final first = fixture.connection.getConnectionAttempt();
    expect(first.phase, ConnectionAttemptPhase.preparing);
    expect(first.deadline!.difference(first.since!), _attemptBudget);
    await tester.pump(_attemptBudget);
    expect(fixture.connection.isReconnecting(), isTrue);
    final backoff = fixture.connection.getConnectionAttempt();
    expect(backoff.phase, ConnectionAttemptPhase.backoff);
    expect(backoff.retryAt, isNotNull);
    fixture.sessions.barrier = null;
    expect(await fixture.connection.advanceReconnect(), isTrue);
    await _flush(tester);
    expect(fixture.connection.getConnectionAttempt().attemptId, isNot(first.attemptId));
    await fixture.sockets.last.login();
    blocked.complete(_userId);
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.idle);
  });

  testWidgets('N6 expired socket LOGI and close cannot replace a later success', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.chat.chatContext.options.reconnectAttemptDeadline = _attemptBudget;
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    final staleLogin = fixture.sockets.last.data;
    final staleClose = fixture.sockets.last.closed;
    await tester.pump(_attemptBudget);
    await fixture.connection.advanceReconnect();
    await _flush(tester);
    await fixture.sockets.last.login();
    await staleLogin('$_loginCommand${jsonEncode(_loginPayload)}');
    staleClose();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.starts, _two);
  });

  testWidgets('N2 repeated advance joins one preparation', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final gate = Completer<String?>();
    fixture.sessions.barrier = gate;
    await fixture.connection.doReconnect();
    final scheduled = fixture.connection.getConnectionAttempt();
    expect(scheduled.phase, ConnectionAttemptPhase.backoff);
    expect(scheduled.retryAt, isNotNull);
    for (var tap = _none; tap < _tapCount; tap++) {
      expect(await fixture.connection.advanceReconnect(), isTrue);
      await tester.pump(_tapInterval);
    }
    expect(fixture.starts, _none);
    gate.complete(_userId);
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(await fixture.connection.advanceReconnect(), isTrue);
    await fixture.sockets.last.login();
    expect(await fixture.connection.advanceReconnect(), isFalse);
  });

  for (final state in _AdvanceBlocked.values) {
    testWidgets('N2 refuses advance in $state', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.connection.doReconnect();
      if (state == _AdvanceBlocked.disconnected) await fixture.connection.disconnect(logout: true);
      if (state == _AdvanceBlocked.background) fixture.chat.isBackground = true;
      if (state == _AdvanceBlocked.auth) fixture.connection.requireAuthentication();
      if (state == _AdvanceBlocked.busy) {
        fixture.connection.respectRetryAfter(const Duration(seconds: _busySeconds));
      }
      expect(await fixture.connection.advanceReconnect(), isFalse);
      expect(fixture.starts, _none);
      fixture.dispose();
    });
  }

  testWidgets('N5 recovery joins identical Future and succeeds on authentication', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final cache = fixture.chat.channelCache;
    final channel = OpenChannel(channelUrl: _retainedChannel,
        participantCount: _none, operators: [])..set(fixture.chat);
    cache.insert(channelKey: _retainedChannel, data: channel);
    final upload = AsyncSimpleTask(() async {});
    fixture.chat.uploadTaskMap[_ackRequestId] = upload;
    final handlers = fixture.chat.eventManager;
    final user = fixture.chat.chatContext.currentUser;
    final first = fixture.connection.recoverTransport();
    final second = fixture.connection.recoverTransport();
    expect(identical(first, second), isTrue);
    expect(fixture.chat.chatContext.currentUser, same(user));
    await _flush(tester);
    expect(fixture.starts, _one);
    fixture.dispatcher.barrier = Completer<void>();
    final login = fixture.sockets.last.login();
    await _flush(tester);
    expect(await first, TransportRecoveryResult.authenticated);
    expect(fixture.chat.channelCache, same(cache));
    expect(cache.find<OpenChannel>(channelKey: _retainedChannel), same(channel));
    expect(fixture.chat.uploadTaskMap[_ackRequestId], same(upload));
    expect(fixture.chat.eventManager, same(handlers));
    fixture.dispatcher.barrier!.complete();
    await login;
    await _flush(tester);
    expect(fixture.handler.keys, hasLength(_one));
  });

  testWidgets('N5 close belongs to deadline and late close cannot change success', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final close = Completer<bool>();
    fixture.sockets.single.closeBarrier = close;
    final recovery = fixture.connection.recoverTransport(deadline: _attemptBudget);
    await _flush(tester);
    await tester.pump(_attemptBudget);
    expect(await recovery, TransportRecoveryResult.timeout);
    expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
    await fixture.connection.advanceReconnect();
    await _flush(tester);
    await fixture.sockets.last.login();
    close.complete(true);
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.chat.chatContext.currentUserId, _userId);
  });

  for (final cancel in _RecoveryCancelled.values) {
    testWidgets('N5 recovery cancels on $cancel', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      if (cancel == _RecoveryCancelled.logout) {
        await fixture.connection.disconnect(logout: true);
      } else if (cancel == _RecoveryCancelled.background) {
        fixture.chat.isBackground = true;
        await fixture.connection.enterBackground();
      } else {
        final connected = fixture.connection.connect(_userId);
        await _flush(tester);
        await fixture.sockets.last.login();
        await connected;
      }
      expect(await recovery, TransportRecoveryResult.cancelled);
    });
  }

  testWidgets('N5 server session rejection requires authentication without logout', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final recovery = fixture.connection.recoverTransport();
    await _flush(tester);
    await fixture.sockets.last.data('$_loginCommand${jsonEncode({
      _errorField: true, _codeField: SendbirdError.accessTokenNotValid,
    })}');
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.authRequired);
    expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
    expect(fixture.chat.chatContext.currentUserId, _userId);
    expect(await fixture.connection.doReconnect(), isFalse);
    expect(await fixture.connection.advanceReconnect(), isFalse);
    expect(await fixture.connection.recoverTransport(), TransportRecoveryResult.authRequired);
  });

  testWidgets('N5 recovery immediately releases ACK waiter as afterWrite', (tester) async {
    final fixture = _Fixture(useTransport: true);
    addTearDown(fixture.dispose);
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    fixture.channels.single.login();
    await _flush(tester);
    final pending = expectLater(fixture.chat.commandManager.sendCommand(
        Command(cmd: CommandString.enter, requestId: _ackRequestId)),
        throwsA(isA<WebSocketFailedException>().having(
            (e) => e.sendStage, 'stage', SendStage.afterWrite)));
    final recovered = fixture.connection.recoverTransport();
    await _flush(tester);
    await pending;
    fixture.channels.last.login();
    await _flush(tester);
    expect(await recovered, TransportRecoveryResult.authenticated);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  for (final timeout in [false, true]) {
    testWidgets('N5 recovery respects existing Retry-After timeout=$timeout', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.connection.changeState(DelayedConnectingState(chat: fixture.chat,
          retryAfter: _busySeconds));
      final recovery = fixture.connection.recoverTransport(
          deadline: timeout ? _legacyReconnectDelay : _busyBudget);
      await _flush(tester);
      expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
      if (timeout) {
        await tester.pump(_legacyReconnectDelay);
        expect(await recovery, TransportRecoveryResult.timeout);
        expect(fixture.starts, _none);
        expect(fixture.connection.getConnectionAttempt().retryAt, isNotNull);
        fixture.dispose();
      } else {
        await tester.pump(_busyBefore);
        expect(fixture.starts, _none);
        await tester.pump(_tapInterval);
        await _flush(tester);
        expect(fixture.starts, _one);
        await fixture.sockets.last.login();
        expect(await recovery, TransportRecoveryResult.authenticated);
      }
    });
  }

  testWidgets('N5 BUSY during recovery delays the next handshake', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
    await _flush(tester);
    await fixture.sockets.last.data('$_busyCommand${jsonEncode({_retryAfterField: _busySeconds})}');
    await _flush(tester);
    expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
    await tester.pump(_busyBefore);
    expect(fixture.starts, _one);
    await tester.pump(_tapInterval);
    await _flush(tester);
    expect(fixture.starts, _two);
    await fixture.sockets.last.login();
    expect(await recovery, TransportRecoveryResult.authenticated);
  });

  testWidgets('N5 transient close retries within the same recovery deadline', (tester) async {
    final fixture = _Fixture();
    final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
    await _flush(tester);
    final attempt = fixture.connection.getConnectionAttempt();
    fixture.sockets.last.closed();
    await _flush(tester);
    expect(fixture.connection.getConnectionAttempt().attemptId, attempt.attemptId);
    expect(fixture.connection.getConnectionAttempt().deadline, attempt.deadline);
    expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
    await tester.pump(_recoveryBackoff);
    await _flush(tester);
    expect(fixture.starts, _two);
    await fixture.sockets.last.login();
    expect(await recovery, TransportRecoveryResult.authenticated);
    fixture.dispose();
  });

  testWidgets('N6 network change close is bounded before preparation', (tester) async {
    final fixture = _Fixture();
    fixture.chat.chatContext.options.reconnectAttemptDeadline = _attemptBudget;
    final blocked = Completer<bool>();
    fixture.sockets.single.closeBarrier = blocked;
    final reconnect = fixture.connection.reconnectForNetworkChange();
    await _flush(tester);
    await tester.pump(_attemptBudget);
    await reconnect;
    expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
    await fixture.connection.advanceReconnect();
    await _flush(tester);
    await fixture.sockets.last.login();
    blocked.complete(true);
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
  });

  testWidgets('N6 session requester refusal blocks transport retries', (tester) async {
    final fixture = _Fixture();
    final sessions = SessionManager(chat: fixture.chat);
    fixture.chat.sessionManager = sessions;
    final recovery = fixture.connection.recoverTransport();
    await _flush(tester);
    await sessions.accessTokenRequester.onFail();
    expect(await recovery, TransportRecoveryResult.authRequired);
    expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
    expect(await fixture.connection.advanceReconnect(), isFalse);
    fixture.dispose();
  });

  for (final connected in [false, true]) {
    testWidgets('N3 real websocket reports stage connected=$connected', (tester) async {
      final fixture = _Fixture(useTransport: true);
      if (connected) {
        await fixture.connection.doReconnect(reset: true);
        await _flush(tester);
        fixture.channels.single.sink.failAdd = true;
      }
      expect(() => fixture.connection.webSocketClient.send(_ackRequestId),
          throwsA(isA<WebSocketFailedException>().having((e) => e.sendStage,
              'stage', connected ? SendStage.afterWrite : SendStage.beforeWrite)));
      await fixture.connection.disconnect(logout: false);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('N5 exhausted retry budget cannot logout on recovery timeout', (tester) async {
    final fixture = _Fixture();
    final connectionHandler = _Nf5ConnectionHandler();
    final sessionHandler = _Nf2SessionHandler();
    fixture.chat.eventManager
      ..addConnectionHandler(_appId, connectionHandler)
      ..setSessionHandler(sessionHandler);
    fixture.chat.chatContext.reconnectTask!.config.maximumRetryCount = _one;
    fixture.chat.chatContext.reconnectTask!.increaseRetryCount(reset: true);
    final recovery = fixture.connection.recoverTransport(deadline: _attemptBudget);
    await _flush(tester);
    await tester.pump(_attemptBudget);
    expect(await recovery, TransportRecoveryResult.timeout);
    expect(fixture.chat.chatContext.currentUserId, _userId);
    expect(fixture.chat.chatContext.currentUser, isNotNull);
    expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.idle);
    expect(fixture.connection.getConnectionAttempt().retryAt, isNull);
    expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
    expect(fixture.connection.isDisconnected(), isTrue);
    expect(sessionHandler.events, isEmpty);
    expect(connectionHandler.events, [_nf5ReconnectStarted, _nf5ReconnectFailed]);
    expect(fixture.connection.reconnectNotificationPending, isFalse);
    final starts = fixture.starts;
    await tester.pump(_attemptBudget);
    expect(fixture.starts, starts);
    fixture.dispose();
  });

  testWidgets('N6 expired in-progress LOGI cannot overwrite replacement', (tester) async {
    final fixture = _Fixture();
    fixture.chat.chatContext.options.reconnectAttemptDeadline = _attemptBudget;
    final blocked = Completer<void>();
    fixture.deviceTokens.barrier = blocked;
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await tester.pump(_attemptBudget);
    fixture.deviceTokens.barrier = null;
    await fixture.connection.advanceReconnect();
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    final user = fixture.chat.chatContext.currentUser;
    final snapshot = fixture.connection.connectionSnapshot;
    blocked.complete();
    await _flush(tester);
    expect(fixture.chat.chatContext.currentUser, same(user));
    expect(fixture.connection.connectionSnapshot.key, snapshot.key);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
  });

  testWidgets('N2 advances recovery backoff once without resetting its deadline', (tester) async {
    final fixture = _Fixture();
    final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
    await _flush(tester);
    final deadline = fixture.connection.getConnectionAttempt().deadline;
    fixture.sockets.last.closed();
    await _flush(tester);
    for (var tap = _none; tap < _tapCount; tap++) {
      expect(await fixture.connection.advanceReconnect(), isTrue);
    }
    await _flush(tester);
    expect(fixture.starts, _two);
    expect(fixture.connection.getConnectionAttempt().deadline, deadline);
    await fixture.sockets.last.login();
    expect(await recovery, TransportRecoveryResult.authenticated);
    fixture.dispose();
  });
}

const _nf2SessionClosed = 'closed';
const _nf2SessionRequired = 'required';
const _nf2SessionRefreshed = 'refreshed';
const _nf2SessionError = 'error';
const _nf2StaleKey = 'stale-session-key';

void _registerNf2RaceTests() {
  for (final error in [false, true]) {
    testWidgets('NF2-1 callback reconnect preparation expires error=$error', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      fixture.chat.chatContext.options.reconnectAttemptDeadline = _attemptBudget;
      await fixture.connection.doReconnect(reset: true);
      await _flush(tester);
      await fixture.sockets.last.login();
      final gate = Completer<String?>();
      fixture.sessions.barrier = gate;
      if (error) {
        fixture.sockets.last.error(WebSocketFailedException());
      } else {
        fixture.sockets.last.closed();
        await tester.pump(_legacyReconnectDelay);
      }
      await _flush(tester);
      final pending = fixture.connection.getConnectionAttempt();
      expect(pending.phase, ConnectionAttemptPhase.preparing);
      await tester.pump(_attemptBudget);
      expect(fixture.connection.getConnectionAttempt().phase, ConnectionAttemptPhase.backoff);
      fixture.sessions.barrier = null;
      expect(await fixture.connection.advanceReconnect(), isTrue);
      await _flush(tester);
      expect(fixture.connection.getConnectionAttempt().attemptId, isNot(pending.attemptId));
      await fixture.sockets.last.login();
      gate.complete(_userId);
      await _flush(tester);
      expect(fixture.starts, _two);
      expect(fixture.connection.isConnected(), isTrue);
    });
  }

  testWidgets('NF2-2 BUSY recovery restores one remaining wait on foreground', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
    await _flush(tester);
    await fixture.sockets.last.data('$_busyCommand${jsonEncode({_retryAfterField: _busySeconds})}');
    await _flush(tester);
    fixture.chat.isBackground = true;
    await fixture.connection.enterBackground();
    expect(await recovery, TransportRecoveryResult.cancelled);
    await tester.pump(_tapInterval);
    fixture.chat.isBackground = false;
    await fixture.connection.enterForeground();
    final timer = fixture.connection.reconnectTimer;
    for (var tap = _none; tap < _tapCount; tap++) {
      await fixture.connection.enterForeground();
      expect(fixture.connection.reconnectTimer, same(timer));
    }
    await tester.pump(_busyBefore);
    await _flush(tester);
    expect(fixture.starts, _two);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
  });

  testWidgets('NF2-3 connect during recovery close awaits fresh authentication', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    await fixture.sockets.last.login();
    final previous = fixture.sockets.last;
    final close = Completer<bool>();
    previous.closeBarrier = close;
    final recovery = fixture.connection.recoverTransport();
    await _flush(tester);
    var completed = false;
    final connecting = fixture.connection.connect(_userId).then((user) {
      completed = true;
      return user;
    });
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.cancelled);
    expect(completed, isFalse);
    close.complete(true);
    await _flush(tester);
    expect(fixture.starts, _two);
    await fixture.sockets.last.login();
    await connecting;
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.sockets.last.connected, isTrue);
  });

  for (final requester in [false, true]) {
    for (final success in [false, true]) {
      for (final recovery in [false, true]) {
        testWidgets('NF2-4 stale HTTP requester=$requester success=$success recovery=$recovery', (tester) async {
          final fixture = _Fixture(wallClock: tester.binding.clock.now);
          addTearDown(fixture.dispose);
          final sessions = SessionManager(chat: fixture.chat);
          fixture.chat.sessionManager = sessions;
          final api = _Nf2SessionApi();
          fixture.chat.apiClient = api;
          final handler = _Nf2SessionHandler();
          fixture.chat.eventManager = EventManager(sessionManager: sessions)
            ..setSessionHandler(handler);
          await fixture.connection.doReconnect(reset: true);
          await _flush(tester);
          await fixture.sockets.last.login();
          Object? refreshError;
          final refresh = (requester
              ? sessions.accessTokenRequester.onSuccess(_firstAccessToken)
              : sessions.updateSessionKey()).then<void>((_) {},
                  onError: (Object error) { refreshError = error; });
          await _flush(tester);
          expect(api.requests, _one);
          if (recovery) {
            final replaced = fixture.connection.recoverTransport();
            await _flush(tester);
            await fixture.sockets.last.data('$_loginCommand${jsonEncode({
              ..._loginPayload, _sessionKeyField: _nextSessionKey,
            })}');
            expect(await replaced, TransportRecoveryResult.authenticated);
          } else {
            final replaced = fixture.connection.connect(_userId, accessToken: _nextAccessToken);
            await _flush(tester);
            await fixture.sockets.last.data('$_loginCommand${jsonEncode({
              ..._loginPayload, _sessionKeyField: _nextSessionKey,
            })}');
            await replaced;
          }
          final socket = fixture.connection.socketIdentity;
          final key = fixture.connection.connectionSnapshot.key;
          final token = fixture.chat.chatContext.accessToken;
          final starts = fixture.starts;
          if (success) {
            api.response.complete({_sessionKeyField: _nf2StaleKey});
          } else {
            api.response.completeError(NetworkErrorException());
          }
          await _flush(tester);
          await refresh;
          expect(fixture.connection.socketIdentity, same(socket));
          expect(fixture.connection.connectionSnapshot.key, same(key));
          expect(fixture.connection.isConnected(), isTrue);
          expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
          expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
          expect(fixture.chat.chatContext.accessToken, token);
          expect(fixture.starts, starts);
          expect(handler.events, isEmpty);
          expect(refreshError, anyOf(isNull, isA<ConnectionCanceledException>(), isA<SendbirdException>()));
        });
      }
    }
  }

  for (final success in [false, true]) {
    testWidgets('NF2-4 stale requester callback ignored success=$success', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      fixture.chat.eventManager.notifyAccessTokenRequired();
      final requester = handler.requester!;
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      await fixture.sockets.last.login();
      expect(await recovery, TransportRecoveryResult.authenticated);
      final token = fixture.chat.chatContext.accessToken;
      final socket = fixture.connection.socketIdentity;
      if (success) {
        await requester.onSuccess(null);
      } else {
        await requester.onFail();
      }
      await _flush(tester);
      expect(fixture.connection.socketIdentity, same(socket));
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.chat.chatContext.accessToken, token);
      expect(handler.events, [_nf2SessionRequired]);
    });
  }

  for (final close in [false, true]) {
    testWidgets('NF2-5 old BUSY continuation preserves recovered transport close=$close', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      await fixture.connection.doReconnect(reset: true);
      await _flush(tester);
      await fixture.sockets.last.login();
      final closeGate = Completer<bool>();
      final dispatchGate = Completer<void>();
      if (close) {
        fixture.sockets.last.closeBarrier = closeGate;
      } else {
        fixture.dispatcher.disconnectBarrier = dispatchGate;
      }
      final busy = fixture.sockets.last.data('$_busyCommand${jsonEncode({_retryAfterField: _busySeconds})}');
      await _flush(tester);
      fixture.sockets.last.closeBarrier = null;
      fixture.dispatcher.disconnectBarrier = null;
      final recovered = fixture.connection.recoverTransport(deadline: _busyBudget);
      await _flush(tester);
      final startsBeforeWait = fixture.starts;
      await tester.pump(const Duration(seconds: _busySeconds));
      await _flush(tester);
      await fixture.sockets.last.login();
      expect(await recovered, TransportRecoveryResult.authenticated);
      final socket = fixture.connection.socketIdentity;
      final key = fixture.connection.connectionSnapshot.key;
      closeGate.complete(true);
      dispatchGate.complete();
      await busy;
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.connection.socketIdentity, same(socket));
      expect(fixture.connection.connectionSnapshot.key, same(key));
      expect(fixture.connection.getConnectionAttempt().retryAt, isNull);
      expect(startsBeforeWait, _one);
      expect(fixture.starts, _two);
    });
  }

  for (final success in [false, true]) {
    testWidgets('NF2-4 current refresh preserves session notifications success=$success', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      final user = fixture.chat.chatContext.currentUser;
      final pending = sessions.updateSessionKey();
      final done = success ? pending : expectLater(pending,
          throwsA(isA<SessionKeyRefreshFailedException>()));
      await _flush(tester);
      if (success) {
        api.response.complete({_sessionKeyField: _nextSessionKey});
      } else {
        api.response.completeError(NetworkErrorException());
      }
      await _flush(tester);
      await done;
      expect(fixture.chat.chatContext.currentUser, same(user));
      expect(handler.events, [if (success) _nf2SessionRefreshed]);
      expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
      if (!success) {
        expect(fixture.connection.getConnectionAttempt().retryAt, isNotNull);
        await fixture.connection.advanceReconnect();
        await _flush(tester);
        await fixture.sockets.last.login();
        await _flush(tester);
        expect(fixture.connection.isConnected(), isTrue);
        expect(handler.events, isEmpty);
      }
      if (success) {
        expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
        await fixture.sockets.last.login();
        await _flush(tester);
        expect(fixture.connection.isConnected(), isTrue);
      }
    });

    testWidgets('NF2-4 old HTTP cannot complete replacement waiters success=$success', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      final old = sessions.updateSessionKey().then<void>((_) {}, onError: (Object _) {});
      await _flush(tester);
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _sessionKeyField: _nextSessionKey,
      })}');
      expect(await recovery, TransportRecoveryResult.authenticated);
      var completed = _none;
      final first = sessions.updateSessionKey().then((_) { completed++; });
      final second = sessions.updateSessionKey().then((_) { completed++; });
      await _flush(tester);
      expect(api.requests, _two);
      if (success) {
        api.response.complete({_sessionKeyField: _nf2StaleKey});
      } else {
        api.response.completeError(NetworkErrorException());
      }
      await _flush(tester);
      await old;
      expect(completed, _none);
      expect(handler.events, isEmpty);
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
      api.responses.last.complete({_sessionKeyField: _nextSessionKey});
      await _flush(tester);
      await Future.wait([first, second]);
      expect(completed, _two);
      expect(handler.events, [_nf2SessionRefreshed]);
      await fixture.sockets.last.login();
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
    });
  }

  testWidgets('NF2-4 rejected token requester can refresh the current session', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final sessions = SessionManager(chat: fixture.chat);
    fixture.chat.sessionManager = sessions;
    final api = _Nf2SessionApi();
    fixture.chat.apiClient = api;
    final handler = _Nf2SessionHandler();
    fixture.chat.eventManager = EventManager(sessionManager: sessions)
      ..setSessionHandler(handler);
    final pending = sessions.updateSessionKey();
    await _flush(tester);
    api.response.completeError(SendbirdException(code: SendbirdError.accessTokenNotValid));
    await _flush(tester);
    expect(handler.events, [_nf2SessionRequired]);
    expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
    final refreshed = handler.requester!.onSuccess(_nextAccessToken);
    await _flush(tester);
    expect(api.requests, _two);
    api.responses.last.complete({_sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await Future.wait([pending, refreshed]);
    expect(handler.events, [_nf2SessionRequired, _nf2SessionRefreshed]);
    expect(fixture.chat.chatContext.accessToken, _nextAccessToken);
    expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
    expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
  });

  testWidgets('NF2-4 requester HTTP replaces the earlier HTTP execution', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final sessions = SessionManager(chat: fixture.chat);
    fixture.chat.sessionManager = sessions;
    final api = _Nf2SessionApi();
    fixture.chat.apiClient = api;
    final handler = _Nf2SessionHandler();
    fixture.chat.eventManager = EventManager(sessionManager: sessions)
      ..setSessionHandler(handler);
    Object? failure;
    var completed = false;
    final pending = sessions.updateSessionKey().then<void>((_) { completed = true; },
        onError: (Object error) { failure = error; });
    await _flush(tester);
    fixture.chat.eventManager.notifyAccessTokenRequired();
    final refreshed = handler.requester!.onSuccess(_nextAccessToken);
    await _flush(tester);
    expect(api.requests, _two);
    api.response.completeError(NetworkErrorException());
    await _flush(tester);
    expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
    expect(completed, isFalse);
    expect(failure, isNull);
    expect(handler.events, [_nf2SessionRequired]);
    api.responses.last.complete({_sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await Future.wait([pending, refreshed]);
    expect(completed, isTrue);
    expect(handler.events, [_nf2SessionRequired, _nf2SessionRefreshed]);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
  });

  testWidgets('NF2-6 revoked token notifies session closed exactly once', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final handler = _Nf2SessionHandler();
    fixture.chat.eventManager.setSessionHandler(handler);
    final user = fixture.chat.chatContext.currentUser;
    final recovery = fixture.connection.recoverTransport();
    await _flush(tester);
    await fixture.sockets.last.data('$_loginCommand${jsonEncode({
      _errorField: true, _codeField: SendbirdError.accessTokenRevoked,
    })}');
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.authRequired);
    expect(fixture.chat.chatContext.currentUser, same(user));
    expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
    expect(handler.events, [_nf2SessionClosed]);
  });
}

class _Nf2SessionApi implements ApiClient {
  final responses = <Completer<Map<String, dynamic>>>[];
  Completer<Map<String, dynamic>> get response => responses.first;
  int get requests => responses.length;
  @override
  Future<T> send<T>(ApiRequest request) async {
    final pending = Completer<Map<String, dynamic>>();
    responses.add(pending);
    return await pending.future as T;
  }
  @override
  void cleanUp() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Nf2SessionHandler extends SessionHandler {
  final events = <String>[];
  AccessTokenRequester? requester;
  @override
  void onAccessTokenRequired(AccessTokenRequester value) {
    events.add(_nf2SessionRequired);
    requester = value;
  }
  @override
  void onSessionClosed() => events.add(_nf2SessionClosed);
  @override
  void onSessionRefreshed() => events.add(_nf2SessionRefreshed);
  @override
  void onSessionError(SendbirdException e) => events.add(_nf2SessionError);
}

const _nf3OtherUser = 'nf3-other-user';
const _nf3BusyWait = Duration(seconds: _busySeconds);

void _registerNf3RaceTests() {
  testWidgets('NF3-2 same credentials during recovery preserve account data', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    await fixture.sockets.last.login();
    final channel = OpenChannel(channelUrl: _retainedChannel,
        participantCount: _none, operators: [])..set(fixture.chat);
    fixture.chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
    final upload = AsyncSimpleTask(() async {});
    fixture.chat.uploadTaskMap[_ackRequestId] = upload;
    final queue = AsyncQueue();
    fixture.chat.setMessageQueue(_retainedChannel, queue);
    final close = Completer<bool>();
    fixture.sockets.last.closeBarrier = close;
    final recovery = fixture.connection.recoverTransport();
    await _flush(tester);
    var completed = false;
    final connecting = fixture.connection.connect(_userId).then((user) {
      completed = true;
      return user;
    });
    await _flush(tester);
    expect(await recovery, TransportRecoveryResult.cancelled);
    expect(completed, isFalse);
    await fixture.sockets.last.login();
    await connecting;
    close.complete(true);
    await _flush(tester);
    expect(fixture.chat.messageQueueMap[_retainedChannel], same(queue));
    expect(fixture.chat.uploadTaskMap[_ackRequestId], same(upload));
    expect(fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), same(channel));
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.starts, _two);
  });

  testWidgets('NF3-3 restored retry cannot interrupt replacement authentication', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
    await _flush(tester);
    await fixture.sockets.last.data('$_busyCommand${jsonEncode({_retryAfterField: _busySeconds})}');
    fixture.chat.isBackground = true;
    await fixture.connection.enterBackground();
    expect(await recovery, TransportRecoveryResult.cancelled);
    fixture.chat.isBackground = false;
    await fixture.connection.enterForeground();
    final timer = fixture.connection.reconnectTimer;
    final connecting = fixture.connection.doConnect(_nf3OtherUser, accessToken: _nextAccessToken);
    await _flush(tester);
    expect(timer?.isActive, isTrue);
    final socket = fixture.connection.socketIdentity;
    final key = fixture.connection.connectionSnapshot.key;
    final starts = fixture.starts;
    await tester.pump(_nf3BusyWait);
    await _flush(tester);
    expect(fixture.connection.isConnecting(), isTrue);
    expect(fixture.connection.socketIdentity, same(socket));
    expect(fixture.connection.connectionSnapshot.key, same(key));
    expect(fixture.starts, starts);
    await fixture.sockets.last.data('$_loginCommand${jsonEncode({
      ..._loginPayload, _userIdField: _nf3OtherUser,
      _sessionKeyField: _nextSessionKey,
    })}');
    await connecting;
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.connection.getConnectionAttempt().retryAt, isNull);
  });

  for (final restoredBusy in _hookModes) {
    testWidgets('NF3-3 restored retry cannot replace newer authentication busy=$restoredBusy', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final Future<User> connecting;
      if (restoredBusy) {
        final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
        await _flush(tester);
        await fixture.sockets.last.data('$_busyCommand${jsonEncode({_retryAfterField: _busySeconds})}');
        fixture.chat.isBackground = true;
        await fixture.connection.enterBackground();
        expect(await recovery, TransportRecoveryResult.cancelled);
        fixture.chat.isBackground = false;
        await fixture.connection.enterForeground();
        connecting = fixture.connection.doConnect(_nf3OtherUser, accessToken: _nextAccessToken);
      } else {
        connecting = fixture.connection.connect(_nf3OtherUser, accessToken: _nextAccessToken);
        await _flush(tester);
        fixture.connection.recordRetryAfter(_nf3BusyWait);
        expect(await fixture.connection.doReconnect(reset: true), isFalse);
      }
      await _flush(tester);
      final restoredTimer = fixture.connection.reconnectTimer;
      expect(restoredTimer?.isActive, isTrue);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _userIdField: _nf3OtherUser,
        _sessionKeyField: _nextSessionKey,
      })}');
      await connecting;
      final socket = fixture.connection.socketIdentity;
      final key = fixture.connection.connectionSnapshot.key;
      final starts = fixture.starts;
      expect(fixture.connection.isConnected(), isTrue);
      await tester.pump(_nf3BusyWait);
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.connection.socketIdentity, same(socket));
      expect(fixture.connection.connectionSnapshot.key, same(key));
      expect(fixture.starts, starts);
      expect(fixture.connection.getConnectionAttempt().attemptId, isNull);
      expect(fixture.connection.getConnectionAttempt().retryAt, isNull);
    });
  }

  testWidgets('NF3-3 restored BUSY wait rejects explicit connect until expiry', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final recovery = fixture.connection.recoverTransport(deadline: _busyBudget);
    await _flush(tester);
    await fixture.sockets.last.data('$_busyCommand${jsonEncode({_retryAfterField: _busySeconds})}');
    fixture.chat.isBackground = true;
    await fixture.connection.enterBackground();
    expect(await recovery, TransportRecoveryResult.cancelled);
    await tester.pump(_tapInterval);
    fixture.chat.isBackground = false;
    await fixture.connection.enterForeground();
    final restoredTimer = fixture.connection.reconnectTimer;
    final attempt = fixture.connection.getConnectionAttempt();
    Object? rejection;
    fixture.connection.connect(_nf3OtherUser, accessToken: _nextAccessToken)
        .then<void>((_) {}, onError: (Object error) { rejection = error; });
    await _flush(tester);
    expect(rejection, isA<ServerOverloadedException>());
    expect(fixture.connection.reconnectTimer, same(restoredTimer));
    expect(fixture.connection.getConnectionAttempt().retryAt, attempt.retryAt);
    expect(fixture.chat.chatContext.currentUserId, _userId);
    expect(fixture.starts, _one);
    await tester.pump(_busyBefore);
    await _flush(tester);
    await fixture.sockets.last.login();
    final connecting = fixture.connection.connect(_nf3OtherUser, accessToken: _nextAccessToken);
    await _flush(tester);
    await fixture.sockets.last.data('$_loginCommand${jsonEncode({
      ..._loginPayload, _userIdField: _nf3OtherUser,
      _sessionKeyField: _nextSessionKey,
    })}');
    expect((await connecting).userId, _nf3OtherUser);
    expect(fixture.connection.isConnected(), isTrue);
  });

  for (final error in _hookModes) {
    testWidgets('NF3-1 refresh survives an unauthenticated transport retry error=$error', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      await fixture.connection.doReconnect(reset: true);
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _sessionKeyField: _userId,
      })}');
      Object? failure;
      var completed = false;
      final refresh = sessions.updateSessionKey().then<void>((_) {
        completed = true;
      }, onError: (Object e) { failure = e; });
      await _flush(tester);
      expect(fixture.chat.chatContext.sessionKey, isNull);
      expect(api.requests, _one);
      if (error) {
        fixture.sockets.last.error(WebSocketFailedException());
      } else {
        fixture.sockets.last.closed();
        await tester.pump(_legacyReconnectDelay);
      }
      await _flush(tester);
      expect(fixture.connection.isDisconnected(), isTrue);
      expect(fixture.connection.getConnectionAttempt().attemptId, isNotNull);
      expect(fixture.starts, _one);
      expect(completed, isFalse);
      api.response.complete({_sessionKeyField: _nextSessionKey});
      await _flush(tester);
      await refresh;
      expect(failure, isNull);
      expect(completed, isTrue);
      expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
      expect(handler.events, [_nf2SessionRefreshed]);
      expect(fixture.starts, _two);
      expect(fixture.sockets.last.loginSessionKey, _nextSessionKey);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _sessionKeyField: _nextSessionKey,
      })}');
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
    });
  }

  for (final changeUser in _hookModes) {
    testWidgets('NF3-2 credentials replacement during recovery clears old account changeUser=$changeUser', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      await fixture.connection.doReconnect(reset: true);
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _sessionKeyField: _userId,
      })}');
      final channel = OpenChannel(channelUrl: _retainedChannel,
          participantCount: _none, operators: [])..set(fixture.chat);
      fixture.chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
      fixture.chat.uploadTaskMap[_ackRequestId] = AsyncSimpleTask(() async {});
      final queue = AsyncQueue();
      fixture.chat.setMessageQueue(_retainedChannel, queue);
      final queueGate = Completer<void>();
      final running = queue.enqueue(AsyncSimpleTask(() => queueGate.future));
      var queuedRan = false;
      final queued = queue.enqueue(AsyncSimpleTask(() async { queuedRan = true; }));
      Object? refreshFailure;
      final refresh = sessions.updateSessionKey().then<void>((_) {},
          onError: (Object e) { refreshFailure = e; });
      await _flush(tester);
      final previous = fixture.sockets.last;
      final close = Completer<bool>();
      previous.closeBarrier = close;
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      final nextUser = changeUser ? _nf3OtherUser : _userId;
      final connecting = fixture.connection.connect(nextUser, accessToken: _nextAccessToken);
      await _flush(tester);
      expect(await recovery, TransportRecoveryResult.cancelled);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _userIdField: nextUser, _sessionKeyField: _nextSessionKey,
      })}');
      expect((await connecting).userId, nextUser);
      expect(fixture.chat.messageQueueMap, isEmpty);
      expect(fixture.chat.uploadTaskMap, isEmpty);
      expect(fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), isNull);
      expect(refreshFailure, isA<ConnectionCanceledException>());
      queueGate.complete();
      close.complete(true);
      api.response.complete({_sessionKeyField: _nf2StaleKey});
      await _flush(tester);
      await Future.wait([running, queued, refresh]);
      expect(queuedRan, isFalse);
      expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.starts, _two);
    });
  }
}

enum _Nf4LoginBoundary { applied, saving, saved }
enum _Nf4Credentials { same, user, token }

const _nf4SessionCommand = CommandString.sessionExpired;
const _nf4ReasonField = 'reason';
const _nf4ExpiresField = 'expires_in';
const _nf4Expired = -1;

void _registerNf4RaceTests() {
  for (final code in [SendbirdError.sessionKeyExpired, SendbirdError.accessTokenNotValid]) {
    testWidgets('NF4-I2 authentication rejection waits for app credentials code=$code', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        _errorField: true, _codeField: code,
      })}');
      await _flush(tester);
      if (code == SendbirdError.sessionKeyExpired) {
        expect(handler.events, isEmpty);
        expect(api.requests, _one);
        expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
        api.response.completeError(SendbirdException(code: SendbirdError.accessTokenNotValid));
        await _flush(tester);
      }
      expect(await recovery, TransportRecoveryResult.authRequired);
      expect(handler.requester, isNotNull);
      var completed = false;
      final waiting = sessions.updateSessionKey().then((_) { completed = true; });
      await _flush(tester);
      final initialRequests = code == SendbirdError.sessionKeyExpired ? _one : _none;
      expect(api.requests, initialRequests);
      expect(completed, isFalse);
      final refresh = handler.requester!.onSuccess(_nextAccessToken);
      await _flush(tester);
      expect(api.requests, initialRequests + _one);
      api.responses.last.complete({_sessionKeyField: _nextSessionKey});
      await _flush(tester);
      await Future.wait([waiting, refresh]);
      expect(completed, isTrue);
      expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
      await fixture.sockets.last.login();
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
    });
  }

  for (final success in _hookModes) {
    testWidgets('NF4-I1 correlated LOGI supersedes HTTP success=$success', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      await fixture.connection.doReconnect(reset: true);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      Object? failure;
      final pending = sessions.updateSessionKey().then<void>((_) {},
          onError: (Object error) { failure = error; });
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        _requestIdField: _ackRequestId, _sessionKeyField: _nextSessionKey,
      })}');
      await _flush(tester);
      if (success) {
        api.response.complete({_sessionKeyField: _nf2StaleKey});
      } else {
        api.response.completeError(NetworkErrorException());
      }
      await _flush(tester);
      await pending;
      expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
      expect(failure, isA<ConnectionCanceledException>());
      expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
      expect(fixture.connection.isConnected(), isTrue);
      expect(handler.events, [_nf2SessionRefreshed]);
    });
  }

  testWidgets('NF4-I2 revoked session cannot start HTTP without new credentials', (tester) async {
    final fixture = _Fixture(wallClock: tester.binding.clock.now);
    addTearDown(fixture.dispose);
    final sessions = SessionManager(chat: fixture.chat);
    fixture.chat.sessionManager = sessions;
    final api = _Nf2SessionApi();
    fixture.chat.apiClient = api;
    final handler = _Nf2SessionHandler();
    fixture.chat.eventManager = EventManager(sessionManager: sessions)
      ..setSessionHandler(handler);
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await fixture.sockets.last.data('$_nf4SessionCommand${jsonEncode({
      _nf4ReasonField: SendbirdError.accessTokenRevoked,
    })}');
    await _flush(tester);
    final starts = fixture.starts;
    Object? failure;
    final pending = sessions.updateSessionKey().then<void>((_) {},
        onError: (Object error) { failure = error; });
    await _flush(tester);
    for (final response in api.responses) {
      response.complete({_sessionKeyField: _nf2StaleKey});
    }
    await _flush(tester);
    await pending;
    expect(failure, isA<SessionKeyRefreshFailedException>());
    expect(api.requests, _none);
    expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
    expect(fixture.starts, starts);
    expect(handler.events, [_nf2SessionClosed]);
    fixture.chat.eventManager.notifyAccessTokenRequired();
    final refreshed = handler.requester!.onSuccess(_nextAccessToken);
    await _flush(tester);
    expect(api.requests, _one);
    api.responses.last.complete({_sessionKeyField: _nextSessionKey});
    await _flush(tester);
    await refreshed;
    expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
    expect(handler.events, [_nf2SessionClosed, _nf2SessionRequired, _nf2SessionRefreshed]);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
  });

  for (final boundary in _Nf4LoginBoundary.values) {
    for (final requester in _hookModes) {
      for (final success in _hookModes) {
        testWidgets('NF4-I1 stale HTTP boundary=$boundary requester=$requester success=$success', (tester) async {
          final fixture = _Fixture(useCache: true, wallClock: tester.binding.clock.now);
          addTearDown(fixture.dispose);
          final sessions = SessionManager(chat: fixture.chat);
          fixture.chat.sessionManager = sessions;
          final api = _Nf2SessionApi();
          fixture.chat.apiClient = api;
          final handler = _Nf2SessionHandler();
          fixture.chat.eventManager = EventManager(sessionManager: sessions)
            ..setSessionHandler(handler);
          await fixture.connection.doReconnect(reset: true);
          await _flush(tester);
          await fixture.sockets.last.login();
          await _flush(tester);
          Object? failure;
          final old = (requester
              ? sessions.createAccessTokenRequester().onSuccess(_firstAccessToken)
              : sessions.updateSessionKey()).then<void>((_) {},
                  onError: (Object error) { failure = error; });
          await _flush(tester);
          final previousOwner = fixture.connection.authenticatedSessionIdentity;
          final db = fixture.chat.dbManager as _CachedDB;
          final save = Completer<void>();
          final returning = Completer<void>();
          db.saveBarrier = save;
          db.returnBarrier = returning;
          void respond() {
            if (success) {
              api.response.complete({_sessionKeyField: _nf2StaleKey});
            } else {
              api.response.completeError(NetworkErrorException());
            }
          }
          if (boundary == _Nf4LoginBoundary.applied) db.beforeSave = respond;
          if (boundary == _Nf4LoginBoundary.saved) db.afterSave = respond;
          var recovered = false;
          final recovery = fixture.connection.recoverTransport().then((result) {
            recovered = true;
            return result;
          });
          await _flush(tester);
          final socket = fixture.connection.socketIdentity;
          final starts = fixture.starts;
          final login = fixture.sockets.last.data('$_loginCommand${jsonEncode({
            ..._loginPayload, _sessionKeyField: _nextSessionKey,
          })}');
          await _flush(tester);
          if (boundary == _Nf4LoginBoundary.saving) respond();
          if (boundary == _Nf4LoginBoundary.saved) save.complete();
          await _flush(tester);
          await old;
          expect(recovered, isFalse);
          expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
          expect(fixture.connection.authenticatedSessionIdentity, isNot(same(previousOwner)));
          expect(fixture.connection.socketIdentity, same(socket));
          expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
          expect(fixture.starts, starts);
          expect(handler.events, isEmpty);
          if (!requester) expect(failure, isA<ConnectionCanceledException>());
          if (!save.isCompleted) save.complete();
          returning.complete();
          await _flush(tester);
          await login;
          expect(await recovery, TransportRecoveryResult.authenticated);
          expect(fixture.chat.chatContext.sessionKey, _nextSessionKey);
          expect(fixture.connection.isConnected(), isTrue);
        });
      }
    }
  }

  for (final success in _hookModes) {
    testWidgets('NF4-I1 requester callback is obsolete before login DB completes success=$success', (tester) async {
      final fixture = _Fixture(useCache: true, wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      final sessions = SessionManager(chat: fixture.chat);
      fixture.chat.sessionManager = sessions;
      final api = _Nf2SessionApi();
      fixture.chat.apiClient = api;
      final handler = _Nf2SessionHandler();
      fixture.chat.eventManager = EventManager(sessionManager: sessions)
        ..setSessionHandler(handler);
      fixture.chat.eventManager.notifyAccessTokenRequired();
      final requester = handler.requester!;
      final db = fixture.chat.dbManager as _CachedDB;
      final gate = Completer<void>();
      db.saveBarrier = gate;
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      final login = fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _sessionKeyField: _nextSessionKey,
      })}');
      await _flush(tester);
      final socket = fixture.connection.socketIdentity;
      final token = fixture.chat.chatContext.accessToken;
      if (success) {
        await requester.onSuccess(null);
      } else {
        await requester.onFail();
      }
      expect(api.requests, _none);
      expect(fixture.connection.socketIdentity, same(socket));
      expect(fixture.connection.getConnectionAttempt().authRequired, isFalse);
      expect(fixture.chat.chatContext.accessToken, token);
      expect(handler.events, [_nf2SessionRequired]);
      gate.complete();
      await _flush(tester);
      await login;
      expect(await recovery, TransportRecoveryResult.authenticated);
    });
  }

  for (final requester in _hookModes) {
    for (final success in _hookModes) {
      testWidgets('NF4-I2 revoked session rejects prior HTTP requester=$requester success=$success', (tester) async {
        final fixture = _Fixture(wallClock: tester.binding.clock.now);
        addTearDown(fixture.dispose);
        final sessions = SessionManager(chat: fixture.chat);
        fixture.chat.sessionManager = sessions;
        final api = _Nf2SessionApi();
        fixture.chat.apiClient = api;
        final handler = _Nf2SessionHandler();
        fixture.chat.eventManager = EventManager(sessionManager: sessions)
          ..setSessionHandler(handler);
        await fixture.connection.doReconnect(reset: true);
        await _flush(tester);
        await fixture.sockets.last.login();
        await _flush(tester);
        final errors = <Object>[];
        final waiting = sessions.updateSessionKey().then<void>((_) {},
            onError: (Object error) { errors.add(error); });
        final second = sessions.updateSessionKey().then<void>((_) {},
            onError: (Object error) { errors.add(error); });
        Future<void>? requested;
        if (requester) {
          fixture.chat.eventManager.notifyAccessTokenRequired();
          requested = handler.requester!.onSuccess(_nextAccessToken);
        }
        await _flush(tester);
        await fixture.sockets.last.data('$_nf4SessionCommand${jsonEncode({
          _nf4ReasonField: SendbirdError.accessTokenRevoked,
        })}');
        await _flush(tester);
        final socket = fixture.connection.socketIdentity;
        final starts = fixture.starts;
        final beforeResponse = List<Object>.of(errors);
        for (final response in api.responses) {
          if (success) {
            response.complete({_sessionKeyField: _nf2StaleKey});
          } else {
            response.completeError(NetworkErrorException());
          }
        }
        await _flush(tester);
        await Future.wait([waiting, second, if (requested != null) requested]);
        expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
        expect(fixture.chat.chatContext.sessionKey, isNull);
        expect(beforeResponse, hasLength(_two));
        expect(errors, everyElement(isA<ConnectionCanceledException>()));
        expect(fixture.connection.socketIdentity, same(socket));
        expect(fixture.connection.isDisconnected(), isTrue);
        expect(fixture.starts, starts);
        expect(handler.events, [if (requester) _nf2SessionRequired, _nf2SessionClosed]);
        expect(await fixture.connection.recoverTransport(), TransportRecoveryResult.authRequired);
        expect(await fixture.connection.doReconnect(reset: true), isFalse);
        expect(fixture.starts, starts);
      });
    }
  }

  for (final success in _hookModes) {
    for (final expired in _hookModes) {
      testWidgets('NF4-I2 revoke cancels rejected-token waiter and requester success=$success expired=$expired', (tester) async {
        final fixture = _Fixture(wallClock: tester.binding.clock.now);
        addTearDown(fixture.dispose);
        final sessions = SessionManager(chat: fixture.chat);
        fixture.chat.sessionManager = sessions;
        final api = _Nf2SessionApi();
        fixture.chat.apiClient = api;
        final handler = _Nf2SessionHandler();
        fixture.chat.eventManager = EventManager(sessionManager: sessions)
          ..setSessionHandler(handler);
        await fixture.connection.doReconnect(reset: true);
        await _flush(tester);
        await fixture.sockets.last.login();
        await _flush(tester);
        Object? failure;
        final waiting = sessions.updateSessionKey().then<void>((_) {},
            onError: (Object error) { failure = error; });
        await _flush(tester);
        api.response.completeError(SendbirdException(code: SendbirdError.accessTokenNotValid));
        await _flush(tester);
        expect(failure, isNull);
        final requester = handler.requester!;
        await fixture.chat.commandManager.processCommand(Command(cmd: _nf4SessionCommand, payload: {
          if (expired) _nf4ExpiresField: _nf4Expired,
          if (!expired) _nf4ReasonField: SendbirdError.accessTokenRevoked,
        }));
        await _flush(tester);
        if (success) {
          final stale = requester.onSuccess(_nextAccessToken);
          await _flush(tester);
          if (api.requests > _one) api.responses.last.complete({_sessionKeyField: _nf2StaleKey});
          await _flush(tester);
          await stale;
        } else {
          await requester.onFail();
        }
        await _flush(tester);
        await waiting;
        expect(failure, isA<ConnectionCanceledException>());
        expect(api.requests, _one);
        expect(handler.events, [_nf2SessionRequired, _nf2SessionClosed]);
        expect(fixture.connection.getConnectionAttempt().authRequired, isTrue);
        expect(fixture.chat.chatContext.accessToken, isNull);
      });
    }
  }

  for (final credentials in _Nf4Credentials.values) {
    testWidgets('NF4-I3 account cleanup after recovery authRequired credentials=$credentials', (tester) async {
      final fixture = _Fixture(wallClock: tester.binding.clock.now);
      addTearDown(fixture.dispose);
      await fixture.connection.doReconnect(reset: true);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      final channel = OpenChannel(channelUrl: _retainedChannel,
          participantCount: _none, operators: [])..set(fixture.chat);
      fixture.chat.channelCache.insert(channelKey: _retainedChannel, data: channel);
      final upload = AsyncSimpleTask(() async {});
      fixture.chat.uploadTaskMap[_ackRequestId] = upload;
      final queue = AsyncQueue();
      fixture.chat.setMessageQueue(_retainedChannel, queue);
      final queueGate = Completer<void>();
      final running = queue.enqueue(AsyncSimpleTask(() => queueGate.future));
      var queuedRan = false;
      final queued = queue.enqueue(AsyncSimpleTask(() async { queuedRan = true; }));
      final recovery = fixture.connection.recoverTransport();
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        _errorField: true, _codeField: SendbirdError.accessTokenRevoked,
      })}');
      expect(await recovery, TransportRecoveryResult.authRequired);
      expect(fixture.connection.isRecoveringTransport, isFalse);
      expect(fixture.connection.isDisconnected(), isTrue);
      final nextUser = credentials == _Nf4Credentials.user ? _nf3OtherUser : _userId;
      final nextToken = credentials == _Nf4Credentials.same ? null : _nextAccessToken;
      final connecting = fixture.connection.connect(nextUser, accessToken: nextToken);
      await _flush(tester);
      await fixture.sockets.last.data('$_loginCommand${jsonEncode({
        ..._loginPayload, _userIdField: nextUser, _sessionKeyField: _nextSessionKey,
      })}');
      expect((await connecting).userId, nextUser);
      if (credentials == _Nf4Credentials.same) {
        expect(fixture.chat.messageQueueMap[_retainedChannel], same(queue));
        expect(fixture.chat.uploadTaskMap[_ackRequestId], same(upload));
        expect(fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), same(channel));
      } else {
        expect(fixture.chat.messageQueueMap, isEmpty);
        expect(fixture.chat.uploadTaskMap, isEmpty);
        expect(fixture.chat.channelCache.find<OpenChannel>(channelKey: _retainedChannel), isNull);
      }
      queueGate.complete();
      await _flush(tester);
      await Future.wait([running, queued]);
      expect(queuedRan, credentials == _Nf4Credentials.same);
      expect(fixture.connection.isConnected(), isTrue);
    });
  }
}
