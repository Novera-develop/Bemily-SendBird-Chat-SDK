import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/db.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/channel/c_group_channel.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/c_user_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/user/c_user.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_cache/cache_service.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_cache/channel/channel_cache.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/command_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/db_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/api_client.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/api_request.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/websocket_client.dart';

abstract class A {
  static const zero = 0;
  static const one = 1;
  static const two = 2;
  static const members = 4;
  static const burst = 6;
  static const many = 20;
  static const unitTxns = 7;
  static const receiveUpserts = 4;
  static const readUpserts = 2;
  static const typingUpserts = 1;
  static const timeout = Duration(seconds: 10);
  static const local = Duration(milliseconds: 100);
  static const tick = Duration(milliseconds: 1);
  static const dead = Duration(seconds: 5);
  static const ackTimeout = 10;
  static const empty = '';
  static const separator = '|';
  static const newline = '\n';
  static const original = 'original';
  static const nick = 'nick';
  static const instances = [original, nick];
  static const app = 'sdk-audit';
  static const self = 'audit-self';
  static const peer = 'audit-peer';
  static const memberPrefix = 'audit-member-';
  static const room = 'audit-room';
  static const warmRoom = 'audit-warm';
  static const apiHost = 'sdk-audit.invalid';
  static const channelUrl = 'channel_url';
  static const channelType = 'channel_type';
  static const group = 'group';
  static const messageId = 'msg_id';
  static const storedMessageId = 'message_id';
  static const message = 'message';
  static const body = 'audit message';
  static const user = 'user';
  static const userId = 'user_id';
  static const nickname = 'nickname';
  static const createdAt = 'created_at';
  static const timestamp = 'ts';
  static const requestId = 'req_id';
  static const category = 'cat';
  static const data = 'data';
  static const updated = 'updated';
  static const type = 'type';
  static const memberField = 'members';
  static const creator = 'created_by';
  static const lastMessage = 'last_message';
  static const typingStart = 10900;
  static const get = 'GET';
  static const hideSuffix = 'hide';
  static const offsetTimestamp = 'ts_message_offset';
  static const preserved = 'RED-concurrent-persistence';
  static const requestA = 'audit-read-a';
  static const requestB = 'audit-read-b';
  static const sourceZone = #auditSource;
  static const persistZone = #auditPersist;
  static const timerZone = #auditTimer;
  static const txnZone = #auditTxn;
  static const fixture = 'fixture';
  static const received = 'onMessageReceived';
  static const messageList = 'sendEventsToMessageCollectionList';
  static const groupList = 'sendEventsToGroupChannelCollectionList';
  static const receiveStore = 'receive-group';
  static const changedGroup = 'changed-group';
  static const changedMessage = 'changed-message-direct';
  static const groupFollowup = 'changed-message-followup';
  static const transientGroup = 'transient-group';
  static const readStatus = 'onReadStatusUpdated';
  static const userMarkedRead = 'onUserMarkedRead';
  static const typingStatus = 'onTypingStatusUpdated';
  static const timeoutAck = 'timeout-before-ack';
  static const deleteWarm = 'delete-warm';
  static const txnMissing = 'put outside transaction';
  static const httpOk = 200;
  static const httpReason = 'OK';
  static const cacheAbsent = 'absent';
  static const cacheDirty = 'dirty';
  static const cacheWarm = 'warm';
  static const t00 = 'T0-0';
  static const t01 = 'T0-1';
  static const t05 = 'T0-5';
  static const sameFrame = 'same-frame';
  static const separateFrames = 'separate-frames';
  static const settleCache = 'settle-cache';
  static const lookupBarrier = 'lookup-barrier';
  static const offsetBarrier = 'offset-barrier';
  static const ackLater = 'later-ack-first';
  static const ackMissing = 'earlier-ack-missing';
  static const delivery = 'delivery-context';
  static const deletion = 'delete-lookup-error';
  static const redCap = 'RED-get-cap';
  static const redCallbacks = 'RED-callback-latency';
  static const redRecovery = 'RED-recovery-fresh';
  static const timerLabel = 'timers';
  static const requestLabel = 'requests';
  static const offsetLabel = 'offset';
  static const flightLabel = 'flight';
  static const cacheLabel = 'cache';
  static const dualInstance = 'dual-instance';
  static const assign = '=';
  static const comma = ',';
}

