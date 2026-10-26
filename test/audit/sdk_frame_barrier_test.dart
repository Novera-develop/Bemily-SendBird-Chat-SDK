import 'dart:async';
import 'dart:io' as io;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/delivery_status.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/command/command_type.dart';

import 'sdk_audit_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeAudit);
  for (final barrier in [A.lookupBarrier, A.offsetBarrier, A.cacheWarm]) {
    for (final frameMode in [A.sameFrame, A.separateFrames]) {
      test('${A.t05} $barrier $frameMode', () => audit(
          '${A.t05}/$barrier/$frameMode', (f) {
        f.cache(A.room, dirty: barrier == A.lookupBarrier);
        f.cache(A.warmRoom);
        f.transport.fail = false;
        final gate = Completer<void>();
        if (barrier != A.cacheWarm) f.transport.barrier = gate;
        bool hidden = false;
        if (barrier == A.offsetBarrier) {
          final channel = f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
          channel.hide().then((_) => hidden = true);
          f.clock.flushMicrotasks();
          expect(f.commands.messageOffsetTsCompleterMap.length, A.one);
        }
        bool ack = false;
        f.sendRead(A.requestA).then((_) => ack = true);
        f.clock.flushMicrotasks();
        expect(f.commands.pendingRequests.length, A.one);
        expect(f.commands.activeTimers, A.two);
        final input = [message(A.one), message(A.two, room: A.warmRoom),
          read(A.one, request: A.requestA)];
        if (frameMode == A.sameFrame) {
          f.frame(input);
        } else {
          for (final command in input) { f.frame([command]); }
        }
        final blocked = barrier != A.cacheWarm;
        if (blocked && frameMode == A.sameFrame) {
          expect(f.handler.messages, isEmpty);
          expect(ack, isFalse);
          expect(f.trace.count(K.commandStart), A.one);
        } else if (blocked) {
          expect(f.handler.messages.map((m) => m.messageId), [A.two]);
          expect(ack, isTrue);
          expect(f.trace.count(K.commandStart), A.two + A.one);
        } else {
          expect(f.handler.messages.length, A.two);
          expect(ack, isTrue);
        }
        if (blocked) {
          f.elapse(A.tick);
          gate.complete();
          f.clock.flushMicrotasks();
        }
        expect(f.handler.messages.map((m) => m.messageId).toSet(), {A.one, A.two});
        expect(ack, isTrue);
        expect(f.trace.count(K.ackSettled), A.one);
        final expectedAckTime = blocked && frameMode == A.sameFrame ? A.tick : Duration.zero;
        expect(f.trace.of(K.ackSettled).single.time, expectedAckTime);
        expect(f.trace.of(K.httpTransport).where((e) => e.detail == A.get).length,
            barrier == A.lookupBarrier ? A.one : A.zero);
        if (barrier == A.offsetBarrier) expect(hidden, isTrue);
        expect(f.commands.messageOffsetTsCompleterMap, isEmpty);
        expect(f.isar.messages.keys, containsAll([A.one, A.two]));
        f.settle();
      }));
    }
  }
  for (final frameMode in [A.sameFrame, A.separateFrames]) {
    test('${A.t05} ${A.timeoutAck} $frameMode', () => audit(
        '${A.t05}/${A.timeoutAck}/$frameMode', (f) {
      f.cache(A.room, dirty: true);
      f.cache(A.warmRoom);
      Object? ackFailure;
      bool ackSuccess = false;
      f.sendRead(A.requestA).then((_) => ackSuccess = true,
          onError: (Object error) { ackFailure = error; return false; });
      f.clock.flushMicrotasks();
      final input = [message(A.one), message(A.two, room: A.warmRoom),
        read(A.one, request: A.requestA)];
      if (frameMode == A.sameFrame) {
        f.frame(input);
      } else {
        for (final command in input) { f.frame([command]); }
      }
      f.elapse(A.dead);
      if (frameMode == A.sameFrame) {
        expect(ackFailure, isA<WebSocketFailedException>());
        expect(ackSuccess, isFalse);
        expect(f.trace.count(K.socketClose), A.one);
      } else {
        expect(ackFailure, isNull);
        expect(ackSuccess, isTrue);
        expect(f.trace.count(K.socketClose), A.zero);
      }
      f.elapse(A.timeout - A.dead);
      expect(f.handler.messages.map((m) => m.messageId).toSet(), {A.one, A.two});
      expect(f.trace.count(K.httpTransport), A.one);
      if (frameMode == A.sameFrame) f.elapse(A.timeout);
      expect(f.trace.count(K.commandEnd), A.two + A.one);
      f.settle();
    }));
  }
  test('${A.t05} ${A.deleteWarm}', () => audit('${A.t05}/${A.deleteWarm}', (f) {
    f.cache(A.room);
    f.frame([wire(CommandString.messageDeleted, messagePayload(A.one))]);
    expect(f.trace.count(K.deleted), A.one);
    expect(f.trace.count(K.httpTransport), A.zero);
    f.settle();
  }));
  for (final missing in [false, true]) {
    test('${A.t05} ${missing ? A.ackMissing : A.ackLater}', () => audit(
        '${A.t05}/${missing ? A.ackMissing : A.ackLater}', (f) {
      f.cache(A.room);
      bool early = false;
      bool late = false;
      f.sendRead(A.requestA).then((_) => early = true);
      f.clock.flushMicrotasks();
      f.elapse(A.tick);
      f.sendRead(A.requestB).then((_) => late = true);
      f.clock.flushMicrotasks();
      expect(f.commands.pendingRequests.length, A.two);
      expect(f.commands.activeTimers, A.two * A.two);
      f.frame([read(A.two, request: A.requestB)]);
      expect(late, isTrue);
      expect(early, isFalse);
      expect(f.commands.activeTimers, A.zero);
      expect(f.commands.pendingRequests, {A.requestA});
      if (missing) {
        f.elapse(A.timeout + A.dead);
        expect(early, isFalse);
        expect(f.commands.pendingRequests, {A.requestA});
        expect(f.trace.count(K.ackFailed), A.zero);
      }
      f.frame([read(A.one, request: A.requestA)]);
      expect(early, isTrue);
      expect(f.trace.count(K.ackSettled), A.two);
      f.settle();
    }));
  }
  test('${A.t05} ${A.deletion}', () => audit('${A.t05}/${A.deletion}', (f) {
    f.db.enabled = false;
    f.cache(A.warmRoom);
    f.frame([wire(CommandString.messageDeleted, messagePayload(A.one)),
      message(A.two, room: A.warmRoom)]);
    expect(f.trace.count(K.deleted), A.zero);
    expect(f.handler.messages, isEmpty);
    f.elapse(A.timeout);
    expect(f.trace.count(K.deleted), A.zero);
    expect(f.handler.messages.single.messageId, A.two);
    expect(f.trace.count(K.httpTransport), A.one);
    expect(f.trace.count(K.commandEnd), A.two);
    f.settle();
  }));
  test('${A.t05} ${A.delivery}', () {
    fakeAsync((clock) {
      final originalTransport = Transport();
      final nickTransport = Transport();
      late Fixture original;
      late Fixture nick;
      io.HttpOverrides.runZoned(() {
        original = Fixture(clock, originalTransport, '${A.t05}/${A.delivery}',
            existing: SendbirdChat.instance.chat);
        original.cache(A.room);
      }, createHttpClient: (_) => originalTransport);
      io.HttpOverrides.runZoned(() {
        nick = Fixture(clock, nickTransport, '${A.t05}/${A.delivery}', instance: A.nick);
        nick.cache(A.room);
        original.trace.entries.clear();
        nick.trace.entries.clear();
        nick.frame([wire(CommandString.delivery, {
          A.channelUrl: A.room, A.updated: {A.peer: A.one},
        })]);
        expect(nick.handler.deliveryChannels.length, A.one);
        final deliveredChannel = nick.handler.deliveryChannels.single;
        expect(identical(deliveredChannel.chat, original.chat), isTrue);
        expect(identical(deliveredChannel.chat, nick.chat), isFalse);
        expect(original.handler.deliveryChannels, isEmpty);
        expect(nick.chat.channelCache.find<DeliveryStatus>(channelKey: A.room)!
            .updatedDeliveryStatus[A.peer], A.one);
        expect(original.trace.count(K.httpTransport), A.zero);
        expect(nick.trace.count(K.httpTransport), A.zero);
        nick.settle();
        original.settle();
        original.trace.dump();
        nick.trace.dump();
      }, createHttpClient: (_) => nickTransport);
    });
  });
}
