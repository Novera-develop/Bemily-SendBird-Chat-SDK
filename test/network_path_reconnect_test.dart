import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/channel/c_group_channel.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/c_user_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/user/c_user.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/login/c_login.dart';

import 'package:fake_async/fake_async.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/db.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/login/login.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_context/chat_context.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/collection_manager/collection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/network_reconnect_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/db_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/device_token_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/event_dispatcher.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/event_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/session_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/disconnected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/delayed_connecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/reconnecting_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/stats/stat_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/utils/async/async_task.dart';
import 'package:sendbird_chat_sdk/src/internal/main/utils/async/async_queue.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/event/login_event.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/api_client.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/api_request.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'audit/sdk_audit_fixture.dart' as audit;

part 'support/network_reconnect_fixture.dart';
part 'network_path_reconnect_lifecycle_cases.dart';
part 'network_path_credentials_cases.dart';
part 'network_path_session_ownership_cases.dart';
part 'network_path_session_matrix_cases.dart';
part 'network_path_background_recovery_cases.dart';

enum _CancellationPhase { scheduled, dispatcher, session, delayedParameters }

void main() {
  _registerNf7Tests();
  _registerNf6Tests();
  _registerNf5Tests();
  _registerNf4RaceTests();
  _registerNf3RaceTests();
  _registerNf2RaceTests();
  _registerTransportRecoveryTests();
  _registerBackgroundRecoveryTests();
  _registerSessionOwnershipTests();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    await SendbirdChat().init(appId: _appId,
        options: SendbirdChatOptions(useCollectionCaching: false));
  });

  testWidgets('W22 fix5 reconnect close gate cancels on background entry', (tester) async {
    final fixture = _Fixture();
    final gate = Completer<bool>();
    fixture.sockets.single.closeBarrier = gate;
    final pending = fixture.connection.reconnectForNetworkChange();
    await _flush(tester);
    final paused = fixture.chat.didChangeAppLifecycleState(AppLifecycleState.paused);
    await _flush(tester);
    gate.complete(true);
    await pending;
    await paused;
    await _flush(tester);
    expect(fixture.starts, _none);
    fixture.sockets.single.closeBarrier = null;
    await fixture.chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await fixture.connection.reconnectForNetworkChange();
    await _flush(tester);
    expect(fixture.starts, _one);
    await fixture.sockets.last.login();
    await _flush(tester);
    expect(fixture.connection.isConnected(), isTrue);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('W22 fix5 reconnect session wait keeps foreground cancellation', (tester) async {
    final fixture = _Fixture();
    final gate = Completer<String?>();
    fixture.sessions.barrier = gate;
    await fixture.connection.reconnectForNetworkChange();
    await _flush(tester);
    expect(fixture.starts, _none);
    fixture.chat.isBackground = true;
    gate.complete(_userId);
    await _flush(tester);
    expect(fixture.starts, _none);
    fixture.sessions.barrier = null;
    fixture.chat.isBackground = false;
    await fixture.connection.reconnectForNetworkChange();
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
      late _Fixture fixture;
      fixture = _Fixture(onLoginInfo: () {
        if (phase == _CancellationPhase.delayedParameters) fixture.chat.isBackground = true;
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
      await fixture.connection.doReconnect(reset: true, foregroundOnly: true);
      final reserved = fixture.adapter.connectionSnapshot;
      expect(reserved.reconnecting, isTrue);
      if (phase == _CancellationPhase.scheduled) fixture.chat.isBackground = true;
      await _flush(tester);
      fixture.chat.isBackground = true;
      reconnectGate.complete();
      sessionGate.complete(_userId);
      await _flush(tester);
      expect(fixture.starts, _none);
      expect(fixture.connection.isDisconnected(), isTrue);
      expect(fixture.adapter.connectionSnapshot.key, reserved.key);
      expect(fixture.adapter.connectionSnapshot.sequence, reserved.sequence);
      expect(fixture.adapter.connectionSnapshot.authenticated, isFalse);
      expect(fixture.adapter.connectionSnapshot.reconnecting, isFalse);
      expect(fixture.events.last.kind, SocketEventKind.websocketClosed);
      expect(fixture.events.last.error, isNull);
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
    await fixture.connection.doReconnect(reset: true, foregroundOnly: true);
    fixture.chat.isBackground = true;
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

  for (final pending in [false, true]) {
  testWidgets('W22 fix6 late cancellation preserves replacement pending=$pending', (tester) async {
    final fixture = _Fixture();
    final gate = Completer<String?>();
    fixture.sessions.barrier = gate;
      await fixture.connection.doReconnect(reset: true, foregroundOnly: true);
    await _flush(tester);
    final nextGate = Completer<String?>();
    fixture.sessions.barrier = pending ? nextGate : null;
    final replacement = fixture.connection.doReconnect(reset: true).then<void>((_) {});
    await _flush(tester);
    final current = fixture.adapter.connectionSnapshot;
    fixture.chat.isBackground = true;
    gate.complete(_userId);
    await _flush(tester);
    expect(fixture.connection.isReconnecting(), isTrue);
    expect(fixture.adapter.connectionSnapshot.key, current.key);
    expect(fixture.adapter.connectionSnapshot.reconnecting, isTrue);
    expect(fixture.starts, pending ? _none : _one);
    expect(fixture.events.where((event) =>
        event.kind == SocketEventKind.authenticationFailed), isEmpty);
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

  testWidgets('connectivity preserves direct reconnect',
      (tester) async {
    final fixture = _Fixture();
    await fixture.chat.handleConnectivityResults([ConnectivityResult.wifi]);
    await _flush(tester);
    expect(fixture.starts, _one);
    expect(fixture.sockets.single.closes, _one);
    fixture.dispose();
    await _flush(tester);
  });

  testWidgets('connectivity preserves one SDK reconnect during handover',
      (tester) async {
    final fixture = _Fixture();
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

  registerNetworkReconnectLifecycleTests();
  registerNetworkCredentialsTests();
}
