part of 'network_path_reconnect_test.dart';

void registerNetworkReconnectLifecycleTests() {
  testWidgets('connection snapshot is synchronous and rejects superseded SDK authentication',
      (tester) async {
    final fixture = _Fixture();
    final manager = fixture.connection.networkReconnect;
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

  testWidgets('owned connection snapshot advances and explicit disconnect invalidates immediately',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final first = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final pending = fixture.adapter.connectionSnapshot;
    expect(pending.key, key);
    expect(pending.reconnecting, isTrue);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await first;
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    expect(fixture.adapter.connectionSnapshot.sequence, pending.sequence);
    final disconnect = fixture.connection.disconnect(logout: false);
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    await disconnect;
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
        event.kind == NetworkReconnectEventKind.reconnectStarted).length, _one);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  for (final hooksInstalled in _hookModes) {
    testWidgets('public reconnect retains real transport ACK and close hooks=$hooksInstalled',
        (tester) async {
      final sdk = SendbirdChat.create();
      await sdk.init(appId: _appId,
          options: SendbirdChatOptions(useCollectionCaching: false));
      final fixture = _Fixture(chat: sdk.chat, useTransport: true);
      sdk.setNetworkPathHooks(hooksInstalled ? _Hooks() : null);
      await expectLater(fixture.adapter.joinGeneration(_thirdGeneration),
          throwsA(isA<StateError>()));
      expect(await sdk.reconnect(), isTrue);
      await _flush(tester);
      final channel = fixture.channels.single;
      channel.login();
      await _flush(tester);
      final key = fixture.authenticated.single.key;
      expect(await sdk.reconnect(), isTrue);
      await expectLater(fixture.adapter.joinGeneration(_fourthGeneration),
          throwsA(isA<StateError>()));
      await _flush(tester);
      expect(fixture.channels.single, same(channel));
      expect(fixture.connection.webSocketClient.isConnected(), isTrue);
      expect(fixture.events.where((event) =>
          event.kind == NetworkReconnectEventKind.reconnectStarted).length, _one);
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
          event.kind == NetworkReconnectEventKind.websocketClosed)
          .single.key, key);
      expect(key.generation, _thirdGeneration);
      await tester.pump(_legacyReconnectDelay);
      await tester.pump(_statSettlingTick);
      await tester.pump(_legacyReconnectDelay);
      await _flush(tester);
      expect(fixture.channels.length, _two);
      fixture.channels.last.login();
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
      expect(fixture.authenticated.last.key.generation, _fourthGeneration);
      expect(fixture.authenticated.last.key.attempt, key.attempt + _one);
      await fixture.connection.disconnect(logout: false);
      fixture.dispose();
      await _flush(tester);
    });
  }

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
        event.kind == NetworkReconnectEventKind.websocketClosed).single.key, key);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary transport fixes generation at actual start after reservation',
      (tester) async {
    final fixture = _Fixture(useTransport: true, clock: () => Duration.zero);
    await expectLater(fixture.adapter.joinGeneration(_thirdGeneration),
        throwsA(isA<StateError>()));
    expect(await fixture.connection.doReconnect(), isTrue);
    await _flush(tester);
    expect(fixture.channels, isEmpty);
    final reservation = fixture.events.single;
    expect(reservation.kind, NetworkReconnectEventKind.reconnectScheduled);
    expect(reservation.key.generation, _thirdGeneration);
    await expectLater(fixture.adapter.joinGeneration(_fourthGeneration),
        throwsA(isA<StateError>()));
    await tester.pump(reservation.scheduledAt!);
    await _flush(tester);
    fixture.channels.single.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;
    expect(key.generation, _fourthGeneration);
    expect(key.attempt, NetworkReconnectAttempt.initialAttempt);
    expect(fixture.events.where((event) =>
        event.kind == NetworkReconnectEventKind.reconnectStarted).single.key, key);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('managed delayed login recovers after authenticated ping sink failure',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    fixture.chat.chatContext
      ..currentUser = null
      ..sessionKey = null
      ..pingInterval = _one;
    expect(fixture.chat.chatContext.currentUserId, _userId);
    final key = fixture.key();
    final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    final channel = fixture.channels.single;
    channel.login();
    await _flush(tester);
    await authentication;
    expect(fixture.connection.isConnected(), isTrue);
    channel.sink.failAdd = true;
    await tester.pump(_pingTick);
    await _flush(tester);
    expect(channel.sink.writes, contains(startsWith(_pingCommand)));
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.joinGeneration(key.generation),
        throwsA(isA<WebSocketFailedException>()));
    expect(fixture.events.where((event) => event.key == key)
        .map((event) => event.kind), [
      NetworkReconnectEventKind.reconnectScheduled,
      NetworkReconnectEventKind.reconnectStarted,
      NetworkReconnectEventKind.authenticated,
      NetworkReconnectEventKind.websocketClosed,
      NetworkReconnectEventKind.authenticationFailed,
    ]);
    expect(fixture.channels.length, _two);
    fixture.channels.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary socket keeps generation captured at connect through later joins',
      (tester) async {
    final fixture = _Fixture();
    await expectLater(fixture.adapter.joinGeneration(_thirdGeneration),
        throwsA(isA<StateError>()));
    final connected = fixture.connection.doConnect(_userId);
    await _flush(tester);
    final socket = fixture.sockets.single;
    await socket.login();
    await _flush(tester);
    await connected;
    final authenticated = fixture.authenticated.single;
    expect(authenticated.key.scope, NetworkReconnectAttempt.sdkScope);
    expect(authenticated.key.generation, _thirdGeneration);
    expect(authenticated.key.attempt, NetworkReconnectAttempt.initialAttempt);
    expect(authenticated.key.sdkInstance, same(fixture.chat.sdkInstance));
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.joinGeneration(_fourthGeneration),
        throwsA(isA<StateError>()));
    socket.closed();
    socket.closed();
    await _flush(tester);
    final closed = fixture.events.where(
        (event) => event.kind == NetworkReconnectEventKind.websocketClosed);
    expect(closed.length, _one);
    expect(closed.single.key, authenticated.key);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary socket defaults to generation zero and emits reconnect scheduling',
      (tester) async {
    final fixture = _Fixture();
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final socket = fixture.sockets.single;
    await socket.login();
    await _flush(tester);
    final event = fixture.authenticated.single;
    expect(event.key.scope, NetworkReconnectAttempt.sdkScope);
    expect(event.key.generation, _initialSdkGeneration);
    expect(event.key.attempt, NetworkReconnectAttempt.initialAttempt);
    expect(fixture.events.map((event) => event.kind), containsAllInOrder([
      NetworkReconnectEventKind.reconnectScheduled,
      NetworkReconnectEventKind.reconnectStarted,
      NetworkReconnectEventKind.authenticated,
    ]));
    expect(fixture.events.map((event) => event.key), everyElement(event.key));
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary transport error emits one terminal event with the captured key',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    fixture.chat.chatContext.pingInterval = _one;
    await expectLater(fixture.adapter.joinGeneration(_thirdGeneration),
        throwsA(isA<StateError>()));
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final channel = fixture.channels.single;
    channel.login();
    await _flush(tester);
    final key = fixture.authenticated.single.key;
    await expectLater(fixture.adapter.joinGeneration(_fourthGeneration),
        throwsA(isA<StateError>()));
    channel.sink.failAdd = true;
    await tester.pump(_pingTick);
    await _flush(tester);
    final failures = fixture.events.where((event) =>
        event.kind == NetworkReconnectEventKind.authenticationFailed);
    expect(failures.length, _one);
    expect(failures.single.key, key);
    expect(key.generation, _thirdGeneration);
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
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
    await expectLater(fixture.adapter.joinGeneration(_thirdGeneration),
        throwsA(isA<StateError>()));
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
    expect(key.generation, _thirdGeneration);
    expect(key.attempt, oldKey.attempt + _one);
    socket.closed();
    socket.closed();
    await _flush(tester);
    expect(fixture.events.where((event) =>
        event.kind == NetworkReconnectEventKind.websocketClosed).single.key, key);
    fixture.dispose();
    await _flush(tester);
  });

  for (final timeout in _closeFailureModes) {
    testWidgets('replacing authenticated lease propagates close failure timeout=$timeout',
        (tester) async {
      final fixture = _Fixture();
      final first = fixture.adapter.beginOrJoinReconnect(fixture.key(), fixture.deadline);
      await _flush(tester);
      final socket = fixture.sockets.last;
      await socket.login();
      await _flush(tester);
      await first;
      final barrier = Completer<bool>();
      socket.closeBarrier = barrier;
      final key = fixture.key(scope: _nextScope, generation: _nextGeneration);
      final matcher = timeout ? isA<TimeoutException>() : isA<WebSocketFailedException>();
      final failed = expectLater(fixture.adapter.closeWebsocket(key), throwsA(matcher));
      final authentication = expectLater(
          fixture.adapter.joinGeneration(key.generation), throwsA(matcher));
      if (timeout) {
        await tester.pump(_closeTimeout);
      } else {
        barrier.complete(false);
      }
      await failed;
      await authentication;
      await _flush(tester);
      expect(socket.closes, _one);
      expect(fixture.events.where((event) => event.key == key &&
          event.kind == NetworkReconnectEventKind.websocketClosed), isEmpty);
      expect(fixture.starts, _one);
      fixture.adapter.cancelScope(key.scope);
      if (timeout) barrier.complete(false);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('cancelAttempt releases authenticated lease before ordinary reconnect',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final first = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    final socket = fixture.sockets.last;
    await socket.login();
    await _flush(tester);
    await first;
    fixture.adapter.cancelAttempt(key);
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.joinGeneration(key.generation),
        throwsA(isA<ConnectionCanceledException>()));
    expect(await fixture.connection.reconnect(reset: true), isTrue);
    await _flush(tester);
    expect(fixture.starts, _two);
    expect(fixture.sockets.last, isNot(same(socket)));
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('cancelAttempt releases authenticated lease before managed retry',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final first = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await first;
    fixture.adapter.cancelAttempt(key);
    final retryKey = fixture.key(attempt: NetworkReconnectAttempt.retryAttempt);
    var completed = false;
    final retry = fixture.adapter.retryReconnect(retryKey, fixture.deadline)
        .then((_) => completed = true);
    await _flush(tester);
    expect(fixture.starts, _two);
    expect(completed, isFalse);
    await fixture.sockets.last.login();
    await _flush(tester);
    await retry;
    expect(fixture.authenticated.last.key, retryKey);
    fixture.adapter.cancelAttempt(retryKey);
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.retryReconnect(retryKey, fixture.deadline),
        throwsA(isA<ConnectionCanceledException>()));
    await expectLater(fixture.adapter.joinGeneration(key.generation),
        throwsA(isA<ConnectionCanceledException>()));
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('authenticated ping sink failure releases lease and starts SDK recovery',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    fixture.chat.chatContext.pingInterval = _one;
    final key = fixture.key();
    final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    final channel = fixture.channels.single;
    channel.login();
    await _flush(tester);
    await authentication;
    channel.sink.failAdd = true;
    await tester.pump(_pingTick);
    await _flush(tester);
    expect(channel.sink.writes, contains(startsWith(_pingCommand)));
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.joinGeneration(key.generation),
        throwsA(isA<WebSocketFailedException>()));
    expect(fixture.events.map((event) => event.kind), containsAllInOrder([
      NetworkReconnectEventKind.authenticated,
      NetworkReconnectEventKind.websocketClosed,
      NetworkReconnectEventKind.authenticationFailed,
    ]));
    expect(fixture.channels.length, _two);
    fixture.channels.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('connect and reconnect during the two SDK closes await authentication',
      (tester) async {
    final first = _Fixture();
    final second = _Fixture();
    final key = first.key();
    await first.adapter.closeWebsocket(key);
    var connected = false;
    var reconnected = false;
    final connect = first.connection.connect(_userId).then((_) => connected = true);
    final reconnect = first.connection.reconnect(reset: true)
        .then((_) => reconnected = true);
    await _flush(tester);
    expect(connected, isFalse);
    expect(reconnected, isFalse);
    expect(first.starts, _none);
    await second.adapter.closeWebsocket(second.key());
    final authentication = first.adapter.beginOrJoinReconnect(key, first.deadline);
    await _flush(tester);
    expect(connected, isFalse);
    expect(reconnected, isFalse);
    await first.sockets.last.login();
    await _flush(tester);
    await Future.wait([authentication, connect, reconnect]);
    expect(connected, isTrue);
    expect(reconnected, isTrue);
    first.dispose();
    second.dispose();
    await _flush(tester);
  });

  testWidgets('new close joins its own authentication instead of the old successful lease',
      (tester) async {
    final fixture = _Fixture();
    final first = fixture.adapter.beginOrJoinReconnect(fixture.key(), fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await first;
    final key = fixture.key(scope: _nextScope, generation: _nextGeneration);
    await fixture.adapter.closeWebsocket(key);
    var completed = false;
    final joined = fixture.connection.reconnect(reset: true)
        .then((_) => completed = true);
    await _flush(tester);
    expect(completed, isFalse);
    final next = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    expect(completed, isFalse);
    await fixture.sockets.last.login();
    await _flush(tester);
    await Future.wait([next, joined]);
    expect(completed, isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  for (final timeout in _closeFailureModes) {
    testWidgets('close failure timeout=$timeout does not poison later managed or ordinary reconnect',
        (tester) async {
      final fixture = _Fixture();
      final key = fixture.key();
      final barrier = Completer<bool>();
      fixture.sockets.single.closeBarrier = barrier;
      final failed = expectLater(fixture.adapter.closeWebsocket(key),
          throwsA(timeout ? isA<TimeoutException>() : isA<WebSocketFailedException>()));
      if (timeout) {
        await tester.pump(_closeTimeout);
      } else {
        barrier.complete(false);
      }
      await failed;
      fixture.adapter.cancelScope(key.scope);
      final nextKey = fixture.key(scope: _nextScope, generation: _nextGeneration);
      final next = fixture.adapter.beginOrJoinReconnect(nextKey, fixture.deadline);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      await next;
      fixture.adapter.cancelScope(nextKey.scope);
      expect(await fixture.connection.doReconnect(reset: true), isTrue);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
      if (timeout) barrier.complete(false);
      fixture.dispose();
      fixture.connection.cancelReconnectTimers();
      await _flush(tester);
    });
  }

  testWidgets('new generation waits for an older failed close to settle without inheriting failure',
      (tester) async {
    final fixture = _Fixture();
    final oldKey = fixture.key();
    final barrier = Completer<bool>();
    fixture.sockets.single.closeBarrier = barrier;
    final failed = expectLater(fixture.adapter.closeWebsocket(oldKey),
        throwsA(isA<WebSocketFailedException>()));
    fixture.adapter.cancelScope(oldKey.scope);
    final key = fixture.key(scope: _nextScope, generation: _nextGeneration);
    final next = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    expect(fixture.starts, _none);
    barrier.complete(false);
    await failed;
    await _flush(tester);
    expect(fixture.starts, _one);
    await fixture.sockets.last.login();
    await _flush(tester);
    await next;
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('ordinary connect can authenticate after a failed close is cancelled',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final barrier = Completer<bool>();
    fixture.sockets.single.closeBarrier = barrier;
    final failed = expectLater(fixture.adapter.closeWebsocket(key),
        throwsA(isA<WebSocketFailedException>()));
    barrier.complete(false);
    await failed;
    fixture.adapter.cancelScope(key.scope);
    final connected = fixture.connection.doConnect(_userId);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect((await connected).userId, _userId);
    fixture.dispose();
    await _flush(tester);
  });

  for (final action in _cancelActions) {
    for (final recoveryStarted in _recoveryStartedModes) {
      testWidgets('$action cancels released scope recovery started=$recoveryStarted',
          (tester) async {
        final sdk = SendbirdChat.create();
        await sdk.init(appId: _appId,
            options: SendbirdChatOptions(useCollectionCaching: false));
        final fixture = _Fixture(chat: sdk.chat);
        final key = fixture.key();
        final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
        await _flush(tester);
        await fixture.sockets.last.login();
        await _flush(tester);
        await authentication;
        fixture.sockets.last.closed();
        await _flush(tester);
        if (recoveryStarted) {
          await tester.pump(_legacyReconnectDelay);
          await _flush(tester);
        }
        final starts = fixture.starts;
        final socket = fixture.sockets.last;
        if (action == _cancelAction) {
          fixture.adapter.cancelScope(key.scope);
        } else if (action == _logoutAction) {
          await fixture.connection.disconnect(logout: true);
        } else {
          await sdk.init(appId: _appId,
              options: SendbirdChatOptions(useCollectionCaching: false));
        }
        await tester.pump(_legacyReconnectDelay);
        await _flush(tester);
        expect(fixture.starts, starts);
        expect(socket.closes, _one);
        expect(fixture.connection.reconnectTimer, isNull);
        expect(fixture.connection.isDisconnected(), isTrue);
        await socket.login();
        await _flush(tester);
        expect(fixture.authenticated.length, _one);
        fixture.dispose();
        await _flush(tester);
      });
    }
  }

  testWidgets('post authentication command error releases lease and recovers',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await authentication;
    await fixture.sockets.last.data(_invalidUpdateCommand);
    await _flush(tester);
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.joinGeneration(key.generation), throwsA(anything));
    expect(fixture.events.map((event) => event.kind), containsAllInOrder([
      NetworkReconnectEventKind.authenticated,
      NetworkReconnectEventKind.websocketClosed,
      NetworkReconnectEventKind.authenticationFailed,
    ]));
    expect(fixture.starts, _two);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('cancelAttempt stops SDK recovery after an authenticated socket closes',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await authentication;
    fixture.sockets.last.closed();
    fixture.adapter.cancelAttempt(key);
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    expect(fixture.starts, _one);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('cancelScope invalidates SDK recovery already awaiting disconnect dispatch',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await authentication;
    final barrier = Completer<void>();
    fixture.dispatcher.disconnectBarrier = barrier;
    final recovery = fixture.sockets.last.error(WebSocketFailedException());
    await _flush(tester);
    fixture.adapter.cancelScope(key.scope);
    barrier.complete();
    await recovery;
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(fixture.connection.isDisconnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('cancelled retained lease cannot regain ownership after scope FIFO eviction',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await authentication;
    fixture.adapter.cancelScope(key.scope);
    for (var index = _none; index < _scopeHistoryLimit; index++) {
      fixture.adapter.cancelScope('$_scopeHistoryPrefix$index');
    }
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    await expectLater(fixture.adapter.joinGeneration(key.generation),
        throwsA(isA<ConnectionCanceledException>()));
    await expectLater(fixture.adapter.closeWebsocket(key),
        throwsA(isA<ConnectionCanceledException>()));
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('history retains two generations and rejects evicted generation reuse',
      (tester) async {
    final fixture = _Fixture();
    final keys = [fixture.key(),
      fixture.key(scope: _nextScope, generation: _nextGeneration),
      fixture.key(scope: _thirdScope, generation: _thirdGeneration)];
    for (final key in keys) {
      final authentication = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      await authentication;
    }
    await expectLater(fixture.adapter.joinGeneration(_firstGeneration),
        throwsA(isA<StateError>()));
    await expectLater(fixture.adapter.beginOrJoinReconnect(keys.first, fixture.deadline),
        throwsA(isA<ConnectionCanceledException>()));
    expect(identical(fixture.adapter.beginOrJoinReconnect(keys.last, fixture.deadline),
        fixture.adapter.joinGeneration(_thirdGeneration)), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

}
