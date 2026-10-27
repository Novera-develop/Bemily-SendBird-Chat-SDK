import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
const _beforeDetection = Duration(milliseconds: 4900);
const _untilDetection = Duration(milliseconds: 100);
const _detectionTime = Duration(seconds: 5);
const _requestOffset = Duration(seconds: 1);
const _afterTimeout = Duration(seconds: 31);
const _reservedRoom = 'reserved-room';
const _reservedText = 'reserved-text';

void main() {
  _registerReservedFileTests();
  _registerSendStageTests();
  testWidgets('W20 reserved request survives synchronous send failure', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    await SendbirdChat().init(appId: _reservedRoom,
        options: SendbirdChatOptions(useCollectionCaching: false));
    final chat = SendbirdChat().chat;
    final channel = OpenChannel(channelUrl: _reservedRoom,
        participantCount: _zeroCalls, operators: [])..set(chat);
    final params = UserMessageCreateParams(message: _reservedText);
    params.requestId = _requestId;
    final pending = channel.sendUserMessage(params);
    expect(pending.requestId, _requestId);
    expect(pending.sendingStatus, SendingStatus.failed);
    expect(params.requestId, isNull);
    final retryParams = UserMessageCreateParams.withMessage(pending);
    expect(retryParams.requestId, isNull);
  });
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

  testWidgets('dead socket fails at five seconds before close finishes',
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

  testWidgets('ACK at 4.9 seconds succeeds and cancels detection',
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
  late final ChatContext context;

  _Fixture({bool connected = true}) : socket = _Socket(connected: connected) {
    context = ChatContext.test()
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
  bool isConnected() => webSocketClient.isConnected();

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

const _observerFirst = 'first';
const _observerSecond = 'second';
const _observerLate = 'late';
const _observerFailure = 'observer failure';
const _ackSeconds = 5;
const _fileUrl = 'https://localhost/uploaded-file';
const _invalidPayloadField = 'invalid';

void _registerSendStageTests() {
  for (final missingUser in [false, true]) {
    testWidgets('N3 beforeWrite guard missingUser=$missingUser', (tester) async {
      final fixture = _Fixture(connected: missingUser);
      if (missingUser) fixture.context.currentUser = null;
      await expectLater(fixture.send(), throwsA(isA<SendbirdException>().having(
          (e) => e.sendStage, 'stage', SendStage.beforeWrite)));
      expect(fixture.socket.sendCalls, _zeroCalls);
    });
  }

  testWidgets('N3 send failure is afterWrite and keeps exception identity', (tester) async {
    final fixture = _Fixture();
    final error = WebSocketFailedException();
    fixture.socket.sendError = error;
    await expectLater(fixture.send(), throwsA(same(error)));
    expect(error.sendStage, SendStage.afterWrite);
    expect(fixture.timers, isEmpty);
  });

  testWidgets('N3 websocket precheck stage survives command propagation', (tester) async {
    final fixture = _Fixture();
    fixture.socket.sendError = WebSocketFailedException(sendStage: SendStage.beforeWrite);
    await expectLater(fixture.send(), throwsA(isA<SendbirdException>().having(
        (e) => e.sendStage, 'stage', SendStage.beforeWrite)));
  });

  testWidgets('N3 ACK timeout preserves afterWrite', (tester) async {
    final fixture = _Fixture();
    fixture.context.options.webSocketTimeout = _ackSeconds;
    final pending = expectLater(fixture.send(), throwsA(isA<AckTimeoutException>().having(
        (e) => e.sendStage, 'stage', SendStage.afterWrite)));
    await tester.pump(const Duration(seconds: _ackSeconds));
    await pending;
  });

  testWidgets('N3 close preserves afterWrite', (tester) async {
    final fixture = _Fixture();
    final pending = expectLater(fixture.send(), throwsA(isA<SendbirdException>().having(
        (e) => e.sendStage, 'stage', SendStage.afterWrite)));
    fixture.manager.clearCompleterMap();
    fixture.manager.cancelAckTimers();
    await pending;
  });

  testWidgets('N3 observers run synchronously after write and isolate failures', (tester) async {
    final fixture = _Fixture();
    final seen = <String>[];
    fixture.manager.addDispatchObserver(_observerFirst, (requestId, stage) {
      expectSync(fixture.socket.sendCalls, _oneCall);
      expectSync(requestId, _requestId);
      expectSync(stage, SendStage.afterWrite);
      seen.add(_observerFirst);
      throw StateError(_observerFailure);
    });
    fixture.manager.addDispatchObserver(_observerSecond, (requestId, stage) {
      seen.add(_observerSecond);
    });
    final sent = fixture.send();
    expect(seen, [_observerFirst, _observerSecond]);
    fixture.manager.addDispatchObserver(_observerLate, (_, __) => seen.add(_observerLate));
    await fixture.manager.processCommand(fixture.command());
    await sent;
    expect(seen, [_observerFirst, _observerSecond]);
    fixture.manager.removeDispatchObserver(_observerFirst);
    fixture.manager.removeDispatchObserver(_observerSecond);
    fixture.manager.removeDispatchObserver(_observerLate);
    final next = fixture.send();
    await fixture.manager.processCommand(fixture.command());
    await next;
    expect(seen, [_observerFirst, _observerSecond]);
  });

  testWidgets('N3 observer close cannot miss ACK waiter', (tester) async {
    final fixture = _Fixture();
    fixture.manager.addDispatchObserver(_observerFirst, (_, __) {
      fixture.manager.clearCompleterMap();
    });
    await expectLater(fixture.send(), throwsA(isA<SendbirdException>().having(
        (e) => e.sendStage, 'stage', SendStage.afterWrite)));
    expect(fixture.timers, isEmpty);
  });

  testWidgets('N3 encoding failure occurs before write', (tester) async {
    final fixture = _Fixture();
    final command = fixture.command();
    command.payload = {_invalidPayloadField: Object()};
    await expectLater(fixture.manager.sendCommand(command),
        throwsA(isA<SendbirdException>().having(
            (e) => e.sendStage, 'stage', SendStage.beforeWrite)));
    expect(fixture.socket.sendCalls, _zeroCalls);
  });

  for (final file in [false, true]) {
  for (final afterWrite in [false, true]) {
    testWidgets('N3 message handler keeps stage file=$file afterWrite=$afterWrite', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      final sdk = SendbirdChat();
      await sdk.init(appId: _reservedRoom,
          options: SendbirdChatOptions(useCollectionCaching: false));
      final chat = sdk.chat;
      final socket = _Socket(connected: afterWrite);
      chat.connectionManager = _Connection(socket);
      chat.chatContext.currentUser = afterWrite ? User(userId: _userId, nickname: _userId) : null;
      if (afterWrite) socket.sendError = WebSocketFailedException();
      final channel = OpenChannel(channelUrl: _reservedRoom,
          participantCount: _zeroCalls, operators: [])..set(chat);
      SendbirdException? received;
      if (file) {
        channel.sendFileMessage(FileMessageCreateParams.withFileUrl(_fileUrl),
            handler: (_, error) => received = error);
      } else {
        channel.sendUserMessage(UserMessageCreateParams(message: _reservedText),
            handler: (_, error) => received = error);
      }
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(received?.sendStage, afterWrite ? SendStage.afterWrite : SendStage.beforeWrite);
    });
  }
}
}

const _emptyRequestId = '';
const _messageIdField = 'msg_id';
const _channelTypeField = 'channel_type';
const _uuidPattern = r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';

void _registerReservedFileTests() {
  for (final reserved in [false, true]) {
    for (final resend in [false, true]) {
      testWidgets('NF8-B file reservation ACK reserved=$reserved resend=$resend', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await SharedPreferences.getInstance();
        final sdk = SendbirdChat();
        await sdk.init(appId: _reservedRoom,
            options: SendbirdChatOptions(useCollectionCaching: false));
        final chat = sdk.chat;
        final socket = _Socket(connected: true);
        chat.connectionManager = _Connection(socket);
        chat.chatContext.currentUser = User(userId: _userId, nickname: _userId);
        final channel = OpenChannel(channelUrl: _reservedRoom,
            participantCount: _zeroCalls, operators: [])..set(chat);
        chat.channelCache.insert(channelKey: _reservedRoom, data: channel);
        final observed = <String>[];
        final received = <FileMessage>[];
        final errors = <SendbirdException?>[];
        sdk.addDispatchObserver(_observerFirst, (id, stage) {
          observed.add(id);
          expectSync(stage, SendStage.afterWrite);
        });
        addTearDown(() => sdk.removeDispatchObserver(_observerFirst));
        final params = FileMessageCreateParams.withFileUrl(_fileUrl);
        FileMessage? failed;
        if (resend) {
          socket.sendError = WebSocketFailedException();
          params.requestId = _requestId;
          channel.sendFileMessage(params, handler: (message, error) => failed = message);
          await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);
          expect(failed?.requestId, _requestId);
          expect(failed?.sendingStatus, SendingStatus.failed);
          expect(params.requestId, isNull);
          expect(FileMessageCreateParams.withMessage(failed!).requestId, isNull);
          socket.sendError = null;
          observed.clear();
        }
        params.requestId = reserved ? _secondRequestId : null;
        void handler(FileMessage message, SendbirdException? error) {
          received.add(message);
          errors.add(error);
        }
        final pending = resend
            ? channel.resendFileMessage(failed!, handler: handler)
            : channel.sendFileMessage(params, handler: handler);
        expect(params.requestId, isNull);
        if (reserved) {
          expect(pending.requestId, _secondRequestId);
        } else {
          expect(pending.requestId, matches(_uuidPattern));
        }
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);
        expect(observed, [pending.requestId]);
        expect(received, isEmpty);
        final ack = Command.buildFileMessage(channelUrl: _reservedRoom,
            params: params, requestId: pending.requestId);
        ack.payload[_messageIdField] = _oneCall;
        ack.payload[_channelTypeField] = ChannelType.open.name;
        await chat.commandManager.processCommand(ack);
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);
        expect(received.map((message) => message.requestId), [pending.requestId]);
        expect(errors, [null]);
        final repeated = channel.sendFileMessage(params, handler: handler);
        expect(repeated.requestId, matches(_uuidPattern));
        expect(repeated.requestId, isNot(pending.requestId));
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);
        expect(observed, [pending.requestId, repeated.requestId]);
        final repeatedAck = Command.buildFileMessage(channelUrl: _reservedRoom,
            params: params, requestId: repeated.requestId);
        repeatedAck.payload[_messageIdField] = _twoTimers;
        repeatedAck.payload[_channelTypeField] = ChannelType.open.name;
        await chat.commandManager.processCommand(repeatedAck);
        await tester.pump(Duration.zero);
        expect(received.map((message) => message.requestId),
            [pending.requestId, repeated.requestId]);
        expect(errors, [null, null]);
        await tester.pump(_afterTimeout);
        expect(socket.closeCalls, _zeroCalls);
      });
    }
  }
  testWidgets('NF8-B file reservation validates and consumes once', (tester) async {
    final channel = OpenChannel(channelUrl: _reservedRoom,
        participantCount: _zeroCalls, operators: []);
    final params = FileMessageCreateParams.withFileUrl(_fileUrl)
      ..requestId = _emptyRequestId;
    expect(() => FileMessage.fromParams(params: params, channel: channel),
        throwsA(isA<InvalidParameterException>()));
    params.requestId = _requestId;
    final first = FileMessage.fromParams(params: params, channel: channel);
    final second = FileMessage.fromParams(params: params, channel: channel);
    expect(first.requestId, _requestId);
    expect(second.requestId, matches(_uuidPattern));
    expect(second.requestId, isNot(first.requestId));
    expect(params.requestId, isNull);
  });
}