enum K {
  commandStart, commandEnd, callback, deleted, read, typing, delivery,
  httpLogical, httpTransport, httpEnd, flightInsert, flightRemove, cache,
  dbFallback, upsert, txnEnter, txnReturn, row, wsLogical, wsWire,
  ackSettled, ackFailed, timerCreate, socketClose, resources,
}

class Entry {
  Entry(this.scenario, this.instance, this.time, this.kind, this.source,
      this.persist, this.detail);
  final String scenario, instance, source, persist, detail;
  final Duration time;
  final K kind;
  @override
  String toString() => [scenario, instance, time.inMilliseconds, kind.name,
      source, persist, detail].join(A.separator);
}

class Trace {
  Trace(this.scenario, this.instance, this.clock);
  final String scenario, instance;
  final FakeAsync clock;
  final entries = <Entry>[];
  void add(K kind, [Object detail = A.empty]) => entries.add(Entry(scenario,
      instance, clock.elapsed, kind, Zone.current[A.sourceZone]?.toString() ?? A.fixture,
      Zone.current[A.persistZone]?.toString() ?? A.empty, detail.toString()));
  List<Entry> of(K kind) => entries.where((e) => e.kind == kind).toList();
  int count(K kind) => of(kind).length;
  void dump() {
    for (final e in entries) {
      // ignore: avoid_print
      print(e);
    }
  }
}

class FlightMap extends MapBase<String, Future<dynamic>> {
  FlightMap(this.trace);
  final Trace trace;
  final inner = <String, Future<dynamic>>{};
  @override
  Future<dynamic>? operator [](Object? key) => inner[key];
  @override
  void operator []=(String key, Future<dynamic> value) {
    trace.add(K.flightInsert, key);
    inner[key] = value;
  }
  @override
  Iterable<String> get keys => inner.keys;
  @override
  Future<dynamic>? remove(Object? key) {
    trace.add(K.flightRemove, key ?? A.empty);
    return inner.remove(key);
  }
  @override
  void clear() => inner.clear();
}

class AuditChat extends Chat {
  AuditChat(this.trace) : super(appId: A.app,
      options: SendbirdChatOptions(useCollectionCaching: true,
          webSocketTimeout: A.ackTimeout));
  final Trace trace;
  @override
  late final Map<String, Future<dynamic>> pendingChannelFetches = FlightMap(trace);
}

class AuditCache extends ChannelCache {
  AuditCache(this.trace);
  final Trace trace;
  @override
  void insert({required String channelKey, required Cacheable data}) {
    super.insert(channelKey: channelKey, data: data);
    if (data is BaseChannel) {
      trace.add(K.cache, data.dirty ? A.cacheDirty : A.cacheWarm);
    }
  }
}

class AuditApi extends ApiClient {
  AuditApi(Chat chat, this.trace) : super(chatContext: chat.chatContext,
      sessionManager: chat.sessionManager);
  final Trace trace;
  @override
  Future<T> send<T>(ApiRequest request) async {
    trace.add(K.httpLogical, request.url);
    try {
      return await super.send<T>(request);
    } finally {
      trace.add(K.httpEnd, request.url);
    }
  }
}

class Transport extends Fake implements io.HttpClient {
  Trace? trace;
  bool fail = true;
  Completer<void>? barrier;
  final responses = <String, Map<String, dynamic>>{};
  @override
  Future<io.HttpClientRequest> openUrl(String method, Uri url) async {
    trace?.add(K.httpTransport, method);
    await barrier?.future;
    if (fail) {
      await Future<void>.delayed(A.timeout);
      throw TimeoutException(A.apiHost, A.timeout);
    }
    return Request(url.pathSegments.last == A.hideSuffix
        ? <String, dynamic>{} : responses[url.pathSegments.last]!);
  }
  @override
  void close({bool force = false}) {}
}

class Headers extends Fake implements io.HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
}

class Request extends Fake implements io.HttpClientRequest {
  Request(this.body);
  final Map<String, dynamic> body;
  @override
  final io.HttpHeaders headers = Headers();
  @override
  set followRedirects(bool value) {}
  @override
  set maxRedirects(int value) {}
  @override
  set contentLength(int value) {}
  @override
  set persistentConnection(bool value) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async { await stream.drain<void>(); }
  @override
  Future<io.HttpClientResponse> close() async => Response(jsonEncode(body));
}

