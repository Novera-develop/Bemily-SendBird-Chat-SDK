import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/http_client.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/api_client.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/api_request.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_context/chat_context.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/session_manager.dart';

const _transportFailure = 'transport unavailable';
const _transportHost = 'transport.invalid';

void main() {
  for (final error in [const io.SocketException(_transportFailure),
    const FormatException(_transportFailure), TimeoutException(_transportFailure)]) {
    test('W20 API transport classification ${error.runtimeType}', () async {
      await io.HttpOverrides.runZoned(() async {
        final context = ChatContext.test()..apiHost = _transportHost;
        final client = ApiClient(chatContext: context, sessionManager: _Session());
        final result = client.send<dynamic>(_Request(chat: _Chat(context)));
        await expectLater(result, throwsA(error is TimeoutException
            ? isA<NetworkErrorException>()
            : isA<RequestFailedException>().having((failure) => failure.isTransientTransport,
                _transportFailure, error is io.SocketException)));
        client.cleanUp();
      }, createHttpClient: (_) => _Transport(error));
    });
  }
  group('RateLimitExceededException', () {
    test('defaults code to 500910 and keeps http status', () {
      final e = RateLimitExceededException(message: 'Too many requests');
      expect(e.code, SendbirdError.rateLimitExceeded);
      expect(e.httpStatusCode, 429);
      expect(e.retryAfter, isNull);
      expect(e, isA<SendbirdException>());
      expect(e.toString(), contains('RateLimitExceededException'));
    });

    test('keeps server code when provided', () {
      final e = RateLimitExceededException(code: 500910, retryAfter: const Duration(milliseconds: 250));
      expect(e.code, 500910);
      expect(e.retryAfter, const Duration(milliseconds: 250));
    });
  });

  group('HttpClient.parseRateLimitRetryAfter', () {
    test('prefers retry-after header', () {
      expect(
        HttpClient.parseRateLimitRetryAfter({'retry-after': '2', 'x-ratelimit-reset': '59.5'}),
        const Duration(seconds: 2),
      );
    });

    test('falls back to x-ratelimit-reset with fractional seconds', () {
      expect(
        HttpClient.parseRateLimitRetryAfter({'x-ratelimit-reset': '0.25349'}),
        const Duration(milliseconds: 253),
      );
    });

    test('returns null when headers are missing or invalid', () {
      expect(HttpClient.parseRateLimitRetryAfter({}), isNull);
      expect(HttpClient.parseRateLimitRetryAfter({'retry-after': 'soon'}), isNull);
      expect(HttpClient.parseRateLimitRetryAfter({'retry-after': '-1'}), isNull);
    });
  });
}

class _Transport extends Fake implements io.HttpClient {
  _Transport(this.error);
  final Object error;
  @override
  Future<io.HttpClientRequest> openUrl(String method, Uri url) async => throw error;
}

class _Session extends Fake implements SessionManager {}
class _Chat extends Fake implements Chat {
  _Chat(this.chatContext);
  @override
  final ChatContext chatContext;
}
class _Request extends ApiRequest {
  _Request({required super.chat});
}
