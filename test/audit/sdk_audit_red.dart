import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';

import 'sdk_audit_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeAudit);
  for (final state in [A.cacheAbsent, A.cacheDirty]) {
    for (final contract in [A.redCap, A.redCallbacks, A.redRecovery]) {
      test('${A.t00} $state $contract', () => audit('${A.t00}/$state/$contract', (f) {
        if (state == A.cacheDirty) f.cache(A.room, dirty: true);
        f.frame([for (var i = A.one; i <= A.burst; i++) message(i)]);
        f.elapse(A.timeout);
        f.elapse(A.local);
        // M49 completion: one transport attempt per failed lookup window.
        if (contract == A.redCap) {
          expect(f.trace.count(K.httpTransport), lessThanOrEqualTo(A.one));
          expect(f.handler.messages.length, A.burst);
        // M49/M16 completion: all six callbacks within one timeout plus local work.
        } else if (contract == A.redCallbacks) {
          expect(f.handler.messages.map((m) => m.messageId).toSet().length, A.burst);
          expect(f.trace.of(K.callback).last.time, lessThanOrEqualTo(A.timeout + A.local));
          expect(f.trace.count(K.httpTransport), lessThanOrEqualTo(A.one));
        } else {
          // M49 completion: fallback progress and one fresh refresh after recovery.
          final callbacksAtDeadline = f.handler.messages.length;
          for (var i = A.one; i < A.burst; i++) { f.elapse(A.timeout); }
          f.transport.fail = false;
          final before = f.trace.count(K.httpTransport);
          GroupChannel? recovered;
          GroupChannel.refresh(A.room, chat: f.chat).then((value) => recovered = value);
          f.clock.flushMicrotasks();
          expect(f.trace.count(K.httpTransport) - before, A.one);
          expect(recovered, isNotNull);
          expect(recovered!.fromCache, isFalse);
          expect(f.cacheState(A.room), A.cacheWarm);
          expect(callbacksAtDeadline, A.burst);
        }
        expect(f.isar.messages.keys, containsAll([for (var i = A.one; i <= A.burst; i++) i]));
        f.settle();
      }));
    }
  }
  // M14 completion: each concurrent received message must survive SDK persistence.
  test('${A.t00} ${A.preserved}', () => audit('${A.t00}/${A.preserved}', (f) {
    for (var i = A.one; i <= A.burst; i++) { f.frame([message(i)]); }
    f.elapse(A.timeout);
    expect(f.trace.count(K.httpTransport), A.one);
    expect(f.handler.messages.map((m) => m.messageId).toSet().length, A.burst);
    expect(f.isar.messages.keys, containsAll([for (var i = A.one; i <= A.burst; i++) i]));
    f.settle();
  }));
}
