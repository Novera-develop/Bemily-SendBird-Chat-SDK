import 'package:flutter_test/flutter_test.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/http_client.dart';

void main() {
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
