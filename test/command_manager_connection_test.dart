import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_context/chat_context.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/command_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';

const _userId = 'connection-test-user';
const _requestId = 'connection-test-request';
const _secondRequestId = 'connection-test-second-request';
const _zeroCalls = 0;
const _oneCall = 1;
const _twoTimers = 2;
const _beforeDetection = Duration(milliseconds: 2900);
const _untilDetection = Duration(milliseconds: 100);
const _detectionTime = Duration(seconds: 3);
const _requestOffset = Duration(seconds: 1);
const _afterTimeout = Duration(seconds: 31);

void main() {
  testWidgets('disconnected send fails before sending or registering ACK timers',
      (tester) async {
    final fixture = _Fixture(connected: false);
    final result = fixture.send();

    await expectLater(result, throwsA(_connectionRequired));
    expect(fixture.socket.sendCalls, _zeroCalls);
    expect(fixture.timers, isEmpty);
    fixture.manager.clearCompleterMap();
    await tester.pump();
    await fixture.manager.processCommand(fixture.command());
    await tester.pump(_afterTimeout);
    expect(fixture.socket.closeCalls, _zeroCalls);
  });

  testWidgets('connected send preserves a WebSocketFailedException',
      (tester) async {
    final fixture = _Fixture();
    final error = WebSocketFailedException();
    fixture.socket.sendError = error;

    await expectLater(fixture.send(), throwsA(same(error)));
    expect(error.code, SendbirdError.webSocketConnectionFailed);
    expect(fixture.socket.sendCalls, _oneCall);
    expect(fixture.timers, isEmpty);
    fixture.manager.clearCompleterMap();
    await tester.pump();
  });

  testWidgets('clearing ACK waiters still fails with 800210', (tester) async {
    final fixture = _Fixture();
    final result = expectLater(fixture.send(), throwsA(_webSocketFailed));
    expect(fixture.socket.sendCalls, _oneCall);
    expect(fixture.timers, hasLength(_twoTimers));

    fixture.manager.clearCompleterMap();
    fixture.manager.cancelAckTimers();
    await result;
    expect(fixture.timers.where((timer) => timer.isActive), isEmpty);
  });

  testWidgets('dead socket fails at three seconds before close finishes',
      (tester) async {
    final fixture = _Fixture();
    Object? error;
    fixture.send().then<void>((_) {}, onError: (Object value) {
      error = value;
    });
    fixture.socket.onClose = () {
      expectSync(fixture.timers.where((timer) => timer.isActive), isEmpty);
    };

    await tester.pump(_beforeDetection);
    expect(error, isNull);
    expect(fixture.socket.closeCalls, _zeroCalls);
    await tester.pump(_untilDetection);
    expect(error, _webSocketFailed);
    expect(fixture.socket.closeCalls, _oneCall);
    expect(fixture.socket.closeCompleter.isCompleted, isFalse);
    expect(fixture.timers.where((timer) => timer.isActive), isEmpty);
    await tester.pump(_afterTimeout);
    expect(fixture.socket.closeCalls, _oneCall);
  });

  testWidgets('ACK at 2.9 seconds succeeds and cancels detection',
      (tester) async {
    final fixture = _Fixture();
    Command? received;
    fixture.send().then((value) => received = value);

    await tester.pump(_beforeDetection);
    final ack = fixture.command();
    await fixture.manager.processCommand(ack);
    await tester.pump();
    expect(received, same(ack));
    expect(fixture.timers.where((timer) => timer.isActive), isEmpty);
    await tester.pump(_afterTimeout);
    expect(fixture.socket.closeCalls, _zeroCalls);
  });

  testWidgets('late ACK does not complete the failed request again',
      (tester) async {
    final fixture = _Fixture();
    var completions = _zeroCalls;
    fixture.send().then<void>((_) {
      completions++;
    }, onError: (Object error) {
      expectSync(error, _webSocketFailed);
      completions++;
    });

    await tester.pump(_detectionTime);
    expect(completions, _oneCall);
    await fixture.manager.processCommand(fixture.command());
    fixture.manager.clearCompleterMap();
    await tester.pump(_afterTimeout);
    expect(completions, _oneCall);
    expect(fixture.socket.closeCalls, _oneCall);
    expect(fixture.timers.where((timer) => timer.isActive), isEmpty);
  });

  testWidgets('other ACK waiters remain for the existing close cleanup',
      (tester) async {
    final fixture = _Fixture();
    final first = expectLater(fixture.send(), throwsA(_webSocketFailed));
    await tester.pump(_requestOffset);
    Object? secondError;
    fixture.send(requestId: _secondRequestId).then<void>((_) {},
        onError: (Object error) {
      secondError = error;
    });

    await tester.pump(_detectionTime - _requestOffset);
    await first;
    expect(secondError, isNull);
    expect(fixture.socket.closeCalls, _oneCall);
    fixture.manager.clearCompleterMap();
    fixture.manager.cancelAckTimers();
    await tester.pump();
    expect(secondError, _webSocketFailed);
    expect(fixture.timers.where((timer) => timer.isActive), isEmpty);
  });
}

final _connectionRequired = isA<ConnectionRequiredException>().having(
    (error) => error.code, 'code', SendbirdError.connectionRequired);
final _webSocketFailed = isA<WebSocketFailedException>().having(
    (error) => error.code, 'code', SendbirdError.webSocketConnectionFailed);

class _Fixture {
  final timers = <Timer>[];
  final _Socket socket;
  late final CommandManager manager;

  _Fixture({bool connected = true}) : socket = _Socket(connected: connected) {
    final context = ChatContext.test()
      ..currentUser = User(userId: _userId, nickname: _userId);
    manager = CommandManager(chat: _Chat(context, _Connection(socket)));
  }

  Command command({String requestId = _requestId}) =>
      Command(cmd: CommandString.enter, requestId: requestId);

  Future<Command?> send({String requestId = _requestId}) => runZoned(
        () => manager.sendCommand(command(requestId: requestId)),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
}

class _Chat implements Chat {
  @override
  final ChatContext chatContext;
  @override
  final ConnectionManager connectionManager;

  _Chat(this.chatContext, this.connectionManager);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements ConnectionManager {
  @override
  final WebSocketClient webSocketClient;

  _Connection(this.webSocketClient);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Socket implements WebSocketClient {
  bool connected;
  int sendCalls = _zeroCalls;
  int closeCalls = _zeroCalls;
  SendbirdException? sendError;
  void Function()? onClose;
  final closeCompleter = Completer<bool>();

  _Socket({required this.connected});

  @override
  bool isConnected() => connected;

  @override
  void send(String data) {
    sendCalls++;
    final error = sendError;
    if (error != null) throw error;
  }

  @override
  Future<bool> close({int? code, String? reason}) {
    closeCalls++;
    connected = false;
    onClose?.call();
    return closeCompleter.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
