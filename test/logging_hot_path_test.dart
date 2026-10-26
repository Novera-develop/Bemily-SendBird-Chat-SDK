import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_cache/cache_service.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';
import 'package:sendbird_chat_sdk/src/internal/main/utils/json_converter.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';

const _zero = 0;
const _one = 1;
const _four = 4;
const _messageId = 42;
const _timestamp = 1000;
const _channelUrl = 'logging-channel';
const _userId = 'logging-user';
const _senderId = 'logging-sender';
const _requestId = 'logging-request';
const _message = 'logging-message';
const _probeKey = 'logging_probe';
const _probeValue = 'encoded';
const _commandKey = 'cmd';
const _requestKey = 'req_id';
const _channelKey = 'channel_url';
const _channelTypeKey = 'channel_type';
const _groupType = 'group';
const _messageIdKey = 'msg_id';
const _messageKey = 'message';
const _timestampKey = 'ts';
const _userKey = 'user';
const _userIdKey = 'user_id';
const _nicknameKey = 'nickname';
const _stack = '#0      loggingCaller (logging.dart:10:20)\n'
    '#1      caller (caller.dart:30:40)';
const _expectedMessage = '[loggingCaller] logging-message';
const _batchFlush = Duration(milliseconds: 100);
const _afterTimeout = Duration(seconds: 31);

