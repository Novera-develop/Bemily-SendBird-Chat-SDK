import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/db.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_cache/cache_service.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/connection_state/connected_state.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/read_status.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/typing_status.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';

import 'sdk_audit_fixture.dart';

const _suite = 'A3-persistence';
const _active = 'active collection';
const _dirty = 'changed member';
const _checkpoint = 'read checkpoint on durable update';
const _ownCheckpoint = 'own read watermark checkpoint';
const _retry = 'failed transaction retries';
const _clear = 'clear cancels queued snapshots';
const _related = 'pinned and inviter restore';
const _scheduled = 'scheduled message revision';
const _delayed = 'delayed put preserves every message';
const _putDelay = Duration(milliseconds: 50);
const _drain = Duration(seconds: 3);
const _nickname = 'updated member';
const _userRow = 'CUser';
const _failure = 'injected transaction failure';
const _channels = 'channels';
const _next = 'next';
const _listPath = 'my_group_channels';
const _inviter = 'audit-inviter';
const _review = 'A3-fix1';
const _reactionQueue = 'queued snapshots preserve active message reaction';
const _restriction = 'restriction revision';
const _receipt = 'peer receipt checkpoint';
const _receiptClose = 'peer receipt disconnect waits for persistence';
const _reasonBefore = 'before';
const _reasonAfter = 'after';
const _reactionField = 'reaction';
const _reactionKey = 'like';
const _operation = 'operation';
const _add = 'ADD';
const _updatedAt = 'updated_at';
const _receiptBudget = 2;
const _checkpointWindow = Duration(milliseconds: 100);
const _messages = 'messages';
const _threadInfo = 'thread_info';
const _parentMessageId = 'parent_message_id';
const _replyCount = 'reply_count';
const _receiptFailure = 'disconnect survives checkpoint failure or timeout';
const _closeTimeout = Duration(seconds: 2);
const _reviewSecond = 'A3-fix2';
const _parentCheckpoint = 'read preserves separately updated parent';
const _clearCheckpoint = 'clear disconnect preserves pending watermark';
const _replaceCheckpoint = 'SDK replacement drains old checkpoint timers';
const _parentMessage = 'parent_message_info';
const _messageRow = 'CUserMessage';
const _expiredCheckpoint = 'expired checkpoint cannot write after reset';
const _credentialCheckpoint = 'credential change flushes pending watermark';
const _newUser = 'audit-new-user';
const _isolatedCheckpoint = 'reset keeps other SDK receipt timer isolated';

class _MessageHandler extends MessageCollectionHandler {
  final updated = <BaseMessage>[];
  @override
  void onMessagesUpdated(MessageContext context, GroupChannel channel,
      List<BaseMessage> messages) => updated.addAll(messages);
  @override
  void onMessagesAdded(MessageContext context, GroupChannel channel,
      List<BaseMessage> messages) {}
  @override
  void onMessagesDeleted(MessageContext context, GroupChannel channel,
      List<BaseMessage> messages) {}
  @override
  void onChannelUpdated(GroupChannelContext context, GroupChannel channel) {}
  @override
  void onChannelDeleted(GroupChannelContext context, String channelUrl) {}
  @override
  void onHugeGapDetected() {}
}

class _MessageDbPort extends DbPort {
  _MessageDbPort({required super.chat, required super.trace, required super.isar});
  @override
  Future<void> upsertMessages(List<RootMessage> messages) async {
    for (final message in messages) {
      await db.upsertUserMessage(message as UserMessage);
    }
  }
}

class _CollectionHandler extends GroupChannelCollectionHandler {
  final updated = <int>[];
  @override
  void onChannelsAdded(
      GroupChannelContext context, List<GroupChannel> channels) {}
  @override
  void onChannelsUpdated(
      GroupChannelContext context, List<GroupChannel> channels) {
    updated.addAll(channels.map((channel) => channel.lastMessage!.messageId));
  }

  @override
  void onChannelsDeleted(
      GroupChannelContext context, List<String> channelUrls) {}
}