class Response extends Stream<List<int>> implements io.HttpClientResponse {
  Response(String body) : bytes = utf8.encode(body);
  final List<int> bytes;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData, onError: onError, onDone: onDone,
          cancelOnError: cancelOnError);
  @override
  int get statusCode => A.httpOk;
  @override
  int get contentLength => bytes.length;
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => true;
  @override
  String get reasonPhrase => A.httpReason;
  @override
  io.HttpHeaders get headers => Headers();
  @override
  List<io.RedirectInfo> get redirects => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CounterIsar extends Fake implements Isar {
  CounterIsar(this.trace);
  final Trace trace;
  final channels = <String, CGroupChannel>{};
  final messages = <int, CUserMessage>{};
  final users = <String, CUser>{};
  @override
  IsarCollection<T> collection<T>() => Rows<T>(this);
  @override
  Future<T> writeTxn<T>(Future<T> Function() callback, {bool silent = false}) async {
    trace.add(K.txnEnter);
    try {
      return await runZoned(callback, zoneValues: {A.txnZone: true});
    } finally {
      trace.add(K.txnReturn);
    }
  }
  void put(Object? row) {
    expect(Zone.current[A.txnZone], isTrue, reason: A.txnMissing);
    trace.add(K.row, row.runtimeType);
    if (row is CGroupChannel) channels[row.channelUrl] = row;
    if (row is CUserMessage) messages[row.messageId] = row;
    if (row is CUser) users[row.userId] = row;
  }
}

class Rows<T> extends IsarCollection<T> {
  Rows(this.owner);
  final CounterIsar owner;
  @override
  Future<Id> put(T object) async {
    owner.put(object);
    return A.one;
  }
  @override
  Query<R> buildQuery<R>({List<WhereClause> whereClauses = const [],
      bool whereDistinct = false, Sort whereSort = Sort.asc,
      FilterOperation? filter, List<SortProperty> sortBy = const [],
      List<DistinctProperty> distinctBy = const [], int? offset, int? limit,
      String? property}) {
    final key = (whereClauses.single as IndexWhereClause).lower!.single;
    Object? value;
    if (T == CGroupChannel) value = owner.channels[key];
    if (T == CUser) value = owner.users[key];
    if (T == CUserMessage) value = owner.messages[int.parse(key.toString())];
    return RowQuery<R>(value as R?);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RowQuery<R> extends Fake implements Query<R> {
  RowQuery(this.value);
  final R? value;
  @override
  Future<R?> findFirst() async => value;
}

class DbPort extends DBManager {
  DbPort({required Chat chat, required this.trace, required this.isar})
      : db = DB(chat: chat, isar: isar), super(chat: chat);
  final Trace trace;
  final CounterIsar isar;
  final DB db;
  bool enabled = true;
  int pending = A.zero;
  @override
  bool isEnabled() => enabled;
  @override
  DB getDB() => db;
  @override
  Future<void> updateGroupChannelReadStatus(GroupChannel channel,
      {required bool Function() shouldPersist}) async {
    pending++;
    try {
      trace.add(K.upsert, A.one);
      await super.updateGroupChannelReadStatus(channel,
          shouldPersist: shouldPersist);
    } finally {
      pending--;
    }
  }
  @override
  Future<void> write(Function writeFunc, {bool force = false}) => db.write(writeFunc);
  @override
  Future<GroupChannel?> getGroupChannel(String channelUrl) async {
    trace.add(K.dbFallback);
    return db.getGroupChannel(channelUrl);
  }
  @override
  Future<void> upsertGroupChannels(List<GroupChannel> channels) async {
    final stack = StackTrace.current.toString();
    final source = stack.contains(A.received) ? A.receiveStore
        : stack.contains(A.messageList)
            ? (stack.contains(A.groupList) ? A.groupFollowup : A.changedMessage)
            : (Zone.current[A.sourceZone] == CommandString.userMessage
                ? A.changedGroup
                : stack.contains(A.readStatus) ? A.readStatus
                : stack.contains(A.userMarkedRead) ? A.userMarkedRead
                : stack.contains(A.typingStatus) ? A.typingStatus : A.transientGroup);
    pending++;
    try {
      await runZoned(() async {
        trace.add(K.upsert, channels.length);
        for (final channel in channels) {
          await db.upsertGroupChannel(channel);
        }
      }, zoneValues: {A.persistZone: source});
    } finally {
      pending--;
    }
  }
}

class AuditCommands extends CommandManager {
  AuditCommands({required super.chat, required this.trace});
  final Trace trace;
  final timers = <Timer>[];
  final pendingRequests = <String>{};
  @override
  Future<void> processCommand(Command cmd) => runZoned(() async {
    trace.add(K.commandStart, cmd.requestId ?? cmd.payload[A.messageId] ?? A.empty);
    try {
      await super.processCommand(cmd);
    } finally {
      trace.add(K.commandEnd, cmd.requestId ?? cmd.payload[A.messageId] ?? A.empty);
    }
  }, zoneValues: {A.sourceZone: cmd.cmd});
  @override
  Future<Command?> sendCommand(Command cmd) => runZoned(() async {
    trace.add(K.wsLogical, cmd.cmd);
    final id = cmd.requestId;
    if (cmd.isAckRequired && id != null) pendingRequests.add(id);
    try {
      final result = await super.sendCommand(cmd);
      if (cmd.isAckRequired) trace.add(K.ackSettled, id ?? A.empty);
      return result;
    } catch (e) {
      trace.add(K.ackFailed, e.runtimeType);
      rethrow;
    } finally {
      if (id != null) pendingRequests.remove(id);
    }
  }, zoneValues: {A.timerZone: true}, zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createTimer(zone, duration, callback);
      timers.add(timer);
      trace.add(K.timerCreate, duration.inMilliseconds);
      return timer;
    },
  ));
  int get activeTimers => timers.where((t) => t.isActive).length;
}

