// Copyright (c) 2024 Sendbird, Inc. All rights reserved.

import 'dart:async';

import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';

class AutoResendManager {
  AutoResendManager._();

  static final AutoResendManager _instance = AutoResendManager._();

  factory AutoResendManager() => _instance;

  static const int _delayForRateLimit = 200; // Check
  final Map<int, bool> _isAutoResendingMap = {};
  final Map<int, bool> _stopAutoResendingMap = {};

  // Stores failed message objects by requestId so that auto-resend can
  // retry them even when useCollectionCaching is false (no DB).
  // The original send handler is called immediately on failure (not saved here).
  // Auto-resend success is signaled via collection events (onMessageSentByMe).
  final Map<String, BaseMessage> _pendingMessageMap = {};

  void registerPendingMessage(String requestId, BaseMessage message) {
    _pendingMessageMap[requestId] = message;
  }

  void startAutoResend(Chat chat) async {
    final chatId = chat.chatId;

    if (!chat.chatContext.options.useAutoResend) {
      sbLog.i(StackTrace.current, 'Returned because of useAutoResend == false');
      return;
    }

    if (_isAutoResendingMap[chatId] == true) {
      sbLog.i(StackTrace.current,
          'Returned because of _isAutoResending == true (chatId: $chatId)');
      return;
    }

    sbLog.i(StackTrace.current, 'Started (chatId: $chatId)');
    _isAutoResendingMap[chatId] = true;
    _stopAutoResendingMap[chatId] = false;

    try {
      for (final collection in chat.collectionManager.baseMessageCollections) {
        if (collection is MessageCollection) {
          if (collection.channel.isFrozen) {
            sbLog.i(StackTrace.current,
                'Skipped because of collection.channel.isFrozen == true');
            continue;
          }

          // Get failed messages from DB (empty when useCollectionCaching is false)
          final dbFailedMessages = await collection.getFailedMessages();
          final dbRequestIds =
              dbFailedMessages.map((m) => m.requestId).toSet();

          // Merge with in-memory messages for channels without DB.
          final inMemoryMessages = _pendingMessageMap.values
              .where((m) =>
                  m.channelUrl == collection.channel.channelUrl &&
                  !dbRequestIds.contains(m.requestId))
              .toList();

          final failedMessages = [...dbFailedMessages, ...inMemoryMessages];

          for (final failedMessage in failedMessages) {
            if (failedMessage.isAutoResendable()) {
              final requestId = failedMessage.requestId ?? '';

              // Resend the message. The original handler was already called
              // when the message first failed, so we don't call it again here.
              // Success is communicated via collection events (onMessageSentByMe).
              Completer completer = Completer();
              SendbirdException? exception;
              if (failedMessage is UserMessage) {
                collection.channel.resendUserMessage(
                  failedMessage,
                  handler: (UserMessage message, SendbirdException? e) {
                    exception = e;
                    if (requestId.isNotEmpty) {
                      _pendingMessageMap.remove(requestId);
                    }
                    completer.complete();
                  },
                );
              } else if (failedMessage is FileMessage) {
                collection.channel.resendFileMessage(
                  failedMessage,
                  handler: (FileMessage message, SendbirdException? e) {
                    exception = e;
                    if (requestId.isNotEmpty) {
                      _pendingMessageMap.remove(requestId);
                    }
                    completer.complete();
                  },
                );
              } else if (failedMessage is MultipleFilesMessage) {
                collection.channel.resendMultipleFilesMessage(
                  failedMessage,
                  handler:
                      (MultipleFilesMessage message, SendbirdException? e) {
                    exception = e;
                    if (requestId.isNotEmpty) {
                      _pendingMessageMap.remove(requestId);
                    }
                    completer.complete();
                  },
                );
              } else {
                // Defensive code
                completer.complete();
              }
              await completer.future;

              if (exception != null) {
                sbLog.i(StackTrace.current,
                    'Stopped because of exception != null (chatId: $chatId)');
                break;
              }

              if (_stopAutoResendingMap[chatId] == true) break;

              // Delay to avoid the rate limit
              await Future.delayed(
                  const Duration(milliseconds: _delayForRateLimit));
            }

            if (_stopAutoResendingMap[chatId] == true) break;
          }
        }

        if (_stopAutoResendingMap[chatId] == true) break;
      }
    } catch (e) {
      sbLog.e(StackTrace.current, e.toString());
    }

    _stopAutoResendingMap[chatId] = false;
    _isAutoResendingMap[chatId] = false;
    sbLog.i(StackTrace.current, 'Stopped (chatId: $chatId)');
  }

  void stopAutoResend(Chat chat) {
    final chatId = chat.chatId;
    if (_isAutoResendingMap[chatId] == true) {
      sbLog.i(StackTrace.current, '(chatId: $chatId)');
      _stopAutoResendingMap[chatId] = true;
    }
  }

  /// Clean up state for a specific chat instance
  void cleanUp(int chatId) {
    _isAutoResendingMap.remove(chatId);
    _stopAutoResendingMap.remove(chatId);
  }
}