void main() {
  tearDown(sbLog.setLogLevelForTest);

  test('error level skips suppressed stack parsing', () {
    sbLog.setLogLevel(LogLevel.error);
    final trace = _CountingTrace();
    sbLog.v(trace, _message);
    sbLog.d(trace, _message);
    sbLog.i(trace, _message);
    sbLog.w(trace, _message);
    expect(trace.parses, _zero);
  });

  test('verbose preserves all messages and caller prefixes', () {
    final printer = _CapturePrinter();
    sbLog.logger = Logger(level: Level.verbose, printer: printer);
    final trace = _CountingTrace();
    sbLog.v(trace, _message);
    sbLog.d(trace, _message);
    sbLog.i(trace, _message);
    sbLog.w(trace, _message);
    expect(printer.messages, List.filled(_four, _expectedMessage));
    expect(trace.parses, _four);
  });

  test('error diagnostics preserve message and caller prefix', () {
    final printer = _CapturePrinter();
    sbLog.logger = Logger(level: Level.error, printer: printer);
    final trace = _CountingTrace();
    sbLog.e(trace, _message);
    expect(printer.messages, [_expectedMessage]);
    expect(trace.parses, _one);
  });

  test('none level skips lazy error messages and stack parsing', () {
    sbLog.setLogLevel(LogLevel.none);
    final trace = _CountingTrace();
    var builds = _zero;
    sbLog.e(trace, () {
      builds++;
      return _message;
    });
    expect(builds, _zero);
    expect(trace.parses, _zero);
  });

  test('lazy error diagnostics preserve message and caller prefix', () {
    final printer = _CapturePrinter();
    sbLog.logger = Logger(level: Level.error, printer: printer);
    final trace = _CountingTrace();
    var builds = _zero;
    sbLog.e(trace, () {
      builds++;
      return _message;
    });
    expect(printer.messages, [_expectedMessage]);
    expect(builds, _one);
    expect(trace.parses, _one);
  });

  for (final level in [Level.error, Level.verbose]) {
    testWidgets('MESG MACK READ preserve processing with $level logging',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      await SendbirdChat().init(
        appId: _channelUrl,
        options: SendbirdChatOptions(useCollectionCaching: false),
      );
      final chat = SendbirdChat().chat;
      chat.chatContext.currentUserId = _userId;
      chat.chatContext.currentUser = User(userId: _userId, nickname: _userId);
      final socket = _Socket();
      chat.connectionManager.webSocketClient = socket;
      final channel = GroupChannel(channelUrl: _channelUrl)..set(chat);
      channel.saveToCache(chat);
      final handler = _Handler();
      chat.eventManager.addChannelHandler(_channelUrl, handler);
      final printer = _CapturePrinter();
      sbLog.logger = Logger(level: level, printer: printer);
      final probe = _EncodeProbe();
      final encodeCounts = <int>[];
      final receive = Command(cmd: CommandString.userMessage)
        ..payload = {
          _commandKey: CommandString.userMessage,
          _channelKey: _channelUrl,
          _channelTypeKey: _groupType,
          _messageIdKey: _messageId,
          _messageKey: _message,
          _timestampKey: _timestamp,
          _userKey: {_userIdKey: _senderId, _nicknameKey: _senderId},
          _probeKey: probe,
        };
      final expectedPayload = jsonEncoder.convert({
        ...receive.payload,
        _probeKey: _probeValue,
      });
      await chat.commandManager.processCommand(receive);
      expect(handler.messages.single.messageId, _messageId);
      expect(handler.messages.single.message, _message);
      expect(channel.lastMessage?.messageId, _messageId);
      expect(socket.sent.single, startsWith(CommandString.mack));
      encodeCounts.add(probe.encodes);
      if (level == Level.verbose) {
        expect(printer.messages, contains(
          '[CommandManager.processCommand] \n-[cmd] ${receive.cmd}'
          '\n-[payload] $expectedPayload',
        ));
      }
      probe.encodes = _zero;
      final mack = Command(cmd: CommandString.mack)
        ..payload = {_commandKey: CommandString.mack, _probeKey: probe};
      await chat.commandManager.processCommand(mack);
      encodeCounts.add(probe.encodes);
      probe.encodes = _zero;
      final outgoing = Command(cmd: CommandString.read, requestId: _requestId);
      var completed = false;
      final pending = chat.commandManager.sendCommand(outgoing).then((value) {
        completed = true;
        return value;
      });
      final read = Command(cmd: CommandString.read, requestId: _requestId)
        ..payload = {
          _commandKey: CommandString.read,
          _requestKey: _requestId,
          _channelKey: _channelUrl,
          _channelTypeKey: _groupType,
          _timestampKey: _timestamp,
          _userKey: {_userIdKey: _userId},
          _probeKey: probe,
        };
      await chat.commandManager.processCommand(read);
      expect(await pending, same(read));
      expect(completed, isTrue);
      expect(channel.myLastRead, _timestamp);
      expect(channel.getCachedReadStatus(_channelUrl)[_userId], _timestamp);
      expect(handler.readChanges, _one);
      encodeCounts.add(probe.encodes);
      expect(encodeCounts, everyElement(level == Level.error ? _zero : _one));
      if (level == Level.error) expect(printer.messages, isEmpty);
      await tester.pump(_batchFlush);
      await tester.pump(_afterTimeout);
      expect(socket.closeCalls, _zero);
      chat.commandManager.cleanUp();
    });
  }
}

class _CountingTrace implements StackTrace {
  int parses = _zero;

  @override
  String toString() {
    parses++;
    return _stack;
  }
}

class _EncodeProbe {
  int encodes = _zero;

  String toJson() {
    encodes++;
    return _probeValue;
  }
}

class _CapturePrinter extends PrettyPrinter {
  final messages = <String>[];

  @override
  List<String> log(LogEvent event) {
    messages.add(stringifyMessage(event.message));
    return [];
  }
}

class _Handler extends GroupChannelHandler {
  final messages = <BaseMessage>[];
  int readChanges = _zero;

  @override
  void onMessageReceived(BaseChannel channel, BaseMessage message) {
    messages.add(message);
  }

  @override
  void onReadStatusUpdated(GroupChannel channel) {
    readChanges++;
  }
}

class _Socket implements WebSocketClient {
  final sent = <String>[];
  int closeCalls = _zero;

  @override
  bool isConnected() => true;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<bool> close({int? code, String? reason}) async {
    closeCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
