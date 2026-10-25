part of 'network_path_reconnect_test.dart';

const _backgroundDurations = [
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

void _registerBackgroundRecoveryTests() {
  testWidgets('W21 reconnect during LOGI wait keeps the active transport owner',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    final connecting = fixture.adapter.connectionSnapshot;
    expect(connecting.reconnecting, isTrue);
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    expect(fixture.channels.length, _one);
    expect(fixture.adapter.connectionSnapshot.sequence, connecting.sequence);
    fixture.channels.single.login();
    await _flush(tester);
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    expect(fixture.adapter.connectionSnapshot.sequence, connecting.sequence);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('W21 event sequence is captured before asynchronous delivery',
      (tester) async {
    final fixture = _Fixture();
    final first = fixture.connection.networkReconnect.createSdkAttempt();
    first.started();
    final firstSequence = fixture.adapter.connectionSnapshot.sequence;
    first.authenticated();
    final second = fixture.connection.networkReconnect.createSdkAttempt();
    final secondSequence = fixture.adapter.connectionSnapshot.sequence;
    first.closed();
    second.started();
    second.authenticated();
    await _flush(tester);
    final authenticated = fixture.authenticated.toList();
    expect(authenticated.first.sequence, firstSequence);
    expect(authenticated.last.sequence, secondSequence);
    expect(fixture.events.singleWhere((event) =>
        event.kind == NetworkReconnectEventKind.websocketClosed).sequence,
        isNull);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('W21 redundant reconnect preserves authenticated transport snapshot',
      (tester) async {
    final fixture = _Fixture(useTransport: true);
    expect(await fixture.connection.doReconnect(reset: true), isTrue);
    await _flush(tester);
    fixture.channels.single.login();
    await _flush(tester);
    final authenticated = fixture.adapter.connectionSnapshot;
    expect(authenticated.authenticated, isTrue);
    expect(await fixture.connection.reconnect(reset: true), isTrue);
    await _flush(tester);
    expect(fixture.channels.length, _one);
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    expect(fixture.adapter.connectionSnapshot.sequence, authenticated.sequence);
    expect(fixture.connection.isConnected(), isTrue);
    await fixture.connection.disconnect(logout: false);
    fixture.dispose();
    await _flush(tester);
  });

  for (final background in _backgroundDurations) {
    for (final loginBeforeBackgroundCompletes in _hookModes) {
      for (final waitForSocketClose in _hookModes) {
      testWidgets('W21 delayed background completion retains resumed transport '
          '$background login=$loginBeforeBackgroundCompletes close=$waitForSocketClose', (tester) async {
        final sdk = SendbirdChat.create();
        await sdk.init(appId: _appId,
            options: SendbirdChatOptions(useCollectionCaching: false));
        final fixture = _Fixture(chat: sdk.chat);
        expect(await fixture.connection.doReconnect(reset: true), isTrue);
        await _flush(tester);
        final firstSocket = fixture.sockets.single;
        await firstSocket.login();
        await _flush(tester);
        firstSocket.closed();
        await fixture.connection.doReconnect(reset: true);
        await _flush(tester);
        final barrier = Completer<void>();
        final closeBarrier = Completer<bool>();
        if (waitForSocketClose) {
          firstSocket.closeBarrier = closeBarrier;
        } else {
          fixture.dispatcher.disconnectBarrier = barrier;
        }
        final paused = sdk.chat.didChangeAppLifecycleState(AppLifecycleState.paused);
        await _flush(tester);
        await tester.pump(background);
        final resumed = sdk.chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await _flush(tester);
        final starts = fixture.starts;
        if (loginBeforeBackgroundCompletes) {
          await fixture.sockets.last.login();
          await _flush(tester);
        }
        barrier.complete();
        closeBarrier.complete(true);
        await paused;
        await resumed;
        await _flush(tester);
        if (!loginBeforeBackgroundCompletes) {
          await fixture.sockets.last.login();
          await _flush(tester);
        }
        expect(fixture.connection.isConnected(), isTrue);
        expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
        expect(fixture.starts, starts);
        await fixture.connection.disconnect(logout: false);
        fixture.dispose();
        await _flush(tester);
      });
      }
    }
  }
}
