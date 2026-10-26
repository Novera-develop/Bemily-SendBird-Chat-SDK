import 'dart:async';
import 'dart:io' as io;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';

import 'sdk_audit_fixture.dart';

abstract class M49 {
  static const absent = 'M49 absent database preserves retry and failure';
  static const success = 'M49 successful lookup remains warm';
  static const fallback = 'M49 fallback settles dirty in owning cache';
  static const recovery = 'M49 explicit refresh bypasses backoff';
  static const expiry = 'M49 expired backoff fetches fresh once';
  static const offset = 'M49 dirty live offset hidden and member state survive fallback';
  static const removed = 'M49 cache removal invalidates fallback backoff';
  static const otherRoom = 'M49 fallback does not suppress another channel';
  static const isolation = 'M49 concurrent SDK fallback stays isolated';
  static const collection = 'M49 fallback updates a loaded channel collection';
  static const hide = 'M49 fallback still awaits hide offset completion';
  static const listPath = 'my_group_channels';
  static const channels = 'channels';
  static const next = 'next';
  static const expiryWait = Duration(seconds: 6);
}

class M49CollectionHandler extends GroupChannelCollectionHandler {
  final updated = <int>[];
  @override
  void onChannelsAdded(GroupChannelContext context, List<GroupChannel> channels) {}
  @override
  void onChannelsUpdated(GroupChannelContext context, List<GroupChannel> channels) {
    updated.addAll(channels.map((channel) => channel.lastMessage!.messageId));
  }
  @override
  void onChannelsDeleted(GroupChannelContext context, List<String> channelUrls) {}
}

class M49HideTransport extends Transport {
  final hideGate = Completer<void>();
  @override
  Future<io.HttpClientRequest> openUrl(String method, Uri url) async {
    if (url.pathSegments.last != A.hideSuffix) return super.openUrl(method, url);
    trace!.add(K.httpTransport, method);
    await hideGate.future;
    return Request({A.offsetTimestamp: A.two});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeAudit);

  test(M49.absent, () => audit(M49.absent, (f) {
    f.isar.channels.clear();
    final errors = <Object>[];
    for (var i = A.zero; i < A.two; i++) {
      GroupChannel.getChannel(A.room, chat: f.chat).then<void>((_) => fail(M49.absent),
          onError: (Object error) { errors.add(error); });
      f.clock.flushMicrotasks();
      f.elapse(A.timeout);
    }
    expect(errors.length, A.two);
    expect(f.trace.count(K.httpTransport), A.two);
    expect(f.cacheState(A.room), A.cacheAbsent);
    f.settle();
  }));

  test(M49.success, () => audit(M49.success, (f) {
    f.transport.fail = false;
    f.frame([message(A.one), message(A.two)]);
    expect(f.trace.count(K.httpTransport), A.one);
    expect(f.handler.messages.length, A.two);
    expect(f.cacheState(A.room), A.cacheWarm);
    expect(f.isar.messages.keys, containsAll([A.one, A.two]));
    f.settle();
  }));

  for (final instance in A.instances) {
    test('${M49.fallback} $instance', () => audit(M49.fallback, (f) {
      f.frame([message(A.one), message(A.two)]);
      f.elapse(A.timeout);
      final cached = f.chat.channelCache.find<GroupChannel>(channelKey: A.room);
      expect(cached, isNotNull);
      expect(cached!.chat, same(f.chat));
      expect(cached.dirty, isTrue);
      expect(cached.fromCache, isTrue);
      expect(f.trace.count(K.httpTransport), A.one);
      expect(f.handler.messages.length, A.two);
      expect(f.isar.messages.keys, containsAll([A.one, A.two]));
      f.settle();
    }, instance: instance));
  }