class _ControlledIsar extends CounterIsar {
  _ControlledIsar(super.trace);
  bool fail = false;
  Completer<void>? gate;
  Future<void> _tail = Future<void>.value();
  @override
  Future<T> writeTxn<T>(Future<T> Function() callback,
      {bool silent = false}) async {
    final barrier = gate;
    gate = null;
    final previous = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    await previous;
    try {
      return await super.writeTxn(() async {
        if (barrier != null) await barrier.future;
        if (fail) {
          fail = false;
          throw StateError(_failure);
        }
        return callback();
      }, silent: silent);
    } finally {
      completion.complete();
    }
  }

  @override
  Future<void> clear() async {
    channels.clear();
    messages.clear();
    users.clear();
  }
}

class _DelayedIsar extends CounterIsar {
  _DelayedIsar(super.trace);
  @override
  IsarCollection<T> collection<T>() => _DelayedRows<T>(this);
}

class _DelayedRows<T> extends Rows<T> {
  _DelayedRows(super.owner);
  @override
  Future<Id> put(T object) async {
    await Future<void>.delayed(_putDelay);
    return super.put(object);
  }
}

GroupChannel _restore(Fixture f) {
  final restarted = AuditChat(f.trace);
  restarted.sdkInstance = f.chat.sdkInstance;
  final reopened = DB(chat: restarted, isar: f.isar);
  GroupChannel? restored;
  reopened.getGroupChannel(A.room).then((value) => restored = value);
  f.clock.flushMicrotasks();
  expect(restored, isNotNull);
  expect(restored!.chat, same(restarted));
  expect(restored!.lastMessage!.chat, same(restarted));
  expect(restored!.members.every((member) => identical(member.chat, restarted)),
      isTrue);
  return restored!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeAudit);
  test('$_reviewSecond $_isolatedCheckpoint', () {
    fakeAsync((clock) {
      final transport = Transport();
      io.HttpOverrides.runZoned(() {
        final original = Fixture(clock, transport, _isolatedCheckpoint);
        final nick = Fixture(clock, Transport(), _isolatedCheckpoint,
            instance: A.nick);
        original.cache(A.room);
        nick.cache(A.room);
        original.frame([read(A.one)]);
        nick.frame([read(A.many)]);
        original.chat.connectionManager.doDisconnect(clear: true);
        clock.flushMicrotasks();
        expect(original.trace.count(K.txnEnter), A.one);
        expect(nick.trace.count(K.txnEnter), A.zero);
        expect(_restore(original).getCachedReadStatus(A.room)[A.peer], A.one);
        nick.elapse(_checkpointWindow);
        expect(nick.trace.count(K.txnEnter), A.one);
        expect(_restore(nick).getCachedReadStatus(A.room)[A.peer], A.many);
        expect(_restore(original).getCachedReadStatus(A.room)[A.peer], A.one);
        original.settle();
        nick.settle();
      }, createHttpClient: (_) => transport);
    });
  });
  for (final instance in A.instances) {
    test('$_reviewSecond $_credentialCheckpoint $instance', () => audit(
        _credentialCheckpoint, (f) {
      f.cache(A.room);
      f.frame([read(A.many)]);
      var checks = A.zero;
      final errors = <Object>[];
      f.chat.connectionManager.connect(_newUser,
          shouldProceed: () => checks++ == A.zero).then<void>((_) {},
          onError: (Object error) => errors.add(error));
      f.clock.flushMicrotasks();
      expect(errors.single, isA<ConnectionCanceledException>());
      expect(f.trace.count(K.socketClose), A.one);
      expect(f.cacheState(A.room), A.cacheAbsent);
      expect(_restore(f).getCachedReadStatus(A.room)[A.peer], A.many);
      expect(f.trace.count(K.txnEnter), A.one);
      f.elapse(_checkpointWindow);
      expect(f.trace.count(K.txnEnter), A.one);
      f.settle();
    }, instance: instance));

    test('$_reviewSecond $_parentCheckpoint $instance', () => audit(
        _parentCheckpoint, (f) {
      f.cache(A.room);
      final port = _MessageDbPort(chat: f.chat, trace: f.trace, isar: f.isar)
        ..enabled = false;
      f.chat.dbManager = port;
      final channel = f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
      channel.lastMessage = UserMessage.fromJsonWithChat(f.chat, {
        ...messagePayload(A.one),
        _parentMessageId: A.zero,
        _parentMessage: messagePayload(A.zero),
      });
      final user = f.chat.chatContext.currentUser;
      f.chat.chatContext.currentUser = null;
      final handler = _MessageHandler();
      final collection = MessageCollection(channel: channel,
          params: MessageListParams(), handler: handler, chat: f.chat);
      f.chat.chatContext.currentUser = user;
      f.transport.fail = false;
      f.transport.responses[_messages] = {_messages: <dynamic>[]};
      collection.initialize();
      f.clock.flushMicrotasks();
      expect(collection.isInitialized, isTrue);
      f.transport.fail = true;
      collection.messageList.add(UserMessage.fromJsonWithChat(
          f.chat, messagePayload(A.zero)));
      expect(channel.lastMessage!.parentMessage, isNotNull);
      expect(channel.lastMessage!.parentMessage,
          isNot(same(collection.messageList.single)));
      port.enabled = true;
      port.upsertGroupChannels([channel]);
      f.clock.flushMicrotasks();
      f.frame([wire(CommandString.reaction, {
        A.channelUrl: A.room, A.channelType: A.group, A.messageId: A.zero,
        A.userId: A.peer, _reactionField: _reactionKey, _operation: _add,
        _updatedAt: A.one,
      })]);
      f.frame([wire(CommandString.thread, {
        A.channelUrl: A.room, A.channelType: A.group, _parentMessageId: A.zero,
        _threadInfo: {_replyCount: A.two, _updatedAt: A.two},
      })]);
      expect(handler.updated.length, A.two);
      expect(f.isar.messages[A.zero]!.reactions!.single.userIds, [A.peer]);
      expect(f.isar.messages[A.zero]!.threadInfo!.replyCount, A.two);
      f.trace.entries.clear();
      f.frame([for (var i = A.one; i <= A.many; i++) read(i)]);
      f.elapse(_checkpointWindow);
      final restored = _restore(f);
      expect(restored.lastMessage!.parentMessage!.reactions!.single.userIds,
          [A.peer]);
      expect(restored.lastMessage!.parentMessage!.threadInfo!.replyCount, A.two);
      expect(restored.getCachedReadStatus(A.room)[A.peer], A.many);
      expect(f.trace.count(K.read), A.many);
      expect(f.trace.count(K.txnEnter), A.one);
      expect(f.trace.of(K.row).where((row) => row.detail == _messageRow), isEmpty);
      collection.dispose();
      f.settle();
    }, instance: instance));

    test('$_reviewSecond $_clearCheckpoint $instance', () => audit(
        _clearCheckpoint, (f) {
      f.cache(A.room);
      f.frame([read(A.many)]);
      var disconnected = false;
      f.chat.connectionManager.doDisconnect(clear: true)
          .then((_) => disconnected = true);
      f.clock.flushMicrotasks();
      expect(disconnected, isTrue);
      f.elapse(_checkpointWindow);
      expect(_restore(f).getCachedReadStatus(A.room)[A.peer], A.many);
      expect(f.trace.count(K.read), A.one);
      expect(f.trace.count(K.txnEnter), A.one);
      expect(f.trace.count(K.row), A.one);
      expect(f.clock.pendingTimers, isEmpty);
      f.settle();
    }, instance: instance));
  }

  test('$_reviewSecond $_replaceCheckpoint', () async {
    final sdk = SendbirdChat.create();
    final options = SendbirdChatOptions(useCollectionCaching: false);
    await sdk.init(appId: A.app, options: options);
    fakeAsync((clock) {
      final transport = Transport();
      io.HttpOverrides.runZoned(() {
        final f = Fixture(clock, transport, _replaceCheckpoint, existing: sdk.chat);
        f.cache(A.room);
        f.frame([read(A.many)]);
        var replaced = false;
        sdk.init(appId: A.nick, options: options).then((_) => replaced = true);
        clock.flushMicrotasks();
        expect(replaced, isTrue);
        expect(sdk.chat, isNot(same(f.chat)));
        expect(clock.pendingTimers, isEmpty);
        expect(_restore(f).getCachedReadStatus(A.room)[A.peer], A.many);
        final writesAtReplacement = f.trace.count(K.txnEnter);
        f.elapse(_checkpointWindow);
        expect(f.trace.count(K.txnEnter), writesAtReplacement);
        expect(writesAtReplacement, A.one);
        f.settle();
      }, createHttpClient: (_) => transport);
    });
  });

  for (final replace in [false, true]) {
    for (final entered in [false, true]) {
      test('$_reviewSecond $_expiredCheckpoint $replace $entered', () async {
        final sdk = SendbirdChat.create();
        final options = SendbirdChatOptions(useCollectionCaching: false);
        await sdk.init(appId: A.app, options: options);
        fakeAsync((clock) {
          final transport = Transport();
          io.HttpOverrides.runZoned(() {
            final f = Fixture(clock, transport, _expiredCheckpoint,
                existing: sdk.chat);
            f.cache(A.room);
            final barrier = Completer<void>();
            final isar = _ControlledIsar(f.trace)
              ..channels.addAll(f.isar.channels)
              ..messages.addAll(f.isar.messages)
              ..users.addAll(f.isar.users)
              ..gate = barrier;
            final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
            f.chat.dbManager = port;
            final initialReadStatus = isar.channels[A.room]!.readStatus;
            if (!entered) {
              final channel = f.chat.channelCache
                  .find<GroupChannel>(channelKey: A.room)!;
              port.upsertGroupChannels([channel]);
              clock.flushMicrotasks();
            }
            f.frame([read(A.one)]);
            f.elapse(_checkpointWindow);
            var completed = false;
            final reset = replace
                ? sdk.init(appId: A.nick, options: options)
                : f.chat.connectionManager.doDisconnect(clear: true);
            reset.then((_) => completed = true);
            clock.flushMicrotasks();
            expect(completed, isFalse);
            f.elapse(_closeTimeout);
            expect(completed, isTrue);
            final rowsBeforeRelease = f.trace.count(K.row);
            barrier.complete();
            clock.flushMicrotasks();
            expect(isar.channels[A.room]!.readStatus, initialReadStatus);
            expect(f.trace.count(K.row) - rowsBeforeRelease,
                entered ? A.zero : A.two);
            expect(f.trace.count(K.txnEnter), A.one);
            expect(port.pending, A.zero);
            expect(clock.pendingTimers, isEmpty);
            late AuditSocket resumedSocket;
            f.chat.connectionManager = ConnectionManager(chat: f.chat,
                socketFactory: (data, closed, error) =>
                    resumedSocket = AuditSocket(data, f.trace));
            f.chat.connectionManager.changeState(ConnectedState(chat: f.chat));
            f.cache(A.room);
            resumedSocket.data(read(A.many));
            clock.flushMicrotasks();
            f.elapse(_checkpointWindow);
            if (!replace) {
              expect(jsonDecode(isar.channels[A.room]!.readStatus)[A.peer],
                  A.many);
              expect(f.trace.count(K.txnEnter), A.two);
            } else {
              expect(f.trace.count(K.txnEnter), A.one);
            }
            f.settle();
          }, createHttpClient: (_) => transport);
        });
      });
    }
  }
  test('$_review $_reactionQueue', () => audit(_reactionQueue, (f) {
    f.cache(A.room);
    final barrier = Completer<void>();
    final isar = _ControlledIsar(f.trace)
      ..channels.addAll(f.isar.channels)
      ..messages.addAll(f.isar.messages)
      ..users.addAll(f.isar.users)
      ..gate = barrier;
    final port = _MessageDbPort(chat: f.chat, trace: f.trace, isar: isar)
      ..enabled = false;
    f.chat.dbManager = port;
    final channel = f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
    final user = f.chat.chatContext.currentUser;
    f.chat.chatContext.currentUser = null;
    final handler = _MessageHandler();
    final collection = MessageCollection(channel: channel,
        params: MessageListParams(), handler: handler, chat: f.chat);
    f.chat.chatContext.currentUser = user;
    f.transport.fail = false;
    f.transport.responses[_messages] = {_messages: <dynamic>[]};
    collection.initialize();
    f.clock.flushMicrotasks();
    expect(collection.isInitialized, isTrue);
    f.transport.fail = true;
    f.trace.entries.clear();
    collection.messageList.add(UserMessage.fromJsonWithChat(
        f.chat, messagePayload(A.zero)));
    port.enabled = true;
    for (var i = A.one; i <= A.many; i++) {
      channel.name = i.toString();
      f.chat.eventManager.notifyChannelChanged(channel);
    }
    f.clock.flushMicrotasks();
    f.frame([wire(CommandString.reaction, {
      A.channelUrl: A.room, A.channelType: A.group, A.messageId: A.zero,
      A.userId: A.peer, _reactionField: _reactionKey, _operation: _add,
      _updatedAt: A.one,
    })]);
    expect(collection.messageList.single.reactions!.single.userIds, [A.peer]);
    f.frame([wire(CommandString.thread, {
      A.channelUrl: A.room, A.channelType: A.group, _parentMessageId: A.zero,
      _threadInfo: {_replyCount: A.two, _updatedAt: A.two},
    })]);
    expect(collection.messageList.single.threadInfo!.replyCount, A.two);
    barrier.complete();
    f.clock.flushMicrotasks();
    expect(handler.updated.length, A.two);
    expect(isar.messages[A.zero]!.reactions!.single.userIds, [A.peer]);
    expect(isar.messages[A.zero]!.threadInfo!.replyCount, A.two);
    expect(isar.channels[A.room]!.name, A.many.toString());
    f.frame([read(A.many)]);
    f.elapse(_checkpointWindow);
    GroupChannel? restored;
    DB(chat: AuditChat(f.trace), isar: isar).getGroupChannel(A.room)
        .then((value) => restored = value);
    f.clock.flushMicrotasks();
    expect(restored!.lastMessage!.reactions!.single.userIds, [A.peer]);
    expect(restored!.lastMessage!.threadInfo!.replyCount, A.two);
    expect(restored!.getCachedReadStatus(A.room)[A.peer], A.many);
    expect(port.pending, A.zero);
    collection.dispose();
    f.settle();
  }));

  for (final inviter in [false, true]) {
    test('$_review $_restriction $inviter', () => audit(_restriction, (f) {
      f.cache(A.room);
      final barrier = Completer<void>();
      final isar = _ControlledIsar(f.trace)..gate = barrier;
      final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
      f.chat.dbManager = port;
      final channel = f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
      final member = inviter
          ? (Member(userId: _inviter, nickname: _inviter)..set(f.chat))
          : channel.members.last;
      if (inviter) channel.inviter = member;
      member.isMuted = true;
      member.restrictionInfo = RestrictionInfo(
          description: _reasonBefore, endAt: A.one);
      f.chat.eventManager.notifyChannelChanged(channel);
      f.clock.flushMicrotasks();
      member.restrictionInfo = RestrictionInfo(
          description: _reasonAfter, endAt: A.two);
      f.chat.eventManager.notifyChannelChanged(channel);
      barrier.complete();
      f.clock.flushMicrotasks();
      GroupChannel? restored;
      DB(chat: AuditChat(f.trace), isar: isar).getGroupChannel(A.room)
          .then((value) => restored = value);
      f.clock.flushMicrotasks();
      final restoredMember = inviter ? restored!.inviter! : restored!.members.last;
      expect(restoredMember.isMuted, isTrue);
      expect(restoredMember.restrictionInfo!.endAt, A.two);
      expect(restoredMember.restrictionInfo!.description, _reasonAfter);
      expect(f.trace.count(K.txnEnter), A.two);
      expect(port.pending, A.zero);
      f.settle();
    }));
  }

  for (final instance in A.instances) {
    test('$_review $_receipt $instance', () => audit(_receipt, (f) {
      f.cache(A.room);
      for (var i = A.one; i <= A.many; i++) {
        f.frame([read(i)]);
      }
      f.elapse(_checkpointWindow);
      expect(f.trace.count(K.read), A.many);
      expect(f.trace.count(K.txnEnter), inInclusiveRange(A.one, _receiptBudget));
      expect(_restore(f).getCachedReadStatus(A.room)[A.peer], A.many);
      expect(f.trace.count(K.wsWire), A.zero);
      f.settle();
    }, instance: instance));
  }

  test('$_review $_receiptClose', () => audit(_receiptClose, (f) {
    f.cache(A.room);
    final barrier = Completer<void>();
    final isar = _ControlledIsar(f.trace)
      ..channels.addAll(f.isar.channels)
      ..messages.addAll(f.isar.messages)
      ..users.addAll(f.isar.users)
      ..gate = barrier;
    final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
    f.chat.dbManager = port;
    f.frame([for (var i = A.one; i <= A.many; i++) read(i)]);
    var disconnected = false;
    f.chat.eventDispatcher.onDisconnected().then((_) => disconnected = true);
    f.clock.flushMicrotasks();
    expect(disconnected, isFalse);
    barrier.complete();
    f.clock.flushMicrotasks();
    expect(disconnected, isTrue);
    expect(f.trace.count(K.read), A.many);
    expect(f.trace.count(K.txnEnter), inInclusiveRange(A.one, _receiptBudget));
    GroupChannel? restored;
    DB(chat: AuditChat(f.trace), isar: isar).getGroupChannel(A.room)
        .then((value) => restored = value);
    f.clock.flushMicrotasks();
    expect(restored!.getCachedReadStatus(A.room)[A.peer], A.many);
    expect(port.pending, A.zero);
    f.settle();
  }));

  for (final fails in [false, true]) {
    test('$_review $_receiptFailure $fails', () => audit(_receiptFailure, (f) {
      f.cache(A.room);
      final barrier = Completer<void>();
      final isar = _ControlledIsar(f.trace)
        ..fail = fails
        ..gate = fails ? null : barrier;
      final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
      f.chat.dbManager = port;
      f.frame([read(A.one)]);
      var disconnected = false;
      f.chat.eventDispatcher.onDisconnected().then((_) => disconnected = true);
      f.clock.flushMicrotasks();
      if (!fails) {
        expect(disconnected, isFalse);
        f.elapse(_closeTimeout);
      }
      expect(disconnected, isTrue);
      barrier.complete();
      f.clock.flushMicrotasks();
      f.frame([read(A.two)]);
      f.elapse(_checkpointWindow);
      expect(jsonDecode(isar.channels[A.room]!.readStatus)[A.peer], A.two);
      expect(f.trace.count(K.txnEnter), _receiptBudget);
      expect(port.pending, A.zero);
      f.settle();
    }));
  }
  for (final instance in A.instances) {
    for (final count in [A.one, A.many]) {
      for (final source in [
        CommandString.userMessage,
        CommandString.read,
        CommandString.systemEvent
      ]) {
        test(
            '$_suite $instance $source $count',
            () => audit('$_suite/$source/$count', (f) {
                  f.cache(A.room);
                  f.trace.entries.clear();
                  f.frame([
                    for (var i = A.one; i <= count; i++)
                      source == CommandString.userMessage
                          ? message(i)
                          : source == CommandString.read
                              ? read(i)
                              : typing(i)
                  ]);
                  f.elapse(A.local);
                  if (source == CommandString.userMessage) {
                    expect(f.handler.messages.length, count);
                    expect(f.isar.messages.keys,
                        containsAll([for (var i = A.one; i <= count; i++) i]));
                    expect(f.isar.channels[A.room]!.lastMessageRootId,
                        count.toString());
                    expect(f.trace.count(K.txnEnter),
                        inInclusiveRange(A.one, count));
                    expect(
                        f.trace
                            .of(K.row)
                            .where((row) => row.detail == _userRow),
                        isEmpty);
                    final restored = _restore(f);
                    expect(restored.lastMessage!.messageId, count);
                    expect(restored.members.length, A.members);
                    expect(restored.creator!.userId, A.self);
                  } else if (source == CommandString.read) {
                    expect(f.trace.count(K.read), count);
                    expect(
                        f.chat.channelCache
                            .find<ReadStatus>(channelKey: A.room, key: A.peer)!
                            .timestamp,
                        count);
                    expect(f.trace.count(K.txnEnter),
                        inInclusiveRange(A.one, _receiptBudget));
                    expect(_restore(f).getCachedReadStatus(A.room)[A.peer], count);
                  } else {
                    expect(f.trace.count(K.typing), count);
                    expect(
                        f.chat.channelCache
                            .find<GroupChannel>(channelKey: A.room)!
                            .getTypingUsers()
                            .single
                            .userId,
                        A.peer);
                    expect(f.trace.count(K.txnEnter), A.zero);
                    f.chat.channelCache
                        .find<TypingStatus>(channelKey: A.room, key: A.peer)!
                        .removeFromCache(f.chat);
                  }
                  f.settle();
                }, instance: instance));
      }
    }
  }

  for (final instance in A.instances) {
    test(
        '$_suite $_active $instance',
        () => audit(_active, (f) {
              f.db.enabled = false;
              f.transport.fail = false;
              f.transport.responses[_listPath] = {
                _channels: [channelJson(A.room)],
                _next: A.empty
              };
              final handler = _CollectionHandler();
              final collection = GroupChannelCollection(
                  query: GroupChannelListQuery(chat: f.chat), handler: handler);
              collection.loadMore();
              f.clock.flushMicrotasks();
              expect(collection.channelList.length, A.one);
              f.db.enabled = true;
              f.transport.fail = true;
              f.trace.entries.clear();
              f.frame([for (var i = A.one; i <= A.many; i++) message(i)]);
              f.elapse(A.local);
              expect(f.handler.messages.length, A.many);
              expect(handler.updated.length, A.many);
              expect(
                  collection.channelList.single.lastMessage!.messageId, A.many);
              expect(f.isar.messages.keys,
                  containsAll([for (var i = A.one; i <= A.many; i++) i]));
              expect(f.trace.count(K.txnEnter), A.many);
              expect(f.trace.of(K.row).where((row) => row.detail == _userRow),
                  isEmpty);
              collection.dispose();
              f.settle();
            }, instance: instance));
  }

  test(
      '$_suite $_dirty',
      () => audit(_dirty, (f) {
            f.cache(A.room);
            final channel =
                f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
            channel.members.last.nickname = _nickname;
            channel.members.last.role = Role.operator;
            f.chat.eventManager.notifyChannelChanged(channel);
            f.clock.flushMicrotasks();
            expect(f.trace.count(K.txnEnter), A.one);
            expect(
                f.trace.of(K.row).where((row) => row.detail == _userRow).length,
                A.one);
            final restored = _restore(f);
            expect(restored.members.last.nickname, _nickname);
            expect(restored.members.last.role, Role.operator);
            f.settle();
          }));

  test(
      '$_suite $_checkpoint',
      () => audit(_checkpoint, (f) {
            f.cache(A.room);
            f.frame([read(A.many)]);
            expect(f.trace.count(K.txnEnter), A.zero);
            f.frame([message(A.one)]);
            expect(f.trace.count(K.txnEnter), A.one);
            expect(jsonDecode(f.isar.channels[A.room]!.readStatus)[A.peer],
                A.many);
            final restored = _restore(f);
            expect(restored.getCachedReadStatus(A.room)[A.peer], A.many);
            f.settle();
          }));

  for (final count in [A.one, A.many]) {
    test(
        '$_suite $_ownCheckpoint $count',
        () => audit(_ownCheckpoint, (f) {
              f.cache(A.room);
              f.frame([
                for (var i = A.one; i <= count; i++)
                  wire(CommandString.read,
                      {...readPayload(i), A.user: userJson(A.self)})
              ]);
              f.elapse(A.local);
              expect(f.trace.count(K.read), count);
              expect(_restore(f).myLastRead, count);
              expect(f.trace.count(K.txnEnter), inInclusiveRange(A.one, count));
              expect(f.trace.count(K.wsWire), A.zero);
              f.settle();
            }));
  }

  test(
      '$_suite $_related',
      () => audit(_related, (f) {
            f.cache(A.room);
            final channel =
                f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
            channel.inviter = Member(userId: _inviter, nickname: _inviter)
              ..set(f.chat);
            channel.lastPinnedMessage =
                UserMessage.fromJsonWithChat(f.chat, messagePayload(A.two));
            channel.pinnedMessageIds = [A.two];
            f.chat.eventManager.notifyChannelChanged(channel);
            f.clock.flushMicrotasks();
            expect(f.trace.count(K.txnEnter), A.one);
            final restored = _restore(f);
            expect(restored.inviter!.userId, _inviter);
            expect(restored.lastPinnedMessage!.messageId, A.two);
            expect(restored.pinnedMessageIds, [A.two]);
            expect(restored.members.length, A.members);
            f.settle();
          }));

  test(
      '$_suite $_retry',
      () => audit(_retry, (f) {
            final isar = _ControlledIsar(f.trace)..fail = true;
            final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
            f.chat.dbManager = port;
            final channel = f.channel(A.room);
            final errors = <Object>[];
            port.upsertGroupChannels([channel]).then<void>((_) {},
                onError: (Object error) {
              errors.add(error);
            });
            f.clock.flushMicrotasks();
            expect(errors.single, isA<StateError>());
            expect(isar.channels, isEmpty);
            port.upsertGroupChannels([channel]);
            f.clock.flushMicrotasks();
            expect(isar.channels.keys, [A.room]);
            expect(isar.messages.keys, [A.zero]);
            expect(isar.users.length, A.members);
            expect(f.trace.count(K.txnEnter), A.two);
            expect(port.pending, A.zero);
            f.settle();
          }));

  test(
      '$_suite $_scheduled',
      () => audit(_scheduled, (f) {
            f.cache(A.room);
            final channel =
                f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
            channel.lastMessage!.scheduledInfo = ScheduledInfo(
                scheduledMessageId: A.one,
                scheduledAt: A.one,
                scheduledStatus: ScheduledStatus.pending);
            f.chat.eventManager.notifyChannelChanged(channel);
            channel.lastMessage!.scheduledInfo!.scheduledAt = A.two;
            f.chat.eventManager.notifyChannelChanged(channel);
            f.clock.flushMicrotasks();
            expect(_restore(f).lastMessage!.scheduledInfo!.scheduledAt, A.two);
            expect(f.trace.count(K.txnEnter), A.two);
            f.settle();
          }));

  for (final frames in [A.sameFrame, A.separateFrames]) {
    for (final active in [false, true]) {
      test(
          '$_suite $_delayed $frames $active',
          () => audit('$_delayed/$frames/$active', (f) {
                final isar = _DelayedIsar(f.trace)
                  ..channels.addAll(f.isar.channels)
                  ..messages.addAll(f.isar.messages)
                  ..users.addAll(f.isar.users);
                final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
                f.chat.dbManager = port;
                final handler = _CollectionHandler();
                GroupChannelCollection? collection;
                if (active) {
                  port.enabled = false;
                  f.transport.fail = false;
                  f.transport.responses[_listPath] = {
                    _channels: [channelJson(A.room)],
                    _next: A.empty
                  };
                  collection = GroupChannelCollection(
                      query: GroupChannelListQuery(chat: f.chat),
                      handler: handler);
                  collection.loadMore();
                  f.clock.flushMicrotasks();
                  expect(collection.channelList.length, A.one);
                  port.enabled = true;
                  f.transport.fail = true;
                  f.chat.channelCache.markAsDirtyAll();
                }
                f.trace.entries.clear();
                if (frames == A.sameFrame) {
                  f.frame([for (var i = A.one; i <= A.burst; i++) message(i)]);
                } else {
                  for (var i = A.one; i <= A.burst; i++) {
                    f.frame([message(i)]);
                  }
                }
                f.elapse(A.timeout);
                expect(f.handler.messages.length, A.burst);
                expect(f.trace.count(K.httpTransport), A.one);
                expect(f.cacheState(A.room), A.cacheDirty);
                f.elapse(_drain);
                expect(isar.messages.keys,
                    containsAll([for (var i = A.one; i <= A.burst; i++) i]));
                expect(isar.channels[A.room]!.lastMessageRootId,
                    A.burst.toString());
                expect(f.trace.count(K.txnEnter), A.burst);
                expect(port.pending, A.zero);
                if (collection != null) {
                  expect(handler.updated.length, A.burst);
                  expect(handler.updated.last, A.burst);
                  expect(collection.channelList.single.lastMessage!.messageId,
                      A.burst);
                  collection.dispose();
                }
                f.settle();
              }));
    }
  }

  test(
      '$_suite $_clear',
      () => audit(_clear, (f) {
            final barrier = Completer<void>();
            final isar = _ControlledIsar(f.trace)..gate = barrier;
            final port = DbPort(chat: f.chat, trace: f.trace, isar: isar);
            f.chat.dbManager = port;
            final channel = f.channel(A.room);
            port.upsertGroupChannels([channel]);
            channel.lastMessage =
                UserMessage.fromJsonWithChat(f.chat, messagePayload(A.one));
            port.upsertGroupChannels([channel]);
            port.db.clear();
            barrier.complete();
            f.clock.flushMicrotasks();
            expect(isar.channels, isEmpty);
            expect(isar.messages, isEmpty);
            port.upsertGroupChannels([channel]);
            f.clock.flushMicrotasks();
            expect(isar.messages.keys, [A.one]);
            expect(port.pending, A.zero);
            f.settle();
          }));
}
