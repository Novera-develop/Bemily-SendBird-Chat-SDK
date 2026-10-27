import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_context/chat_context.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/connection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/session_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/api_client.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/http_client.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/api_request.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _appId = 'session-refresh-hang';
const _userId = 'refresh-user';
const _oldKey = 'old-session-key';
const _newKey = 'new-session-key';
const _accessToken = 'refresh-access-token';
const _apiHost = 'api.invalid';
const _sessionKeyPath = '/session_key';
const _expiredBody = {'error': true, 'code': 400309, 'message': 'expired'};
const _okBody = {'ok': true};
const _httpOk = 200;
const _httpBadRequest = 400;
const _tick = Duration(seconds: 1);
const _settleLimit = Duration(seconds: 120);
const _shortDeadline = Duration(seconds: 3);
const _unreachableDeadline = Duration(hours: 1);
const _innerApiTimeout = Duration(seconds: 10);
const _requesterDelay = Duration(seconds: 5);
const _coalescedRequests = 3;
const _httpServerError = 500;
const _credentialRenotifyCooldown = Duration(seconds: 30);

class _ListRequest extends ApiRequest {
  _ListRequest({required super.chat}) {
    url = 'group_channels';
  }

  @override
  Future response(Map<String, dynamic> res) async => res;
}

class _Outcome {
  bool done = false;
  Object? value;
  Object? error;
}

class _SessionEvents extends SessionHandler {
  int refreshed = 0;
  int errors = 0;
  int closed = 0;
  int tokenRequired = 0;
  AccessTokenRequester? requester;

  @override
  void onAccessTokenRequired(AccessTokenRequester accessTokenRequester) {
    tokenRequired++;
    requester = accessTokenRequester;
  }

  @override
  void onSessionClosed() => closed++;

  @override
  void onSessionRefreshed() => refreshed++;

  @override
  void onSessionError(SendbirdException e) => errors++;
}

class _Harness {
  _Harness(this.handler,
      {Duration reconnectAttemptDeadline = SendbirdChatOptions.defaultReconnectAttemptDeadline}) {
    SharedPreferences.setMockInitialValues({});
    chat = Chat(
      appId: _appId,
      options: SendbirdChatOptions(
        useCollectionCaching: false,
        reconnectAttemptDeadline: reconnectAttemptDeadline,
      ),
    );
    chat.setSessionHandler(events);
    chat.chatContext
      ..currentUser = User(userId: _userId, nickname: _userId)
      ..currentUserId = _userId
      ..sessionKey = _oldKey
      ..accessToken = _accessToken
      ..apiHost = _apiHost;
    chat.apiClient = ApiClient(
      chatContext: chat.chatContext,
      sessionManager: chat.sessionManager,
      client: MockClient(_dispatch),
    );
  }

  final Future<http.Response> Function(http.Request request, int index) handler;
  late final Chat chat;
  final requests = <http.Request>[];
  final events = _SessionEvents();

  Future<http.Response> _dispatch(http.Request request) {
    requests.add(request);
    return handler(request, requests.length - 1);
  }

  int get sessionKeyRequests =>
      requests.where((r) => r.url.path.endsWith(_sessionKeyPath)).length;

  _Outcome send() {
    final outcome = _Outcome();
    chat.apiClient.send<dynamic>(_ListRequest(chat: chat)).then((value) {
      outcome
        ..done = true
        ..value = value;
    }, onError: (Object error) {
      outcome
        ..done = true
        ..error = error;
    });
    return outcome;
  }

  void dispose() {
    chat.connectionManager.cancelReconnectTimers();
    chat.apiClient.cleanUp();
  }
}

