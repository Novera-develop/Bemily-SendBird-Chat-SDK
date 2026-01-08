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
  // bool _isAutoResending = false;
  // bool _stopAutoResending = false;
  final Map<int, bool> _isAutoResendingMap = {};
  final Map<int, bool> _stopAutoResendingMap = {};

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

          final failedMessages = await collection.getFailedMessages();

          for (final failedMessage in failedMessages) {
            if (failedMessage.isAutoResendable()) {
              // Resend a message
              Completer completer = Completer();
              SendbirdException? exception;
              if (failedMessage is UserMessage) {
                collection.channel.resendUserMessage(
                  failedMessage,
                  handler: (UserMessage message, SendbirdException? e) {
                    exception = e;
                    completer.complete();
                  },
                );
              } else if (failedMessage is FileMessage) {
                collection.channel.resendFileMessage(
                  failedMessage,
                  handler: (FileMessage message, SendbirdException? e) {
                    exception = e;
                    completer.complete();
                  },
                );
              } else if (failedMessage is MultipleFilesMessage) {
                collection.channel.resendMultipleFilesMessage(
                  failedMessage,
                  handler:
                      (MultipleFilesMessage message, SendbirdException? e) {
                    exception = e;
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
