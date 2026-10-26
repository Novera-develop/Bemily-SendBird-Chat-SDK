import 'dart:convert';
import 'dart:io' as io;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_cache/cache_service.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/read_status.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/typing_status.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';

import 'sdk_audit_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeAudit);
  for (final state in [A.cacheAbsent, A.cacheDirty]) {
    for (final frames in [A.sameFrame, A.separateFrames]) {
      test('${A.t00} $state $frames', () => audit('${A.t00}/$state/$frames', (f) {
        if (state == A.cacheDirty) f.cache(A.room, dirty: true);
        final inputs = [for (var i = A.one; i <= A.burst; i++) message(i)];
        if (frames == A.sameFrame) {
          f.frame(inputs);
        } else {
          for (final input in inputs) { f.frame([input]); }
        }
        expect(f.trace.count(K.httpTransport), A.one);
        expect(f.handler.messages, isEmpty);
        f.elapse(A.timeout);
        expect(f.trace.count(K.httpTransport), A.one);
        expect(f.handler.messages.map((m) => m.messageId),
            orderedEquals([for (var i = A.one; i <= A.burst; i++) i]));
        expect(f.trace.of(K.callback).last.time, A.timeout);
        expect(f.cacheState(A.room), A.cacheDirty);
        final flights = frames == A.sameFrame ? A.burst : A.one;
        expect(f.trace.count(K.flightInsert), flights);
        expect(f.trace.count(K.flightRemove), flights);
        if (frames == A.sameFrame) {
          expect(f.isar.messages.keys, containsAll([for (var i = A.one; i <= A.burst; i++) i]));
        } else {
          expect(f.isar.messages.keys.toSet(),
              {for (var i = A.zero; i <= A.burst; i++) i});
        }
        expect(f.isar.channels[A.room]!.lastMessageRootId, A.burst.toString());
        f.settle();
      }));
    }
  }
  test('${A.t00} ${A.settleCache}', () => audit('${A.t00}/${A.settleCache}', (f) {
    f.handler.onReceive = (channel) => channel.saveToCache(f.chat);
    f.frame([for (var i = A.one; i <= A.burst; i++) message(i)]);
    f.elapse(A.timeout);
    expect(f.handler.messages.length, A.burst);
    expect(f.trace.count(K.httpTransport), A.one);
    expect(f.trace.of(K.callback).last.time, A.timeout);
    expect(f.cacheState(A.room), A.cacheDirty);
    f.settle();
  }));
  for (final instance in A.instances) {
    for (final count in [A.one, A.many]) {
      for (final source in [CommandString.userMessage, CommandString.read, CommandString.systemEvent]) {
        test('${A.t01} $instance $source $count', () => audit(
            '${A.t01}/$source/$count', (f) {
          f.cache(A.room);
          f.trace.entries.clear();
          expect(f.chat.collectionManager.groupChannelCollections, isEmpty);
          expect(f.chat.collectionManager.baseMessageCollections, isEmpty);
          expect(f.chat.chatContext.options.useCollectionCaching, isTrue);
          f.frame([for (var i = A.one; i <= count; i++)
            source == CommandString.userMessage ? message(i)
                : source == CommandString.read ? read(i) : typing(i)]);
          f.elapse(A.local);
          expect(f.db.pending, A.zero);
          final persisted = source == CommandString.userMessage ? count : A.zero;
          final checkpoints = source == CommandString.read ? A.one : A.zero;
          expect(f.trace.count(K.upsert), persisted * A.two + checkpoints);
          expect(f.trace.count(K.txnEnter), persisted + checkpoints);
          expect(f.trace.count(K.row), persisted * A.two + checkpoints);
          expect(f.isar.users.length, A.members);
          expect(f.isar.channels.keys, [A.room]);
          expect(f.trace.count(K.httpTransport), A.zero);
          expect(f.trace.entries.every((e) => e.instance == instance), isTrue);
          if (source == CommandString.userMessage) {
            expect(f.handler.messages.length, count);
            expect(f.handler.messages.map((m) => m.messageId).toSet().length, count);
            expect(f.isar.messages.keys, containsAll([for (var i = A.one; i <= count; i++) i]));
            expect(f.isar.channels[A.room]!.lastMessageRootId, count.toString());
            expect(f.trace.count(K.wsLogical), count);
            expect(f.trace.count(K.wsWire), count);
          } else if (source == CommandString.read) {
            expect(f.trace.count(K.read), count);
            expect(f.chat.channelCache.find<ReadStatus>(channelKey: A.room, key: A.peer)!.timestamp, count);
            expect(f.trace.count(K.wsWire), A.zero);
            expect(jsonDecode(f.isar.channels[A.room]!.readStatus)[A.peer], count);
          } else {
            expect(f.trace.count(K.typing), count);
            expect(f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!.getTypingUsers().single.userId, A.peer);
            expect(f.trace.count(K.wsWire), A.zero);
            final status = f.chat.channelCache.find<TypingStatus>(channelKey: A.room, key: A.peer)!;
            expect(status.typingTimer!.isActive, isTrue);
            status.removeFromCache(f.chat);
          }
          f.settle();
        }, instance: instance));
      }
    }
  }
  test('${A.t01} ${A.dualInstance}', () {
    fakeAsync((clock) {
      final originalTransport = Transport();
      final nickTransport = Transport();
      late Fixture original;
      late Fixture nick;
      io.HttpOverrides.runZoned(() {
        original = Fixture(clock, originalTransport, '${A.t01}/${A.dualInstance}');
        original.cache(A.room);
      }, createHttpClient: (_) => originalTransport);
      io.HttpOverrides.runZoned(() {
        nick = Fixture(clock, nickTransport, '${A.t01}/${A.dualInstance}', instance: A.nick);
        nick.cache(A.room);
      }, createHttpClient: (_) => nickTransport);
      original.trace.entries.clear();
      nick.trace.entries.clear();
      original.socket.data(message(A.one));
      nick.socket.data(message(A.two));
      clock.flushMicrotasks();
      original.settle();
      nick.settle();
      expect(original.handler.messages.single.messageId, A.one);
      expect(nick.handler.messages.single.messageId, A.two);
      expect(original.isar.messages.containsKey(A.two), isFalse);
      expect(nick.isar.messages.containsKey(A.one), isFalse);
      expect(original.handler.messages.single.chat, same(original.chat));
      expect(nick.handler.messages.single.chat, same(nick.chat));
      for (final f in [original, nick]) {
        expect(f.trace.count(K.txnEnter), A.one);
        expect(f.trace.count(K.upsert), A.two);
        expect(f.trace.count(K.wsWire), A.one);
        expect(f.trace.count(K.httpTransport), A.zero);
        f.trace.dump();
      }
    });
  });

}