class AuditSocket extends Fake implements WebSocketClient {
  AuditSocket(this.data, this.trace);
  @override
  void connect({required String url, String? accessToken, String? sessionKey,
      bool reconnect = false, OnWebSocketTransportStart? onTransportStart}) {
    onTransportStart?.call(() {});
  }
  final OnWebSocketData data;
  final Trace trace;
  @override
  bool isConnected() => true;
  @override
  void send(String data) => trace.add(K.wsWire, data.split(A.newline).first.substring(A.zero, A.members));
  @override
  Future<bool> close({int? code, String? reason}) async {
    trace.add(K.socketClose);
    return true;
  }
}

class Handler extends GroupChannelHandler {
  Handler(this.trace);
  final Trace trace;
  final messages = <BaseMessage>[];
  final deliveryChannels = <GroupChannel>[];
  void Function(BaseChannel)? onReceive;
  @override
  void onMessageReceived(BaseChannel channel, BaseMessage message) {
    messages.add(message);
    trace.add(K.callback, message.messageId);
    onReceive?.call(channel);
  }
  @override
  void onMessageDeleted(BaseChannel channel, int messageId) => trace.add(K.deleted, messageId);
  @override
  void onUserMarkedRead(GroupChannel channel, List<String> userIds) => trace.add(K.read);
  @override
  void onTypingStatusUpdated(GroupChannel channel) => trace.add(K.typing);
  @override
  void onDeliveryStatusUpdated(GroupChannel channel) {
    deliveryChannels.add(channel);
    trace.add(K.delivery);
  }
}