http.Response _json(Map<String, dynamic> body, [int status = _httpOk]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

bool _isSessionKey(http.Request request) =>
    request.url.path.endsWith(_sessionKeyPath);

Future<Duration> _settle(WidgetTester tester, _Outcome outcome) async {
  var elapsed = Duration.zero;
  await tester.pump();
  while (!outcome.done && elapsed < _settleLimit) {
    await tester.pump(_tick);
    elapsed += _tick;
  }
  return elapsed;
}

Future<http.Response> _refreshAwareHandler(http.Request request, int index) async {
  if (_isSessionKey(request)) return _json({'key': _newKey});
  return request.headers['Session-Key'] == _newKey
      ? _json(_okBody)
      : _json(_expiredBody, _httpBadRequest);
}

void _expectTerminated(_Outcome outcome) {
  expect(outcome.done, isTrue,
      reason: 'REST request must end in finite time, not wait forever');
}

void registerSessionRefreshHangTests() {
  testWidgets('F1 baseline: expired key refreshes and the request retries',
      (tester) async {
    final harness = _Harness((request, index) async {
      if (_isSessionKey(request)) return _json({'key': _newKey});
      return request.headers['Session-Key'] == _newKey
          ? _json(_okBody)
          : _json(_expiredBody, _httpBadRequest);
    });
    final outcome = harness.send();
    final elapsed = await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(elapsed, Duration.zero,
        reason: 'refresh and retry must finish without any timer or backoff');
    expect(outcome.error, isNull);
    expect(outcome.value, _okBody);
    expect(harness.sessionKeyRequests, 1);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(a) refresh REST 400309 ends without any deadline help',
      (tester) async {
    // Waiter and request deadlines are pushed out of reach, so only the
    // recursion guard can end this request within the settle limit.
    final harness = _Harness(
        (request, index) async => _json(_expiredBody, _httpBadRequest),
        reconnectAttemptDeadline: _unreachableDeadline);
    final outcome = harness.send();
    final elapsed = await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(elapsed, lessThan(_innerApiTimeout));
    expect(outcome.error, isA<SessionKeyRefreshFailedException>());
    expect(harness.sessionKeyRequests, 1);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(b) credentials wait without requester answer hits the waiter deadline',
      (tester) async {
    // No refresh REST is ever sent here, so the recursion guard is irrelevant;
    // the http request deadline (>= 45s) is later than the 3s waiter deadline.
    final harness = _Harness(
        (request, index) async => _json(_expiredBody, _httpBadRequest),
        reconnectAttemptDeadline: _shortDeadline);
    harness.chat.connectionManager.requireAuthentication();
    harness.chat.sessionManager.createAccessTokenRequester();
    final outcome = harness.send();
    final elapsed = await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(elapsed, greaterThanOrEqualTo(_shortDeadline));
    expect(elapsed, lessThan(_shortDeadline + _tick * 2));
    expect(outcome.error, isA<SessionRefreshTimeoutException>());
    expect((outcome.error as SessionRefreshTimeoutException).isTransientTransport,
        isTrue);
    expect((outcome.error as SendbirdException).code, SendbirdError.sessionRefreshTimeout);
    expect(harness.sessionKeyRequests, 0);
    expect(harness.events.errors + harness.events.closed, 0);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(b3) after expiry later calls fail fast, late answer recovers',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler,
        reconnectAttemptDeadline: _shortDeadline);
    harness.chat.connectionManager.requireAuthentication();
    final requester = harness.chat.sessionManager.createAccessTokenRequester();
    final first = harness.send();
    await _settle(tester, first);
    expect(first.error, isA<SessionRefreshTimeoutException>());

    final second = harness.send();
    final elapsed = await _settle(tester, second);
    expect(elapsed, lessThan(_tick * 2));
    expect(second.error, isA<SessionRefreshTimeoutException>());

    await requester.onSuccess(_accessToken);
    await tester.pump(_tick);
    expect(harness.events.refreshed, 1);
    final third = harness.send();
    await _settle(tester, third);
    expect(third.error, isNull);
    expect(third.value, _okBody);
    expect(harness.events.errors + harness.events.closed, 0);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('U5g after the credential wait expires the requester is notified again',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler,
        reconnectAttemptDeadline: _shortDeadline);
    harness.chat.connectionManager.requireAuthentication();
    harness.chat.sessionManager.createAccessTokenRequester();
    final first = harness.send();
    await _settle(tester, first);
    expect(first.error, isA<SessionRefreshTimeoutException>());
    expect(harness.events.tokenRequired, 0);

    final failFast = harness.send();
    await _settle(tester, failFast);
    expect(failFast.error, isA<SessionRefreshTimeoutException>());
    expect(harness.events.tokenRequired, 0);

    await tester.pump(_credentialRenotifyCooldown);
    expect(harness.events.tokenRequired, 1);

    final third = harness.send();
    await tester.pump(_tick);
    expect(third.done, isFalse, reason: 'a renotified wait is not fast-failed');
    await harness.events.requester!.onSuccess(_accessToken);
    await _settle(tester, third);
    expect(third.error, isNull);
    expect(third.value, _okBody);
    expect(harness.events.errors + harness.events.closed, 0);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('U5g expiry in background defers the requester notice to foreground',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler,
        reconnectAttemptDeadline: _shortDeadline);
    harness.chat.connectionManager.requireAuthentication();
    harness.chat.sessionManager.createAccessTokenRequester();
    final first = harness.send();
    await _settle(tester, first);
    expect(first.error, isA<SessionRefreshTimeoutException>());

    harness.chat.isBackground = true;
    await tester.pump(_credentialRenotifyCooldown);
    expect(harness.events.tokenRequired, 0);

    harness.chat.isBackground = false;
    await harness.chat.connectionManager.enterForeground();
    expect(harness.events.tokenRequired, 1);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  for (final entry in {
    'foreground': (ConnectionManager m) => m.enterForeground(),
    'advanceReconnect': (ConnectionManager m) => m.advanceReconnect(),
    'recoverTransport': (ConnectionManager m) => m.recoverTransport(),
  }.entries) {
    testWidgets('U5g ${entry.key} after the credential wait expired notifies again',
        (tester) async {
      final harness = _Harness(_refreshAwareHandler,
          reconnectAttemptDeadline: _shortDeadline);
      harness.chat.connectionManager.requireAuthentication();
      harness.chat.sessionManager.createAccessTokenRequester();
      final first = harness.send();
      await _settle(tester, first);
      expect(first.error, isA<SessionRefreshTimeoutException>());
      expect(harness.events.tokenRequired, 0);

      await entry.value(harness.chat.connectionManager);
      expect(harness.events.tokenRequired, 1);
      await harness.events.requester!.onSuccess(_accessToken);
      final next = harness.send();
      await _settle(tester, next);
      expect(next.error, isNull);
      expect(next.value, _okBody);
      harness.dispose();
      await tester.pump(_settleLimit);
    });
  }

  testWidgets('F1(b4) transport-owned waiter outlives the attempt deadline',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler,
        reconnectAttemptDeadline: _shortDeadline);
    harness.chat.connectionManager.requireAuthentication();
    harness.chat.sessionManager.createAccessTokenRequester();
    final outcome = _Outcome();
    harness.chat.sessionManager
        .updateSessionKey(restartTransport: true)
        .then<void>((_) => outcome.done = true, onError: (Object e) {
      outcome
        ..done = true
        ..error = e;
    });
    await tester.pump(_shortDeadline);
    expect(outcome.done, isFalse,
        reason: 'attempt deadline must fire before the waiter deadline');
    await tester.pump(_tick * 2);
    expect(outcome.error, isA<SessionRefreshTimeoutException>());
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(b2) duplicate requester answers do not leave waiters hanging',
      (tester) async {
    final harness = _Harness((request, index) async {
      if (_isSessionKey(request)) return _json({'key': _newKey});
      return request.headers['Session-Key'] == _newKey
          ? _json(_okBody)
          : _json(_expiredBody, _httpBadRequest);
    });
    final requester = harness.chat.sessionManager.createAccessTokenRequester();
    harness.chat.connectionManager.requireAuthentication();
    final outcome = harness.send();
    await tester.pump();
    await requester.onFail();
    await requester.onFail();
    await _settle(tester, outcome);
    _expectTerminated(outcome);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(c) owner replaced while refresh waits flushes the waiter',
      (tester) async {
    final hang = Completer<http.Response>();
    final harness = _Harness((request, index) {
      if (_isSessionKey(request)) return hang.future;
      return Future.value(_json(_expiredBody, _httpBadRequest));
    });
    final outcome = harness.send();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    harness.chat.connectionManager.replaceSessionOwner();
    await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(outcome.error, isA<SendbirdException>());
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(c2) refresh REST that never answers is bounded',
      (tester) async {
    final hang = Completer<http.Response>();
    final harness = _Harness((request, index) {
      if (_isSessionKey(request)) return hang.future;
      return Future.value(_json(_expiredBody, _httpBadRequest));
    });
    final outcome = harness.send();
    await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(outcome.error, isA<SendbirdException>());
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1(d) http client caps a session refresh that never settles',
      (tester) async {
    final fixture = _FakeSessionFixture(_NeverRefreshSession());
    final outcome = fixture.send();
    await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(outcome.error, isA<NetworkErrorException>());
    fixture.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1 expired request is never resent by a late refresh',
      (tester) async {
    final session = _ManualRefreshSession();
    final fixture = _FakeSessionFixture(session);
    final outcome = fixture.send();
    await _settle(tester, outcome);
    expect(outcome.error, isA<NetworkErrorException>());
    expect(fixture.requests, 1);
    session.release();
    await tester.pump(_tick);
    expect(fixture.requests, 1, reason: 'expired request must not be resent');
    fixture.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1 scenario: foreground LOGI expiry + REST 400309, requester answers',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler);
    harness.chat.connectionManager.requireAuthentication();
    final requester = harness.chat.sessionManager.createAccessTokenRequester();
    final outcome = harness.send();
    await tester.pump(_requesterDelay);
    expect(outcome.done, isFalse);
    await requester.onSuccess(_accessToken);
    await _settle(tester, outcome);
    expect(outcome.error, isNull);
    expect(outcome.value, _okBody);
    expect(harness.sessionKeyRequests, 1);
    expect(harness.events.errors + harness.events.closed, 0);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1 scenario: coalesced concurrent lists all recover',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler);
    harness.chat.connectionManager.requireAuthentication();
    final requester = harness.chat.sessionManager.createAccessTokenRequester();
    final outcomes = List.generate(_coalescedRequests, (_) => harness.send());
    await tester.pump(_requesterDelay);
    await requester.onSuccess(_accessToken);
    for (final outcome in outcomes) {
      await _settle(tester, outcome);
      expect(outcome.error, isNull);
      expect(outcome.value, _okBody);
    }
    expect(harness.sessionKeyRequests, 1);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1 scenario: coalesced lists without answer all end at the deadline',
      (tester) async {
    final harness = _Harness(_refreshAwareHandler,
        reconnectAttemptDeadline: _shortDeadline);
    harness.chat.connectionManager.requireAuthentication();
    harness.chat.sessionManager.createAccessTokenRequester();
    final outcomes = List.generate(_coalescedRequests, (_) => harness.send());
    for (final outcome in outcomes) {
      await _settle(tester, outcome);
      _expectTerminated(outcome);
      expect(outcome.error, isA<SessionRefreshTimeoutException>());
    }
    expect(harness.events.errors + harness.events.closed, 0);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  testWidgets('F1 refresh REST 500 surfaces as refresh failure, no session notice',
      (tester) async {
    final harness = _Harness((request, index) async => _isSessionKey(request)
        ? _json({'error': true, 'code': 500901, 'message': 'x'}, _httpServerError)
        : _json(_expiredBody, _httpBadRequest));
    final outcome = harness.send();
    await _settle(tester, outcome);
    _expectTerminated(outcome);
    expect(outcome.error, isA<SessionKeyRefreshFailedException>());
    expect(harness.events.errors + harness.events.closed, 0);
    harness.dispose();
    await tester.pump(_settleLimit);
  });

  test('F1 request deadline is derived from the reconnect deadline', () {
    final context = ChatContext.test();
    final base = HttpClient(
        chatContext: context, sessionManager: _NeverRefreshSession());
    expect(base.requestDeadline, greaterThanOrEqualTo(HttpClient.minRequestDeadline));
    context.options = SendbirdChatOptions(
        reconnectAttemptDeadline: _unreachableDeadline);
    expect(base.requestDeadline, greaterThan(_unreachableDeadline));
    base.cleanUp();
  });
}

class _FakeSessionFixture {
  _FakeSessionFixture(SessionManager session) {
    final context = ChatContext.test()..apiHost = _apiHost;
    client = ApiClient(
      chatContext: context,
      sessionManager: session,
      client: MockClient((request) async {
        requests++;
        return _json(_expiredBody, _httpBadRequest);
      }),
    );
    chat = _FakeChat(context);
  }

  late final ApiClient client;
  late final _FakeChat chat;
  int requests = 0;

  _Outcome send() {
    final outcome = _Outcome();
    client.send<dynamic>(_ListRequest(chat: chat)).then((value) {
      outcome
        ..done = true
        ..value = value;
    }, onError: (Object error) {
      outcome
        ..done = true
        ..error = error;
    });
    return outcome;
  }

  void dispose() => client.cleanUp();
}

class _ManualRefreshSession extends Fake implements SessionManager {
  final _completer = Completer<void>();

  void release() => _completer.complete();

  @override
  Future<void> updateSessionKey({bool restartTransport = false}) =>
      _completer.future;
}

class _NeverRefreshSession extends Fake implements SessionManager {
  @override
  Future<void> updateSessionKey({bool restartTransport = false}) =>
      Completer<void>().future;
}

class _FakeChat extends Fake implements Chat {
  _FakeChat(this.chatContext);
  @override
  final ChatContext chatContext;
}