  test(M49.recovery, () => audit(M49.recovery, (f) {
    f.frame([message(A.one)]);
    f.elapse(A.timeout);
    expect(f.cacheState(A.room), A.cacheDirty);
    f.transport.fail = false;
    GroupChannel? fresh;
    GroupChannel.refresh(A.room, chat: f.chat).then((value) => fresh = value);
    f.clock.flushMicrotasks();
    expect(fresh, isNotNull);
    expect(fresh!.fromCache, isFalse);
    expect(fresh!.dirty, isFalse);
    expect(f.trace.count(K.httpTransport), A.two);
    f.frame([message(A.two)]);
    expect(f.trace.count(K.httpTransport), A.two);
    expect(f.handler.messages.length, A.two);
    expect(f.cacheState(A.room), A.cacheWarm);
    f.settle();
  }));

  test(M49.offset, () => audit(M49.offset, (f) {
    f.cache(A.room, dirty: true);
    final cached = f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
    cached.messageOffsetTimestamp = A.two;
    cached.isHidden = true;
    cached.hiddenState = GroupChannelHiddenState.preventAutoUnhide;
    cached.myMemberState = MemberState.none;
    cached.members.removeWhere((member) => member.userId == A.peer);
    f.frame([message(A.one), message(A.two)]);
    f.elapse(A.timeout);
    expect(f.handler.messages.map((message) => message.messageId), [A.two]);
    expect(f.trace.count(K.httpTransport), A.one);
    final current = f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!;
    expect(current.messageOffsetTimestamp, A.two);
    expect(current.isHidden, isTrue);
    expect(current.hiddenState, GroupChannelHiddenState.preventAutoUnhide);
    expect(current.myMemberState, MemberState.none);
    expect(current.members.any((member) => member.userId == A.peer), isFalse);
    expect(f.isar.messages.containsKey(A.one), isFalse);
    expect(f.isar.messages.containsKey(A.two), isTrue);
    f.settle();
  }));

  test(M49.removed, () => audit(M49.removed, (f) {
    f.frame([message(A.one)]);
    f.elapse(A.timeout);
    expect(f.cacheState(A.room), A.cacheDirty);
    f.chat.channelCache.deleteAll();
    f.transport.fail = false;
    f.frame([message(A.two)]);
    expect(f.trace.count(K.httpTransport), A.two);
    expect(f.handler.messages.length, A.two);
    expect(f.cacheState(A.room), A.cacheWarm);
    f.settle();
  }));

  test(M49.otherRoom, () => audit(M49.otherRoom, (f) {
    f.frame([message(A.one)]);
    f.elapse(A.timeout);
    f.transport.fail = false;
    f.frame([message(A.two, room: A.warmRoom)]);
    expect(f.trace.count(K.httpTransport), A.two);
    expect(f.handler.messages.length, A.two);
    expect(f.cacheState(A.warmRoom), A.cacheWarm);
    f.settle();
  }));

  test(M49.collection, () => audit(M49.collection, (f) {
    f.db.enabled = false;
    f.transport.fail = false;
    f.transport.responses[M49.listPath] = {
      M49.channels: [channelJson(A.room)], M49.next: A.empty,
    };
    final handler = M49CollectionHandler();
    final collection = GroupChannelCollection(
        query: GroupChannelListQuery(chat: f.chat), handler: handler);
    collection.loadMore();
    f.clock.flushMicrotasks();
    expect(collection.channelList.length, A.one);
    f.db.enabled = true;
    f.transport.fail = true;
    f.chat.channelCache.markAsDirtyAll();
    f.trace.entries.clear();
    f.frame([for (var i = A.one; i <= A.burst; i++) message(i)]);
    f.elapse(A.timeout);
    expect(f.handler.messages.length, A.burst);
    expect(handler.updated.length, greaterThanOrEqualTo(A.burst));
    expect(handler.updated, everyElement(inInclusiveRange(A.one, A.burst)));
    expect(handler.updated.last, A.burst);
    expect(collection.channelList.single.lastMessage!.messageId, A.burst);
    expect(collection.channelList.single.dirty, isTrue);
    expect(f.trace.count(K.httpTransport), A.one);
    expect(f.isar.messages.keys, containsAll(
        [for (var i = A.one; i <= A.burst; i++) i]));
    collection.dispose();
    f.settle();
  }));

