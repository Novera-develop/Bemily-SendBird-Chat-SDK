import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/db.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/login/login.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/reconnect_task.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_context/chat_context.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/db_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/device_token_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/event_dispatcher.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/session_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/disconnected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/reconnecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/stats/stat_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/event/login_event.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:web_socket_channel/web_socket_channel.dart';

part 'support/network_reconnect_fixture.dart';
part 'network_path_reconnect_lifecycle_cases.dart';
part 'network_path_credentials_cases.dart';
part 'network_path_session_ownership_cases.dart';
part 'network_path_background_recovery_cases.dart';

enum _CancellationPhase { scheduled, dispatcher, session, delayedParameters }

void main() {
  _registerBackgroundRecoveryTests();
  _registerSessionOwnershipTests();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    await SendbirdChat().init(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false));
  });

  for (final guardOnly in [false, true]) {
    testWidgets('W22 fix5 reconnect close gate cancels guardOnly=$guardOnly', (tester) async {
      final fixture = _Fixture();
      final gate = Completer<bool>();
      fixture.sockets.single.closeBarrier = gate;
      var foreground = true;
      final pending = fixture.connection.reconnectForNetworkChange(
          shouldProceed: () => foreground);
      await _flush(tester);
      Future<void>? paused;
      if (guardOnly) {
        foreground = false;
      } else {
        paused = fixture.chat.didChangeAppLifecycleState(AppLifecycleState.paused);
        await _flush(tester);
      }
      gate.complete(true);
      await pending;
      await paused;
      await _flush(tester);
      expect(fixture.starts, _none);
      fixture.sockets.single.closeBarrier = null;
      foreground = true;
      await fixture.chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await fixture.connection.reconnectForNetworkChange(shouldProceed: () => foreground);
      await _flush(tester);
      expect(fixture.starts, _one);
      await fixture.sockets.last.login();
      await _flush(tester);
      expect(fixture.connection.isConnected(), isTrue);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('W22 fix5 reconnect session wait keeps foreground cancellation', (tester) async {
    final fixture = _Fixture();
    final gate = Completer<String?>();
    fixture.sessions.barrier = gate;
    var foreground = true;
    await fixture.connection.reconnectForNetworkChange(shouldProceed: () => foreground);
    await _flush(tester);
    expect(fixture.starts, _none);
    foreground = false;
    gate.complete(_userId);
    await _flush(tester);
    expect(fixture.starts, _none);
    fixture.sessions.barrier = null;
    foreground = true;
    await fixture.connection.reconnectForNetworkChange(shouldProceed: () => foreground);
    await _flush(tester);
    expect(fixture.starts, _one);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  for (final phase in _CancellationPhase.values) {
    testWidgets('W22 fix6 cancelled reservation releases state at $phase', (tester) async {
      var allowed = true;
      final fixture = _Fixture(onLoginInfo: () {
        if (phase == _CancellationPhase.delayedParameters) allowed = false;
      });
      addTearDown(fixture.dispose);
      final reconnectGate = Completer<void>();
      final sessionGate = Completer<String?>();
      if (phase == _CancellationPhase.dispatcher) {
        fixture.dispatcher.reconnectingBarrier = reconnectGate;
      }
      if (phase == _CancellationPhase.session) fixture.sessions.barrier = sessionGate;
      if (phase == _CancellationPhase.delayedParameters) {
        fixture.chat.chatContext.currentUser = null;
        fixture.chat.chatContext.sessionKey = null;
      }
      await fixture.connection.doReconnect(reset: true, shouldProceed: () => allowed);
      final reserved = fixture.adapter.connectionSnapshot;
      expect(reserved.reconnecting, isTrue);
      if (phase == _CancellationPhase.scheduled) allowed = false;
      await _flush(tester);
      allowed = false;
      reconnectGate.complete();
      sessionGate.complete(_userId);
      await _flush(tester);
      expect(fixture.starts, _none);
      expect(fixture.connection.isDisconnected(), isTrue);
      expect(fixture.adapter.connectionSnapshot.key, reserved.key);
      expect(fixture.adapter.connectionSnapshot.sequence, reserved.sequence);
      expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
      expect(fixture.adapter.connectionSnapshot.reconnecting, isFalse);
      expect(fixture.events.last.kind, NetworkReconnectEventKind.authenticationFailed);
      expect(fixture.events.last.error, isA<ConnectionCanceledException>());
      expect(fixture.connection.reconnectTimer, isNull);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('W22 fix6 cancelled reservation preserves authenticated transport', (tester) async {
    final fixture = _Fixture();
    await fixture.connection.doReconnect(reset: true);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    final current = fixture.adapter.connectionSnapshot;
    var allowed = true;
    await fixture.connection.doReconnect(reset: true, shouldProceed: () => allowed);
    allowed = false;
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    expect(fixture.adapter.connectionSnapshot.key, current.key);
    expect(fixture.adapter.connectionSnapshot.sequence, current.sequence);
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    expect(fixture.adapter.connectionSnapshot.reconnecting, isFalse);
    expect(fixture.starts, _one);
    fixture.dispose();
    await _flush(tester);
  });

  for (final owned in [false, true]) {
    for (final pending in [false, true]) {
    testWidgets('W22 fix6 late cancellation preserves replacement owned=$owned pending=$pending', (tester) async {
      final fixture = _Fixture();
      final gate = Completer<String?>();
      fixture.sessions.barrier = gate;
      var allowed = true;
      await fixture.connection.doReconnect(reset: true, shouldProceed: () => allowed);
      await _flush(tester);
      final nextGate = Completer<String?>();
      fixture.sessions.barrier = pending ? nextGate : null;
      final replacement = owned
          ? fixture.adapter.beginOrJoinReconnect(fixture.key(), fixture.deadline)
          : fixture.connection.doReconnect(reset: true).then<void>((_) {});
      await _flush(tester);
      final current = fixture.adapter.connectionSnapshot;
      allowed = false;
      gate.complete(_userId);
      await _flush(tester);
      expect(fixture.connection.isReconnecting(), isTrue);
      expect(fixture.adapter.connectionSnapshot.key, current.key);
      expect(fixture.adapter.connectionSnapshot.reconnecting, isTrue);
      expect(fixture.starts, pending ? _none : _one);
      expect(fixture.events.where((event) =>
          event.kind == NetworkReconnectEventKind.authenticationFailed), isEmpty);
      nextGate.complete(_userId);
      await _flush(tester);
      expect(fixture.starts, _one);
      await fixture.sockets.last.login();
      await _flush(tester);
      await replacement;
      expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
      fixture.dispose();
      await _flush(tester);
    });
  }
  }

  testWidgets('installed hooks own online and offline connectivity events',
      (tester) async {
    final fixture = _Fixture();
    final hooks = _Hooks();
    fixture.chat.networkPathHooks = hooks;
    await fixture.chat.handleConnectivityResults([
      ConnectivityResult.wifi, ConnectivityResult.mobile, ConnectivityResult.vpn,
    ]);
    await fixture.chat.handleConnectivityResults([ConnectivityResult.none]);
    await _flush(tester);
    expect(hooks.instances, everyElement(same(fixture.chat.sdkInstance)));
    expect(hooks.online, [true, false]);
    expect(hooks.wifi, [true, false]);
    expect(hooks.cellular, [true, false]);
    expect(hooks.vpn, [true, false]);
    expect(fixture.starts, _none);
    expect(fixture.sockets.single.closes, _none);
    fixture.dispose();
  });

  testWidgets('without hooks connectivity preserves direct reconnect',
      (tester) async {
    final fixture = _Fixture();
    await fixture.chat.handleConnectivityResults([ConnectivityResult.wifi]);
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(fixture.sockets.single.closes, _one);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('observing DIRECT hook preserves one SDK reconnect during handover',
      (tester) async {
    final fixture = _Fixture();
    fixture.chat.networkPathHooks = _Hooks(ownsReconnect: false);
    await fixture.chat.handleConnectivityResults([ConnectivityResult.mobile]);
    await _flush(tester);
    expect(fixture.starts, _one);
    await fixture.chat.handleConnectivityResults([ConnectivityResult.mobile]);
    await _flush(tester);
    expect(fixture.starts, _one);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.authenticated.length, _one);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('same generation and external reconnect share one authenticated future',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final joined = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    expect(identical(future, joined), isTrue);
    expect(identical(future, fixture.adapter.joinGeneration(key.generation)), isTrue);
    var completed = false;
    future.then((_) => completed = true);
    final external = fixture.connection.reconnectForNetworkChange();
    final externalBackoff = fixture.connection.doReconnect();
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(completed, isFalse);
    final barrier = Completer<void>();
    fixture.dispatcher.barrier = barrier;
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    expect(completed, isFalse);
    barrier.complete();
    await _flush(tester);
    await future;
    await external;
    expect(await externalBackoff, isTrue);
    expect(fixture.events.map((event) => event.kind), containsAllInOrder([
      NetworkReconnectEventKind.reconnectScheduled,
      NetworkReconnectEventKind.reconnectStarted,
      NetworkReconnectEventKind.authenticated,
    ]));
    expect(fixture.events.map((event) => event.key), everyElement(key));
    expect(fixture.handler.keys, [key]);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('closed owned attempt cannot authenticate again with the same key',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final connected = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await connected;
    expect(fixture.adapter.connectionSnapshot.authenticated, isTrue);
    fixture.sockets.last.closed();
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    fixture.connection.networkReconnect.authenticated(key);
    expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
    await _flush(tester);
    expect(fixture.authenticated.length, _one);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('old login retains its socket key across awaits and cannot authenticate a new generation',
      (tester) async {
    final fixture = _Fixture();
    final oldKey = fixture.key();
    final first = fixture.adapter.beginOrJoinReconnect(oldKey, fixture.deadline);
    final cancelled = expectLater(first, throwsA(isA<ConnectionCanceledException>()));
    await _flush(tester);
    final oldSocket = fixture.sockets.last;
    final barrier = Completer<void>();
    fixture.dispatcher.barrier = barrier;
    await oldSocket.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    final newKey = fixture.key(scope: _nextScope, generation: _nextGeneration);
    final second = fixture.adapter.beginOrJoinReconnect(newKey, fixture.deadline);
    await _flush(tester);
    await cancelled;
    barrier.complete();
    fixture.dispatcher.barrier = null;
    await _flush(tester);
    expect(fixture.dispatcher.completedKeys, [oldKey]);
    expect(fixture.authenticated, isEmpty);
    await oldSocket.login();
    await _flush(tester);
    expect(fixture.authenticated, isEmpty);
    await fixture.sockets.last.login();
    await _flush(tester);
    await second;
    expect(fixture.authenticated.map((event) => event.key), [newKey]);
    expect(fixture.handler.keys, [newKey]);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('cancelScope cancels backoff, connecting socket and late authentication',
      (tester) async {
    final fixture = _Fixture();
    final oldSocket = fixture.sockets.single;
    oldSocket.connected = false;
    oldSocket.closed();
    final key = fixture.key();
    final result = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final failed = expectLater(result, throwsA(isA<ConnectionCanceledException>()));
    await _flush(tester);
    final connecting = fixture.sockets.last;
    fixture.adapter.cancelScope(key.scope);
    fixture.adapter.cancelScope(key.scope);
    await failed;
    await connecting.login();
    await tester.pump(_afterDeadline);
    expect(fixture.starts, _one);
    expect(connecting.closes, _one);
    expect(fixture.connection.reconnectTimer, isNull);
    expect(fixture.authenticated, isEmpty);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('cancel before connection starts prevents any socket attempt',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final failed = expectLater(future, throwsA(isA<ConnectionCanceledException>()));
    fixture.adapter.cancelScope(key.scope);
    await tester.pump(_afterDeadline);
    await failed;
    expect(fixture.starts, _none);
    expect(fixture.connection.reconnectTimer, isNull);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('deadline fails and closes the connection rather than leaving a timed out future',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final failed = expectLater(future, throwsA(isA<TimeoutException>()));
    await _flush(tester);
    final socket = fixture.sockets.last;
    await tester.pump(_afterDeadline);
    await failed;
    expect(socket.closes, _one);
    await socket.login();
    await _flush(tester);
    expect(fixture.authenticated, isEmpty);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('retry replaces only the attempt and is idempotent', (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final first = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final failed = expectLater(first, throwsA(isA<WebSocketFailedException>()));
    await _flush(tester);
    final oldSocket = fixture.sockets.last;
    await oldSocket.error(WebSocketFailedException());
    await failed;
    final retryKey = fixture.key(attempt: NetworkReconnectAttempt.retryAttempt);
    final retry = fixture.adapter.retryReconnect(retryKey, fixture.deadline);
    expect(identical(retry,
        fixture.adapter.retryReconnect(retryKey, fixture.deadline)), isTrue);
    await _flush(tester);
    expect(fixture.starts, _two);
    await oldSocket.login();
    await _flush(tester);
    expect(fixture.authenticated, isEmpty);
    await fixture.sockets.last.login();
    await _flush(tester);
    await retry;
    expect(fixture.authenticated.single.key, retryKey);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('explicit close is idempotent and emits the complete transition key',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final close = fixture.adapter.closeWebsocket(key);
    expect(identical(close, fixture.adapter.closeWebsocket(key)), isTrue);
    await close;
    await _flush(tester);
    expect(fixture.events.single.kind, NetworkReconnectEventKind.websocketClosed);
    expect(fixture.events.single.key, key);
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    expect(fixture.sockets.first.closes, _one);
    await fixture.sockets.last.login();
    await _flush(tester);
    await future;
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('instances cannot join or cancel one another', (tester) async {
    final first = _Fixture();
    final second = _Fixture();
    final key = first.key();
    final future = first.adapter.beginOrJoinReconnect(key, first.deadline);
    expect(() => second.adapter.beginOrJoinReconnect(key, second.deadline),
        throwsArgumentError);
    second.adapter.cancelScope(key.scope);
    await _flush(tester);
    await first.sockets.last.login();
    await _flush(tester);
    await future;
    expect(second.starts, _none);
    first.dispose();
    second.dispose();
    await _flush(tester);
  });

  testWidgets('cancelling a pending close fails its future and closes the socket once',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final socket = fixture.sockets.single;
    final barrier = Completer<bool>();
    socket.closeBarrier = barrier;
    final close = fixture.adapter.closeWebsocket(key);
    final failed = expectLater(close, throwsA(isA<ConnectionCanceledException>()));
    fixture.adapter.cancelScope(key.scope);
    fixture.adapter.cancelScope(key.scope);
    barrier.complete(true);
    await failed;
    await _flush(tester);
    expect(socket.closes, _one);
    expect(fixture.events, isEmpty);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('public hooks installed before init retain the SDK instance identity',
      (tester) async {
    final sdk = SendbirdChat.create();
    final other = SendbirdChat.create();
    final hooks = _Hooks();
    sdk.setNetworkPathHooks(hooks);
    await sdk.init(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false));
    await other.init(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false));
    await sdk.chat.handleConnectivityResults([ConnectivityResult.wifi]);
    expect(hooks.instances.single, same(sdk));
    expect(sdk.networkReconnectAdapter.sdkInstance, same(sdk));
    expect(other.chat.networkPathHooks, isNull);
    sdk.setNetworkPathHooks(null);
    expect(sdk.chat.networkPathHooks, isNull);
  });

  testWidgets('authentication error commands fail the original attempt',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final failed = expectLater(future, throwsA(isA<SendbirdException>().having(
        (error) => error.code, _codeField, SendbirdError.accessTokenNotValid)));
    await _flush(tester);
    await fixture.sockets.last.data('$_errorCommand${jsonEncode(_authErrorPayload)}');
    await failed;
    await _flush(tester);
    expect(fixture.events.last.kind, NetworkReconnectEventKind.authenticationFailed);
    expect(fixture.events.last.key, key);
    expect(fixture.starts, _one);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('expired clock rejects login before the deadline timer gets a turn',
      (tester) async {
    var now = Duration.zero;
    final fixture = _Fixture(clock: () => now);
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    final failed = expectLater(future, throwsA(isA<TimeoutException>()));
    await _flush(tester);
    now = _afterDeadline;
    await fixture.sockets.last.login();
    await failed;
    await _flush(tester);
    expect(fixture.authenticated, isEmpty);
    expect(fixture.handler.keys, isEmpty);
    expect(fixture.connection.isDisconnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('onConnected uses the captured key through login postprocessing',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    fixture.chat.chatContext.loginCompleter = Completer<User>();
    fixture.connection.changeState(ConnectingState(chat: fixture.chat));
    final barrier = Completer<void>();
    fixture.dispatcher.barrier = barrier;
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.authenticated, isEmpty);
    barrier.complete();
    await _flush(tester);
    await future;
    expect(fixture.handler.keys, [key]);
    expect(fixture.handler.connectedUsers, [_userId]);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('resetBackoff and repeated begin cannot start a second socket',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    fixture.adapter.resetBackoff(key, fixture.deadline);
    fixture.adapter.resetBackoff(key, fixture.deadline);
    expect(identical(future,
        fixture.adapter.beginOrJoinReconnect(key, fixture.deadline)), isTrue);
    await _flush(tester);
    expect(fixture.starts, _one);
    await fixture.sockets.last.login();
    await _flush(tester);
    await future;
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('a later close releases a successful lease and resumes SDK recovery',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    final socket = fixture.sockets.last;
    await socket.login();
    await _flush(tester);
    await future;
    socket.closed();
    await _flush(tester);
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    final closeEvent = fixture.events.firstWhere(
        (event) => event.kind == NetworkReconnectEventKind.websocketClosed);
    expect(closeEvent.key, key);
    await expectLater(fixture.adapter.joinGeneration(key.generation),
        throwsA(isA<WebSocketFailedException>()));
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    expect(fixture.starts, _two);
    expect(fixture.sockets.last, isNot(same(socket)));
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('controller retry preempts SDK recovery after a successful lease loses its socket',
      (tester) async {
    final fixture = _Fixture();
    final key = fixture.key();
    final future = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    await fixture.sockets.last.login();
    await _flush(tester);
    await future;
    fixture.sockets.last.closed();
    await _flush(tester);
    final retryKey = fixture.key(attempt: NetworkReconnectAttempt.retryAttempt);
    final retry = fixture.adapter.retryReconnect(retryKey, fixture.deadline);
    await _flush(tester);
    expect(fixture.connection.networkReconnect.ownsReconnect, isTrue);
    expect(fixture.starts, _two);
    await tester.pump(_legacyReconnectDelay);
    await _flush(tester);
    expect(fixture.starts, _two);
    await fixture.sockets.last.login();
    await _flush(tester);
    await retry;
    expect(fixture.authenticated.last.key, retryKey);
    fixture.dispose();
    await _flush(tester);
  });
  for (final authenticated in _recoveryStartedModes) {
    testWidgets('changed token releases managed lease authenticated=$authenticated',
        (tester) async {
      final fixture = _Fixture();
      fixture.chat.networkPathHooks = _Hooks();
      fixture.chat.chatContext.accessToken = _firstAccessToken;
      final key = fixture.key();
      final recovery = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
      final cancelled = authenticated ? null : expectLater(
          recovery, throwsA(isA<ConnectionCanceledException>()));
      await _flush(tester);
      final managed = fixture.sockets.last;
      if (authenticated) {
        await managed.login();
        await _flush(tester);
        await recovery;
      }
      final closeBarrier = Completer<bool>();
      managed.closeBarrier = closeBarrier;
      var completed = false;
      final replacement = fixture.chat.connect(_userId,
          accessToken: _nextAccessToken).then((user) {
        completed = true;
        return user;
      });
      await _flush(tester);
      expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
      expect(fixture.connection.reconnectTimer, isNull);
      expect(managed.closes, _one);
      expect(completed, isFalse);
      expect(fixture.starts, _one);
      closeBarrier.complete(true);
      await _flush(tester);
      if (cancelled != null) await cancelled;
      expect(fixture.starts, _two);
      final ordinary = fixture.sockets.last;
      expect(ordinary, isNot(same(managed)));
      expect(ordinary.loginAccessToken, _nextAccessToken);
      expect(ordinary.loginSessionKey, isNull);
      await managed.login();
      await _flush(tester);
      expect(completed, isFalse);
      await ordinary.login();
      await _flush(tester);
      expect((await replacement).userId, _userId);
      expect(fixture.chat.chatContext.accessToken, _nextAccessToken);
      await expectLater(fixture.adapter.joinGeneration(key.generation),
          throwsA(isA<ConnectionCanceledException>()));
      await tester.pump(_afterDeadline);
      expect(fixture.starts, _two);
      fixture.dispose();
      await _flush(tester);
    });

    testWidgets('same credentials join managed lease authenticated=$authenticated',
        (tester) async {
      final fixture = _Fixture();
      fixture.chat.networkPathHooks = _Hooks();
      fixture.chat.chatContext.accessToken = _firstAccessToken;
      final key = fixture.key();
      final recovery = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
      await _flush(tester);
      if (authenticated) {
        await fixture.sockets.last.login();
        await _flush(tester);
        await recovery;
      }
      var completed = false;
      final joined = fixture.chat.connect(_userId,
          accessToken: _firstAccessToken).then((user) {
        completed = true;
        return user;
      });
      await _flush(tester);
      expect(completed, authenticated);
      expect(fixture.connection.networkReconnect.ownsReconnect, isTrue);
      expect(fixture.adapter.joinGeneration(key.generation), same(recovery));
      expect(fixture.starts, _one);
      expect(fixture.sockets.last.closes, _none);
      if (!authenticated) {
        await fixture.sockets.last.login();
        await _flush(tester);
      }
      await recovery;
      expect((await joined).userId, _userId);
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('same credentials join while LOGI postprocessing rotates session key',
      (tester) async {
    final fixture = _Fixture();
    fixture.chat.chatContext.accessToken = _firstAccessToken;
    final key = fixture.key();
    final recovery = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
    await _flush(tester);
    final barrier = Completer<void>();
    fixture.dispatcher.barrier = barrier;
    await fixture.sockets.last.login();
    await _flush(tester);
    var completed = false;
    final joined = fixture.chat.connect(_userId,
        accessToken: _firstAccessToken).then((_) => completed = true);
    await _flush(tester);
    expect(completed, isFalse);
    expect(fixture.starts, _one);
    barrier.complete();
    await _flush(tester);
    await Future.wait([recovery, joined]);
    expect(fixture.connection.networkReconnect.ownsReconnect, isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  for (final field in _credentialFields) {
    testWidgets('changed $field cannot reuse authenticated credentials',
        (tester) async {
      final fixture = _Fixture();
      fixture.chat.chatContext.accessToken = _firstAccessToken;
      final key = fixture.key();
      final recovery = fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
      await _flush(tester);
      await fixture.sockets.last.login();
      await _flush(tester);
      await recovery;
      if (field == _credentialFields[_sessionKeyIndex]) {
        fixture.chat.chatContext.sessionKey = _nextSessionKey;
      }
      final replacement = fixture.chat.connect(_userId,
          accessToken: _firstAccessToken,
          apiHost: field == _credentialFields[_apiHostIndex] ? _nextApiHost : null,
          wsHost: field == _credentialFields[_wsHostIndex] ? _nextWsHost : null,
          nickname: field == _credentialFields[_nicknameIndex] ? _nextNickname : null);
      await _flush(tester);
      expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
      expect(fixture.starts, _two);
      expect(fixture.sockets.last.loginAccessToken, _firstAccessToken);
      expect(fixture.sockets.last.loginSessionKey, isNull);
      if (field == _credentialFields[_apiHostIndex]) {
        expect(fixture.chat.chatContext.apiHost, _nextApiHost);
      }
      if (field == _credentialFields[_wsHostIndex]) {
        expect(Uri.parse(fixture.sockets.last._url!).host,
            Uri.parse(_nextWsHost).host);
      }
      if (field == _credentialFields[_nicknameIndex]) {
        expect(Uri.parse(fixture.sockets.last._url!).queryParameters[_nicknameField],
            _nextNickname);
      }
      await fixture.sockets.last.login();
      await _flush(tester);
      await replacement;
      fixture.dispose();
      await _flush(tester);
    });
  }

  testWidgets('without hooks same-user token change replaces credentials',
      (tester) async {
    final fixture = _Fixture();
    fixture.chat.chatContext.accessToken = _firstAccessToken;
    final replacement = fixture.chat.connect(_userId,
        accessToken: _nextAccessToken);
    await _flush(tester);
    expect(fixture.sockets.single.closes, _one);
    expect(fixture.sockets.single.loginAccessToken, _nextAccessToken);
    await fixture.sockets.single.login();
    await _flush(tester);
    final user = await replacement;
    expect(user, same(fixture.chat.chatContext.currentUser));
    expect(fixture.chat.chatContext.accessToken, _nextAccessToken);
    expect(fixture.starts, _one);
    expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
    fixture.dispose();
    await _flush(tester);
  });

  test('token replacement sends a fresh WebSocket login token header', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _ephemeralPort);
      final tokens = <String?>[];
      final sessionKeys = <String?>[];
      final peers = <WebSocket>[];
      final subscription = server.listen((request) async {
        tokens.add(request.headers.value(_tokenHeader));
        sessionKeys.add(request.headers.value(_authHeader));
        final peer = await WebSocketTransformer.upgrade(request);
        peers.add(peer);
        peer.listen((_) {});
        peer.add('$_loginCommand${jsonEncode(_loginPayload)}');
      });
      final sdk = SendbirdChat.create();
      await sdk.init(appId: _appId,
          options: SendbirdChatOptions(useCollectionCaching: false));
      final fixture = _Fixture(chat: sdk.chat, useLocalServer: true);
      fixture.chat.networkPathHooks = _Hooks();
      final wsHost = Uri(scheme: _localSocketScheme,
          host: server.address.address, port: server.port).toString();
      fixture.chat.chatContext
        ..accessToken = _firstAccessToken
        ..wsHost = wsHost;
      try {
        final key = fixture.key();
        await fixture.adapter.beginOrJoinReconnect(key, fixture.deadline);
        expect(tokens, [null]);
        expect(sessionKeys, [_userId]);
        final user = await sdk.connect(_userId,
            accessToken: _nextAccessToken, wsHost: wsHost);
        expect(user.userId, _userId);
        expect(tokens, [null, _nextAccessToken]);
        expect(sessionKeys, [_userId, null]);
        expect(fixture.connection.networkReconnect.ownsReconnect, isFalse);
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
  registerNetworkReconnectLifecycleTests();
  registerNetworkCredentialsTests();
}