class Fixture {
  Fixture(this.clock, this.transport, String scenario,
      {String instance = A.original, Chat? existing}) {
    trace = Trace(scenario, instance, clock);
    transport.trace = trace;
    chat = existing ?? AuditChat(trace);
    chat.sdkInstance = instance;
    chat.chatContext
      ..currentUser = User(userId: A.self, nickname: A.self)
      ..currentUserId = A.self
      ..apiHost = A.apiHost;
    chat.channelCache = AuditCache(trace);
    chat.apiClient = AuditApi(chat, trace);
    isar = CounterIsar(trace);
    chat.dbManager = db = DbPort(chat: chat, trace: trace, isar: isar);
    chat.commandManager = commands = AuditCommands(chat: chat, trace: trace);
    chat.connectionManager = ConnectionManager(chat: chat, socketFactory: (data, closed, error) {
      return socket = AuditSocket(data, trace);
    });
    chat.connectionManager.changeState(ConnectedState(chat: chat));
    handler = Handler(trace);
    chat.eventManager.addChannelHandler(A.app, handler);
    for (final url in [A.room, A.warmRoom]) {
      if (url == A.room) db.upsertGroupChannels([channel(url)]);
      transport.responses[url] = channelJson(url);
    }
    clock.flushMicrotasks();
    trace.entries.clear();
  }
  final FakeAsync clock;
  final Transport transport;
  late final Trace trace;
  late final Chat chat;
  late final DbPort db;
  late final CounterIsar isar;
  late final AuditCommands commands;
  late final AuditSocket socket;
  late final Handler handler;
  GroupChannel channel(String url) => GroupChannel.fromJsonWithChat(chat, channelJson(url));
  void cache(String url, {bool dirty = false}) {
    final value = channel(url)..dirty = dirty;
    value.saveToCache(chat);
    clock.flushMicrotasks();
  }
  String cacheState(String url) {
    final value = chat.channelCache.find<GroupChannel>(channelKey: url);
    return value == null ? A.cacheAbsent : (value.dirty ? A.cacheDirty : A.cacheWarm);
  }
  void frame(List<String> commands) {
    socket.data(commands.join(A.newline));
    clock.flushMicrotasks();
    snapshot();
  }
  void snapshot() => trace.add(K.resources, {
    A.timerLabel: commands.activeTimers,
    A.requestLabel: commands.pendingRequests.length,
    A.offsetLabel: commands.messageOffsetTsCompleterMap.length,
    A.flightLabel: chat.pendingChannelFetches.length,
    A.cacheLabel: cacheState(A.room),
  }.entries.map((e) => '${e.key}${A.assign}${e.value}').join(A.comma));
  void elapse(Duration value) { clock.elapse(value); clock.flushMicrotasks(); snapshot(); }
  void settle() {
    elapse(A.local);
    expect(db.pending, A.zero);
    expect(chat.pendingChannelFetches, isEmpty);
    expect(commands.messageOffsetTsCompleterMap, isEmpty);
    expect(commands.pendingRequests, isEmpty);
    expect(commands.activeTimers, A.zero);
    expect(clock.pendingTimers, isEmpty);
    expect(trace.count(K.txnReturn), trace.count(K.txnEnter));
  }
  Future<Command?> sendRead(String id) {
    final command = Command(cmd: CommandString.read, requestId: id,
        payload: readPayload(A.one, request: id));
    return commands.sendCommand(command);
  }
}

Map<String, dynamic> userJson(String id) => {A.userId: id, A.nickname: id};
Map<String, dynamic> messagePayload(int id, {String room = A.room}) => {
  A.channelUrl: room, A.channelType: A.group, A.messageId: id,
  A.storedMessageId: id, A.message: A.body, A.createdAt: id,
  A.user: userJson(A.peer), A.type: CommandString.userMessage,
};
Map<String, dynamic> channelJson(String url) => {
  A.channelUrl: url,
  A.memberField: [userJson(A.self), userJson(A.peer),
    for (var i = A.two; i < A.members; i++) userJson('${A.memberPrefix}$i')],
  A.creator: userJson(A.self),
  A.lastMessage: messagePayload(A.zero, room: url),
};
Map<String, dynamic> readPayload(int ts, {String? request}) => {
  A.channelUrl: A.room, A.channelType: A.group, A.user: userJson(A.peer),
  A.timestamp: ts, if (request != null) A.requestId: request,
};
String wire(String cmd, Map<String, dynamic> payload) => '$cmd${jsonEncode(payload)}';
String message(int id, {String room = A.room}) => wire(CommandString.userMessage, messagePayload(id, room: room));
String read(int ts, {String? request}) => wire(CommandString.read, readPayload(ts, request: request));
String typing(int ts) => wire(CommandString.systemEvent, {
  A.channelUrl: A.room, A.channelType: A.group, A.category: A.typingStart,
  A.data: userJson(A.peer), A.timestamp: ts,
});
void audit(String scenario, void Function(Fixture) body,
    {String instance = A.original}) {
  fakeAsync((clock) {
    final transport = Transport();
    io.HttpOverrides.runZoned(() {
      final fixture = Fixture(clock, transport, scenario, instance: instance);
      try {
        body(fixture);
      } finally {
        fixture.trace.dump();
      }
    }, createHttpClient: (_) => transport);
  });
}

Future<void> initializeAudit() async {
  SharedPreferences.setMockInitialValues({});
  await SendbirdChat().init(appId: A.app,
      options: SendbirdChatOptions(useCollectionCaching: false));
}