  test(M49.hide, () => fakeAsync((clock) {
    final transport = M49HideTransport();
    io.HttpOverrides.runZoned(() {
      final f = Fixture(clock, transport, M49.hide);
      final stored = f.channel(A.room)
        ..messageOffsetTimestamp = A.two
        ..isHidden = true
        ..hiddenState = GroupChannelHiddenState.preventAutoUnhide;
      f.db.upsertGroupChannels([stored]);
      clock.flushMicrotasks();
      f.trace.entries.clear();
      GroupChannel? channel;
      GroupChannel.getChannel(A.room, chat: f.chat).then((value) => channel = value);
      clock.flushMicrotasks();
      f.elapse(A.timeout);
      expect(channel, isNotNull);
      bool hidden = false;
      channel!.hide(hidePreviousMessage: true, allowAutoUnhide: false)
          .then((_) => hidden = true);
      clock.flushMicrotasks();
      f.frame([message(A.one), message(A.two)]);
      expect(hidden, isFalse);
      expect(f.handler.messages, isEmpty);
      expect(f.commands.messageOffsetTsCompleterMap.length, A.one);
      transport.hideGate.complete();
      clock.flushMicrotasks();
      expect(hidden, isTrue);
      expect(f.handler.messages.map((message) => message.messageId), [A.two]);
      expect(channel!.isHidden, isTrue);
      expect(channel!.messageOffsetTimestamp, A.two);
      expect(f.isar.messages.containsKey(A.one), isFalse);
      expect(f.isar.messages.containsKey(A.two), isTrue);
      expect(f.trace.of(K.httpTransport).where((entry) => entry.detail == A.get).length, A.one);
      f.settle();
      f.trace.dump();
    }, createHttpClient: (_) => transport);
  }));

  test(M49.isolation, () => fakeAsync((clock) {
    final fixtures = <Fixture>[];
    for (final instance in A.instances) {
      final transport = Transport();
      io.HttpOverrides.runZoned(() {
        final f = Fixture(clock, transport, M49.isolation, instance: instance);
        fixtures.add(f);
        f.frame([message(instance == A.original ? A.one : A.two)]);
      }, createHttpClient: (_) => transport);
    }
    clock.elapse(A.timeout);
    for (final f in fixtures) {
      final ownId = f.chat.sdkInstance == A.original ? A.one : A.two;
      final otherId = ownId == A.one ? A.two : A.one;
      expect(f.handler.messages.single.messageId, ownId);
      expect(f.handler.messages.single.chat, same(f.chat));
      expect(f.chat.channelCache.find<GroupChannel>(channelKey: A.room)!.chat, same(f.chat));
      expect(f.isar.messages.containsKey(ownId), isTrue);
      expect(f.isar.messages.containsKey(otherId), isFalse);
      expect(f.trace.count(K.httpTransport), A.one);
      f.settle();
      f.trace.dump();
    }
  }));

  test(M49.expiry, () async {
    final clock = FakeAsync();
    final transport = Transport();
    late Fixture f;
    clock.run((_) {
      io.HttpOverrides.runZoned(() {
        f = Fixture(clock, transport, M49.expiry);
        f.frame([message(A.one)]);
        f.elapse(A.timeout);
        expect(f.cacheState(A.room), A.cacheDirty);
        f.frame([message(A.two)]);
        expect(f.trace.count(K.httpTransport), A.one);
        expect(f.handler.messages.length, A.two);
      }, createHttpClient: (_) => transport);
    });
    await Future<void>.delayed(M49.expiryWait);
    clock.run((_) {
      io.HttpOverrides.runZoned(() {
        transport.fail = false;
        f.frame([message(A.burst)]);
        expect(f.trace.count(K.httpTransport), A.two);
        expect(f.handler.messages.map((message) => message.messageId),
            [A.one, A.two, A.burst]);
        expect(f.cacheState(A.room), A.cacheWarm);
        f.settle();
        f.trace.dump();
      }, createHttpClient: (_) => transport);
    });
  });
}
