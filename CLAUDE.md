# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Sendbird Chat SDK for Flutter, a real-time chat SDK that enables Flutter applications to integrate messaging features. The SDK supports open channels, group channels, feed channels, and notifications.

**Current version:** 4.7.0
**Minimum requirements:** Dart 2.19.0+, Flutter 3.7.0+
**Platforms:** Android, iOS, Web

## Common Commands

### Package Management
```bash
# Install dependencies
flutter pub get

# Generate code for JSON serialization and Isar database
dart run build_runner build

# Clean and regenerate
dart run build_runner clean
dart run build_runner build --delete-conflicting-outputs
```

### Testing
```bash
# Run all tests
flutter test

# Run a specific test file
flutter test test/path/to/test_file.dart

# Run tests with coverage
flutter test --coverage
```

### Code Quality
```bash
# Analyze code
flutter analyze

# Format code
dart format .
```

### Example App
```bash
# Run the example app
cd example
flutter run
```

## Architecture Overview

### Directory Structure

The codebase is organized into distinct layers:

- **`lib/src/public/`**: Public-facing API that developers interact with
  - `core/`: Core domain models (channels, messages, users)
  - `main/`: Main SDK functionality (chat, collections, handlers, queries)

- **`lib/src/internal/`**: Internal implementation (not exposed to SDK users)
  - `main/chat/`: Core Chat implementation split into feature mixins (auth, connection, channels, etc.)
  - `main/chat_manager/`: Manager classes for different SDK subsystems
  - `main/chat_cache/`: In-memory caching layer
  - `network/`: Network layer (HTTP and WebSocket communication)
  - `db/`: Local persistence using Isar database

### Key Architectural Patterns

#### 1. Public/Internal Separation
The SDK maintains strict separation between public and internal APIs:
- Public classes in `lib/src/public/` are exported via `lib/sendbird_chat_sdk.dart`
- Internal implementations in `lib/src/internal/` should never be directly accessed by SDK users
- The `SendbirdChat` class (public) wraps the internal `Chat` class

#### 2. Chat Core with Mixins
The internal `Chat` class (`lib/src/internal/main/chat/chat.dart`) uses mixins to organize functionality:
- `chat_auth.dart`: Authentication and user management
- `chat_connection.dart`: WebSocket connection lifecycle
- `chat_channel.dart`: Channel operations
- `chat_push.dart`: Push notification management
- `chat_user.dart`: User-related operations
- `chat_emoji.dart`: Emoji support
- `chat_notifications.dart`: Notification features
- `chat_caching.dart`: Caching operations
- `chat_event_handler.dart`: Event handler management

#### 3. Manager Pattern
The SDK uses specialized manager classes to handle different concerns:
- **ConnectionManager**: WebSocket connection state machine
- **CommandManager**: WebSocket command serialization/deserialization
- **EventManager**: Event routing and handler invocation
- **DBManager**: Database operations and local caching
- **SessionManager**: User session management
- **CollectionManager**: Manages GroupChannelCollection and MessageCollection instances
- **DeviceTokenManager**: Push notification token management
- **FileCacheManager**: File caching for media messages

#### 4. State Machine for Connection
Connection states are implemented as separate classes in `lib/src/internal/main/connection_state/`:
- `ConnectedState`
- `ConnectingState`
- `DisconnectedState`
- `ReconnectingState`
- `DelayedConnectingState` (added in v4.7.0)

Each state handles transitions and operations differently.

#### 5. Two-Tier Caching
The SDK implements a dual caching strategy:
- **In-memory cache** (`lib/src/internal/main/chat_cache/`): Fast access for active data
- **Persistent cache** (`lib/src/internal/db/`): Isar-based local storage for offline support

Database schema uses `c_` prefix (e.g., `CGroupChannel`, `CUserMessage`) for cached entities that map to public models.

#### 6. Collection Pattern
Collections provide efficient data management with automatic updates:
- **GroupChannelCollection**: Manages a list of channels with real-time updates
- **MessageCollection**: Manages messages in a channel with pagination and real-time updates
- **NotificationCollection**: Manages notification messages in feed channels

Collections use handlers to notify the app of changes (e.g., `GroupChannelCollectionHandler`, `MessageCollectionHandler`).

#### 7. Network Layer
Dual network communication:
- **HTTP API** (`lib/src/internal/network/http/`): REST API calls for operations like channel creation, user updates
- **WebSocket** (`lib/src/internal/network/websocket/`): Real-time messaging via WebSocket commands

Commands are JSON-serializable objects defined in `lib/src/internal/network/websocket/command/`.

### Important Patterns and Conventions

#### Code Generation
Files ending in `.g.dart` are auto-generated. When modifying annotated classes:
1. Make changes to the source file
2. Run `dart run build_runner build` to regenerate
3. Common annotations: `@JsonSerializable`, `@Collection` (Isar)

#### Message Types
The SDK supports multiple message types (all inherit from `BaseMessage`):
- `UserMessage`: Text messages
- `FileMessage`: Media/file messages
- `AdminMessage`: System messages
- `NotificationMessage`: Push notification messages

#### Channel Types
Three main channel types:
- `OpenChannel`: Public channels anyone can join
- `GroupChannel`: Private channels with members
- `FeedChannel`: One-way notification channels

#### Error Handling
Errors use `SendbirdException` with specific error codes. Connection issues automatically trigger reconnection logic.

#### Event Handlers
The SDK uses a handler registration pattern:
- `ChannelHandler`: For channel events
- `ConnectionHandler`: For connection state changes
- `UserEventHandler`: For user-related events
- `SessionHandler`: For session lifecycle events

Handlers are registered with unique IDs and can be added/removed at runtime.

## Development Notes

### Working with Database Schema
- Database schemas are in `lib/src/internal/db/schema/`
- Cached entities (prefix `C`) are separate from public models
- Use `DBManager` for all database operations
- The database supports offline mode when `useCollectionCaching` option is enabled

### WebSocket Commands
- Commands follow a request/response pattern with `req_id` for correlation
- Command types are defined in `command_type.dart`
- The `CommandManager` handles serialization and routing

### Adding New Features
When adding features that involve both client and server communication:
1. Define HTTP request/response in `lib/src/internal/network/http/http_client/request/`
2. Add WebSocket command if real-time updates are needed
3. Update relevant manager (e.g., `ConnectionManager`, `EventManager`)
4. Expose public API through `SendbirdChat` or channel/message classes
5. Consider caching requirements and update `DBManager` if needed

### Testing Considerations
- No test files currently exist in the repository
- The SDK uses dependency injection through the `Chat` instance and `ChatContext`
- Mock the `Chat` class for unit testing SDK features

### Android 16KB Page Size Support
As of v4.6.0, the SDK supports Android 16KB page sizes. This requires:
- `minSdkVersion` 23 or higher on Android
- Using `isar_community` v3.3.0-dev.3 or later

### Privacy Manifest (iOS)
To support Apple's privacy manifest requirements, add the contents of `ios/Resources/PrivacyInfo.xcprivacy` to your project's `PrivacyInfo.xcprivacy`.

## 멀티 지원하게 해줘

사용자가 "멀티 지원하게 해줘"라고 요청하면, 아래의 완성된 코드로 각 파일을 업데이트합니다.

**Ticket**: FMTW-1726
**Purpose**: Fix connect errors by adding multi-instance support to AutoResendManager and MessageRetentionManager

### 변경 요약

| 파일 | 변경 내용 |
|------|----------|
| `chat.dart` | `globalChatId`, `chatId` 추가 |
| `sendbird_chat.dart` | `SendbirdChat.create()`, 편의 메서드 추가 |
| `auto_resend_manager.dart` | Map 기반 멀티 인스턴스 지원 |
| `message_retention_manager.dart` | appId 기반 config_ts 관리 |
| `chat_auth.dart` | `getConfigTs(appId)` 호출 |
| `collection_manager.dart` | `stopAutoResend(_chat)` 호출 |
| `connection_manager.dart` | `clearConfigTs(appId)`, `cleanUp(chatId)` 호출 |
| `command_manager.dart` | 연결 대기 큐 로직 추가 |
| `base_message.dart` | `pendingHandler` 필드, `isAutoResendable()` 메서드 추가 |
| `base_channel_message.dart` | Auto resend 핸들러 저장 로직 추가 |
| `group_channel_message.dart` | Auto resend 핸들러 저장 로직 추가 |
| `db_manager.dart` | appId 기반 DB 이름, 버전 키 생성 |
| `device_token_manager.dart` | appId 기반 SharedPreferences 키 생성 |
| `session_manager.dart` | appId 기반 SharedPreferences 키 생성 |
| `file_cache_manager.dart` | appId 기반 캐시 폴더 이름 생성 |
| `daily_record_stat_prefs.dart` | appId 기반 키 프리픽스 생성 |
| `default_stat_prefs.dart` | appId 기반 SharedPreferences 키 생성 |

---

### 파일 0: chat.dart (Internal)

**경로**: `lib/src/internal/main/chat/chat.dart`

**수정할 부분 1** - static 변수 추가 (class 내부 상단):

찾기:
```dart
  static const extraDataNotifications = 'notifications';

  final Map<String, String> extensions = {};
```

교체:
```dart
  static const extraDataNotifications = 'notifications';

  static int globalChatId = 0;

  final Map<String, String> extensions = {};
```

**수정할 부분 2** - chatId 필드 추가:

찾기:
```dart
  late FileCacheManager fileCacheManager;

  Chat({
    required String appId,
    required SendbirdChatOptions options,
  })  : lastMarkAsReadTimestamp = 0 {
```

교체:
```dart
  late FileCacheManager fileCacheManager;

  final int chatId;

  Chat({
    required String appId,
    required SendbirdChatOptions options,
  })  : chatId = globalChatId++,
        lastMarkAsReadTimestamp = 0 {
```

---

### 파일 1: auto_resend_manager.dart

**경로**: `lib/src/internal/main/chat_manager/collection_manager/auto_resend_manager.dart`

**전체 파일 교체**:
```dart
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
              // Get pending handler before resend
              final pendingHandler = failedMessage.pendingHandler;

              // Resend a message
              Completer completer = Completer();
              SendbirdException? exception;
              if (failedMessage is UserMessage) {
                collection.channel.resendUserMessage(
                  failedMessage,
                  handler: (UserMessage message, SendbirdException? e) {
                    exception = e;
                    // Call pending handler with result
                    if (pendingHandler != null) {
                      (pendingHandler as UserMessageHandler)(message, e);
                      failedMessage.pendingHandler = null;
                    }
                    completer.complete();
                  },
                );
              } else if (failedMessage is FileMessage) {
                collection.channel.resendFileMessage(
                  failedMessage,
                  handler: (FileMessage message, SendbirdException? e) {
                    exception = e;
                    // Call pending handler with result
                    if (pendingHandler != null) {
                      (pendingHandler as FileMessageHandler)(message, e);
                      failedMessage.pendingHandler = null;
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
                    // Call pending handler with result
                    if (pendingHandler != null) {
                      (pendingHandler as MultipleFilesMessageHandler)(
                          message, e);
                      failedMessage.pendingHandler = null;
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
```

---

### 파일 2: message_retention_manager.dart

**경로**: `lib/src/internal/main/chat_manager/collection_manager/message_retention_manager.dart`

**전체 파일 교체**:
```dart
// Copyright (c) 2025 Sendbird, Inc. All rights reserved.

import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/collection_manager/collection_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';
import 'package:sendbird_chat_sdk/src/internal/main/model/application_settings.dart';
import 'package:sendbird_chat_sdk/src/internal/main/utils/json_converter.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/main/application_settings_get_request.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MessageRetentionManager {
  MessageRetentionManager._();

  static final MessageRetentionManager _instance = MessageRetentionManager._();

  factory MessageRetentionManager() => _instance;

  final String _configTsKeyPrefix = 'com.sendbird.chat.config_ts';

  /// Application settings limit per appId to support multi-instance
  final Map<String, int?> _applicationSettingsLimitMap = {};

  /// Latest pagination count per appId to support multi-instance
  final Map<String, int> _latestPaginationCountMap = {};

  /// Get config_ts key for specific appId to support multi-instance
  String _getConfigTsKey(String appId) {
    return '${_configTsKeyPrefix}_$appId';
  }

  /// Set application settings limit for specific appId
  void setApplicationSettingsLimit(String appId, int? limit) {
    _applicationSettingsLimitMap[appId] = limit;
  }

  /// Get application settings limit for specific appId
  int? getApplicationSettingsLimit(String appId) {
    return _applicationSettingsLimitMap[appId];
  }

  /// Get latest pagination count for specific appId
  int getLatestPaginationCount(String appId) {
    return _latestPaginationCountMap[appId] ?? 0;
  }

  void checkApplicationSettings(Chat chat) async {
    sbLog.i(StackTrace.current, 'Started');

    final appId = chat.chatContext.appId;

    try {
      int? lastConfigTs = await getConfigTs(appId);
      String? token;
      ApplicationSettings settings;

      _latestPaginationCountMap[appId] = 0;

      do {
        if (lastConfigTs != null && token == null) {
          sbLog.d(StackTrace.current,
              '[lastConfigTs] ${DateTime.fromMillisecondsSinceEpoch(lastConfigTs).toString()}');
        }

        settings = await _getApplicationSettings(
          chat,
          ts: token == null ? lastConfigTs : null,
          token: token,
          limit: _applicationSettingsLimitMap[appId],
        );

        _latestPaginationCountMap[appId] =
            (_latestPaginationCountMap[appId] ?? 0) + 1;
        sbLog.d(
            StackTrace.current,
            '\n[paginationCount] ${_latestPaginationCountMap[appId]}'
            '\n[settings] ${jsonEncoder.convert(settings.configs)}'
            '\n[hasMore] ${settings.hasMore}'
            '\n[token]: ${settings.next}'
            '\n[ts]: ${settings.ts}');

        final messagePurgeOffset = settings.configs['message_purge_offset'];
        if (messagePurgeOffset != null) {
          final groupChannels = await chat.dbManager
              .getGroupChannels(query: GroupChannelListQuery());

          for (final groupChannel in groupChannels) {
            int? ts;
            if (groupChannel.customType.isEmpty) {
              ts = messagePurgeOffset['global'];
            } else if (messagePurgeOffset[groupChannel.customType] != null) {
              ts = messagePurgeOffset[groupChannel.customType];
            } else {
              ts = messagePurgeOffset['global'];
            }

            if (ts != null && groupChannel.messageDeletionTimestamp != ts) {
              await syncGroupChannelMessages(
                chat,
                channel: groupChannel,
                messageDeletionTimestamp: ts,
                canNotifyChannelChanged: true,
              );
            }
          }
        }

        token = settings.next;
      } while (settings.hasMore);

      if (settings.ts != null) {
        setConfigTs(chat.chatContext.appId, settings.ts!);
      }
    } catch (e) {
      sbLog.e(StackTrace.current, e.toString());
    }

    sbLog.i(StackTrace.current, 'Ended');
  }

  Future<void> syncGroupChannelMessages(
    Chat chat, {
    required GroupChannel channel,
    required int messageDeletionTimestamp,
    required bool canNotifyChannelChanged,
  }) async {
    // Channel
    if (channel.lastMessage?.createdAt != null &&
        channel.lastMessage!.createdAt <= messageDeletionTimestamp) {
      channel.lastMessage = null;

      if (canNotifyChannelChanged) {
        chat.eventManager.notifyChannelChanged(channel);
      }
    }

    // MessageCollection
    if (!await chat.collectionManager.updateMessageOffset(
      channelUrl: channel.channelUrl,
      messageOffset: messageDeletionTimestamp,
    )) {
      // Delete messages in DB if there is no MessageCollection in memory.
      final messages = await chat.dbManager.getMessages(
        channelType: ChannelType.group,
        channelUrl: channel.channelUrl,
        sendingStatus: SendingStatus.succeeded,
        timestamp: chat.maxInt,
        params: MessageListParams(),
        isPrevious: true,
      );

      if (messages.isNotEmpty) {
        final messagesToDelete = messages.where((message) {
          return message.createdAt <= messageDeletionTimestamp;
        });

        if (messagesToDelete.isNotEmpty) {
          await chat.dbManager.deleteMessages(
            channel,
            messagesToDelete.map((e) => e.getMessageId().toString()).toList(),
          );
        }
      }
    }
  }

  Future<ApplicationSettings> _getApplicationSettings(
    Chat chat, {
    int? ts,
    String? token,
    int? limit,
  }) async {
    sbLog.i(StackTrace.current, 'token: $token');

    final settings = await chat.apiClient
        .send<ApplicationSettings>(ApplicationSettingsGetRequest(
      chat,
      ts: ts,
      token: token,
      limit: limit,
    ));
    return settings;
  }

  Future<bool> setConfigTs(String appId, int configTs) async {
    final prefs = await SharedPreferences.getInstance();
    return await prefs.setInt(_getConfigTsKey(appId), configTs);
  }

  Future<int?> getConfigTs(String appId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_getConfigTsKey(appId));
  }

  Future<void> clearConfigTs(String appId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_getConfigTsKey(appId));
  }
}
```

---

### 파일 3: chat_auth.dart

**경로**: `lib/src/internal/main/chat/chat_auth.dart`

**수정할 부분** (Line 40-41):

찾기:
```dart
int configTs = await MessageRetentionManager().getConfigTs() ?? 0;
```

교체:
```dart
int configTs =
    await MessageRetentionManager().getConfigTs(chatContext.appId) ?? 0;
```

---

### 파일 4: collection_manager.dart

**경로**: `lib/src/internal/main/chat_manager/collection_manager/collection_manager.dart`

**수정할 부분** (onDisconnected 메서드 내):

찾기:
```dart
AutoResendManager().stopAutoResend();
```

교체:
```dart
AutoResendManager().stopAutoResend(_chat);
```

---

### 파일 5: connection_manager.dart

**경로**: `lib/src/internal/main/chat_manager/connection_manager.dart`

**수정 1** - import 추가 (파일 상단):
```dart
import 'collection_manager/auto_resend_manager.dart';
```

**수정 2** - clearConfigTs 호출 부분:

찾기:
```dart
await MessageRetentionManager().clearConfigTs();
```

교체:
```dart
await MessageRetentionManager().clearConfigTs(chat.chatContext.appId);
AutoResendManager().cleanUp(chat.chatId);
```

**수정 3** - getConfigTs 호출 부분:

찾기:
```dart
int configTs = await MessageRetentionManager().getConfigTs() ?? 0;
```

교체:
```dart
int configTs = await MessageRetentionManager().getConfigTs(appId) ?? 0;
```

---

### 파일 6: sendbird_chat.dart

**경로**: `lib/src/public/main/chat/sendbird_chat.dart`

**전체 파일 교체**:
```dart
// Copyright (c) 2023 Sendbird, Inc. All rights reserved.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';

/// An object represents a main class to use Sendbird Chat
class SendbirdChat {
  /// Default push template
  static const String pushTemplateDefault = 'default';

  /// Alternative push template
  static const String pushTemplateAlternative = 'alternative';

  /// Max int value
  int get maxInt => kIsWeb ? 9007199254740991 : double.maxFinite.toInt();

  static SendbirdChat? _defaultInstance;

  late Chat _chat;

  Chat get chat => _chat;

  /// Private constructor
  SendbirdChat._();

  /// Default singleton instance - for backward compatibility
  /// Returns the default instance. Creates it if it doesn't exist.
  factory SendbirdChat() {
    _defaultInstance ??= SendbirdChat._();
    return _defaultInstance!;
  }

  /// Creates a new independent instance for multi-app support
  /// Use this when you need to connect to multiple Sendbird applications simultaneously.
  ///
  /// Example:
  /// ```dart
  /// final sendbird1 = SendbirdChat(); // default instance
  /// await sendbird1.init(appId: 'APP_ID_1');
  ///
  /// final sendbird2 = SendbirdChat.create(); // additional instance
  /// await sendbird2.init(appId: 'APP_ID_2');
  /// ```
  factory SendbirdChat.create() {
    return SendbirdChat._();
  }

  /// Gets the default instance. Throws an error if not initialized.
  static SendbirdChat get instance {
    if (_defaultInstance == null) {
      throw SendbirdException(
        message:
            'SendbirdChat is not initialized. Call SendbirdChat().init() first.',
      );
    }
    return _defaultInstance!;
  }

//------------------------------//
// Chat
//------------------------------//
  /// Initializes SendbirdChat with given app ID.
  Future<bool> init({
    required String appId,
    SendbirdChatOptions? options,
  }) async {
    bool result = true;

    // Chat 객체를 appId와 함께 생성
    _chat = Chat(appId: appId, options: options ?? SendbirdChatOptions());

    _chat.chatContext.init(
      chat: _chat,
      appId: appId,
      options: options ?? SendbirdChatOptions(),
    );

    //+ [DBManager]
    if (_chat.chatContext.options.useCollectionCaching) {
      await _chat.dbManager.init();
    }

    _chat.dbManager.appendLocalCacheStat(
      useLocalCache: _chat.chatContext.options.useCollectionCaching,
    );
    //- [DBManager]
    return result;
  }

  /// Current SDK version.
  String getSdkVersion() {
    sbLog.i(StackTrace.current, 'return: $sdkVersion');
    return _chat.getSdkVersion();
  }

  /// Sets [SendbirdChatOptions].
  void setOptions(SendbirdChatOptions options) {
    sbLog.i(StackTrace.current);
    _chat.setOptions(options);
  }

  /// Returns current [SendbirdChatOptions].
  SendbirdChatOptions getOptions() {
    sbLog.i(StackTrace.current);
    return _chat.getOptions();
  }

  /// Sets app version.
  void setAppVersion(String version) {
    sbLog.i(StackTrace.current, 'version: $version');
    _chat.setAppVersion(version);
  }

  /// Sets log level.
  void setLogLevel(LogLevel level) {
    sbLog.i(StackTrace.current, 'level: $level');
    _chat.setLogLevel(level);
  }

  /// True if SDK has been initialized.
  bool isInitialized() {
    final result = _chat.isInitialized();
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Returns current application id.
  String? getApplicationId() {
    final result = _chat.getApplicationId();
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Returns current application information with [AppInfo].
  AppInfo? getAppInfo() {
    // sbLog.i(StackTrace.current);
    return _chat.getAppInfo();
  }

  /// To send additional User-Agent information please set the version information.
  /// This will be set pre-defined keys only.
  void addExtension(String key, String version) {
    sbLog.i(StackTrace.current, 'key: $key, version: $version');
    _chat.addExtension(key, version);
  }

  Future<Map<String, dynamic>?> getUIKitConfiguration() async {
    if (_chat.extensions[Chat.extensionKeyUiKit] == null) {
      return null;
    }
    return await _chat.getUIKitConfiguration();
  }

//------------------------------//
// Channel
//------------------------------//
  /// Sets the current `User`'s preference for `GroupChannel` join.
  /// If this is set as `true`, the `User` will automatically join the `GroupChannel`.
  /// If set as `false`, the `User` can join the `GroupChannel` by calling
  /// [GroupChannelOperation.acceptInvitation]
  /// or decline the invitation by calling [GroupChannelOperation.declineInvitation].
  Future<void> setChannelInvitationPreference(bool autoAccept) async {
    sbLog.i(StackTrace.current, 'autoAccept: $autoAccept');
    await _chat.setChannelInvitationPreference(autoAccept);
  }

  /// Gets the current `User`'s preference for `GroupChannel` join.
  /// If this is set as `true`, the `User` will automatically join the `GroupChannel`.
  /// If set as `false`, the `User` can join the `GroupChannel` by calling
  /// [GroupChannelOperation.acceptInvitation]
  /// or decline the invitation by calling [GroupChannelOperation.declineInvitation].
  Future<bool> getChannelInvitationPreference() async {
    sbLog.i(StackTrace.current);
    return await _chat.getChannelInvitationPreference();
  }

  /// Requests the channel changelogs from given token.
  Future<GroupChannelChangeLogs> getMyGroupChannelChangeLogs(
    GroupChannelChangeLogsParams params, {
    String? token,
    int? timestamp,
  }) async {
    sbLog.i(StackTrace.current, 'token: $token');
    return _chat.getMyGroupChannelChangeLogs(params,
        token: token, timestamp: timestamp);
  }

  /// Requests the channel changelogs from given token.
  /// @since 4.0.3
  Future<FeedChannelChangeLogs> getMyFeedChannelChangeLogs(
    FeedChannelChangeLogsParams params, {
    String? token,
    int? timestamp,
  }) async {
    sbLog.i(StackTrace.current, 'token: $token');
    return _chat.getMyFeedChannelChangeLogs(params,
        token: token, timestamp: timestamp);
  }

  /// Sends mark as read to all joined `GroupChannel`s.
  /// This method has rate limit. You can send one request per second.
  Future<void> markAsReadAll() async {
    sbLog.i(StackTrace.current);
    await _chat.markAsReadAll();
  }

  /// Sends mark as read to joined `GroupChannel`s.
  /// This method has rate limit. You can send one request per second.
  Future<void> markAsRead({required List<String> channelUrls}) async {
    sbLog.i(StackTrace.current, 'channelUrls: $channelUrls');
    await _chat.markAsRead(channelUrls: channelUrls);
  }

  /// Sends mark as delivered to this channel when you received push message from us.
  /// [data] is the payload data from the push.
  /// Delivery receipt is a premium feature.
  Future<void> markAsDelivered({required Map<String, dynamic> data}) async {
    sbLog.i(StackTrace.current, 'data: $data');
    await _chat.markAsDelivered(data: data);
  }

  /// Gets the number of my `GroupChannel`s.
  Future<int> getGroupChannelCount(MyMemberStateFilter filter) async {
    sbLog.i(StackTrace.current, 'filter: $filter');
    return await _chat.getGroupChannelCount(filter);
  }

  /// Gets the total number of unread `GroupChannel`s the current user has joined.
  Future<int> getTotalUnreadChannelCount(
      [GroupChannelTotalUnreadChannelCountParams? params]) async {
    final result = await _chat.getTotalUnreadChannelCount(params);
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Gets the total number of unread message of `GroupChannel`s with [GroupChannelTotalUnreadMessageCountParams] filter.
  Future<int> getTotalUnreadMessageCount(
      [GroupChannelTotalUnreadMessageCountParams? groupChannelParams]) async {
    final result = await _chat.getTotalUnreadMessageCount(
      groupChannelParams: groupChannelParams,
    );
    sbLog.i(StackTrace.current, 'return: ${result.totalCountForGroupChannels}');
    return result.totalCountForGroupChannels;
  }

  /// Gets the total number of unread message of `GroupChannel`s and `FeedChannel`s
  /// with [GroupChannelTotalUnreadMessageCountParams] filter.
  /// @since 4.0.3
  @Deprecated('Use getTotalUnreadMessageCountWithParams() instead.')
  Future<UnreadMessageCount> getTotalUnreadMessageCountWithFeedChannel(
      [GroupChannelTotalUnreadMessageCountParams? params]) async {
    final result =
        await _chat.getTotalUnreadMessageCount(groupChannelParams: params);
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Gets the total number of unread message of `GroupChannel`s and `FeedChannel`s
  /// with [GroupChannelTotalUnreadMessageCountParams] and [FeedChannelTotalUnreadMessageCountParams] filters.
  /// @since 4.5.0
  Future<UnreadMessageCount> getTotalUnreadMessageCountWithParams({
    GroupChannelTotalUnreadMessageCountParams? groupChannelParams,
    FeedChannelTotalUnreadMessageCountParams? feedChannelParams,
  }) async {
    final result = await _chat.getTotalUnreadMessageCount(
      groupChannelParams: groupChannelParams,
      feedChannelParams: feedChannelParams,
    );
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Gets the unread item count of `GroupChannel`s from keys.
  Future<GroupChannelUnreadItemCount> getUnreadItemCount(
      List<UnreadItemKey> keys) async {
    final result = await _chat.getUnreadItemCount(keys);
    sbLog.i(StackTrace.current, 'keys: $keys, return: $result');
    return result;
  }

  /// Gets the subscribed total number of unread message of all `GroupChannel`s the current user has joined.
  int get getSubscribedTotalUnreadMessageCount {
    final result = _chat.subscribedTotalUnreadMessageCount;
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Gets the total number of unread message of `GroupChannel`s with subscribed custom types.
  int get getSubscribedCustomTypeTotalUnreadMessageCount {
    final result = _chat.subscribedCustomTypeTotalUnreadMessageCount;
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Gets the number of unread message of `GroupChannel` with subscribed custom type.
  int? getSubscribedCustomTypeUnreadMessageCount(String customType) {
    final result = _chat.subscribedCustomTypeUnreadMessageCount(customType);
    sbLog.i(StackTrace.current, 'customType: $customType, return: $result');
    return result;
  }

  /// Gets the number of total scheduled messages.
  Future<int> getTotalScheduledMessageCount({
    TotalScheduledMessageCountParams? params,
  }) async {
    final result = await _chat.getTotalScheduledMessageCount(params: params);
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

//------------------------------//
// Connection
//------------------------------//
  /// Connects to SendbirdChat with given `User` ID and auth token.
  /// If you have created `User`s without [auth token](https://docs.sendbird.com/platform#user_3_create),
  /// refer to [connect] or just pass auth token with `null`.
  Future<User> connect(
    String userId, {
    String? nickname,
    String? accessToken,
    String? apiHost,
    String? wsHost,
  }) async {
    sbLog.i(StackTrace.current, 'userId: $userId');

    return await _chat.connect(
      userId,
      nickname: nickname,
      accessToken: accessToken,
      apiHost: apiHost,
      wsHost: wsHost,
    );
  }

  /// Disconnects from SendbirdChat.
  Future<void> disconnect() async {
    sbLog.i(StackTrace.current, 'userId: ${_chat.chatContext.currentUserId}');
    await _chat.disconnect();
  }

  /// Tries reconnection with previously and successfully connected user information.
  /// This can be called in [ConnectionHandler.onReconnectFailed] or where you check the device network status
  /// to let the SDK try reconnection.
  /// [ConnectionHandler.onReconnectStarted] will be called after you call this
  /// (note that it will not be called if there is previously started connection process which has not finished),
  /// and [ConnectionHandler.onReconnectFailed] or [ConnectionHandler.onReconnectSucceeded] will be
  /// called according to the connection status afterwards.
  /// Usually, the SDK automatically retries connection process when the network connection is lost with some backoff period.
  /// When you call this method, you can start connection process immediately.
  Future<bool> reconnect() async {
    sbLog.i(StackTrace.current);
    return await _chat.reconnect(reset: true);
  }

  /// The last connected timestamp.
  int? getLastConnectedAt() {
    final result = _chat.getLastConnectedAt();
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Gets the SDK socket connection state.
  MyConnectionState getConnectionState() {
    final result = _chat.getConnectionState();
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

//------------------------------//
// Emoji
//------------------------------//
  /// Requests the all emoji.
  Future<EmojiContainer> getAllEmoji() async {
    sbLog.i(StackTrace.current);
    return await _chat.getAllEmoji();
  }

  /// Requests the emoji.
  Future<Emoji> getEmoji(String key) async {
    sbLog.i(StackTrace.current);
    return await _chat.getEmoji(key);
  }

  /// Requests the emoji category.
  Future<EmojiCategory> getEmojiCategory(int categoryId) async {
    sbLog.i(StackTrace.current);
    return await _chat.getEmojiCategory(categoryId);
  }

//------------------------------//
// Event Handler
//------------------------------//
  /// Adds a channel handler. All added handlers will be notified when events occur.
  Future<void> addChannelHandler(
      String identifier, RootChannelHandler handler) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    _chat.addChannelHandler(identifier, handler);
  }

  /// Gets a channel handler.
  Future<BaseChannelHandler?> getChannelHandler(String identifier) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    return _chat.getChannelHandler(identifier);
  }

  /// Removes a channel handler. The deleted handler no longer be notified.
  Future<void> removeChannelHandler(String identifier) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    _chat.removeChannelHandler(identifier);
  }

  /// Removes all channel handlers added by [addChannelHandler].
  Future<void> removeAllChannelHandlers() async {
    sbLog.i(StackTrace.current);
    _chat.removeAllChannelHandlers();
  }

  /// Adds a connection handler. All added handlers will be notified when events occurs.
  Future<void> addConnectionHandler(
      String identifier, ConnectionHandler handler) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    _chat.addConnectionHandler(identifier, handler);
  }

  /// Gets a connection handler.
  Future<ConnectionHandler?> getConnectionHandler(String identifier) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    return _chat.getConnectionHandler(identifier);
  }

  /// Removes a connection handler. The deleted handler no longer be notified.
  Future<void> removeConnectionHandler(String identifier) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    _chat.removeConnectionHandler(identifier);
  }

  /// Removes all connection handlers added by [addConnectionHandler].
  Future<void> removeAllConnectionHandlers() async {
    sbLog.i(StackTrace.current);
    _chat.removeAllConnectionHandlers();
  }

  /// Adds a user event handler. All added handlers will be notified when events occur.
  Future<void> addUserEventHandler(
      String identifier, UserEventHandler handler) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    _chat.addUserEventHandler(identifier, handler);
  }

  /// Gets a user event handler.
  Future<UserEventHandler?> getUserEventHandler(String identifier) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    return _chat.getUserEventHandler(identifier);
  }

  /// Removes a user event handler. The deleted handler no longer be notified.
  Future<void> removeUserEventHandler(String identifier) async {
    sbLog.i(StackTrace.current, 'identifier: $identifier');
    _chat.removeUserEventHandler(identifier);
  }

  /// Removes all user event handlers added by [addUserEventHandler].
  Future<void> removeAllUserEventHandlers() async {
    sbLog.i(StackTrace.current);
    _chat.removeAllUserEventHandlers();
  }

  /// Set a [SessionHandler] which is required for SDK refresh the session when the current session expires.
  /// Must be set before the connection is made by [connect].
  Future<void> setSessionHandler(SessionHandler handler) async {
    sbLog.i(StackTrace.current);
    _chat.setSessionHandler(handler);
  }

  /// Gets a session handler.
  Future<SessionHandler?> getSessionHandler() async {
    sbLog.i(StackTrace.current);
    return _chat.getSessionHandler();
  }

  /// Removes a session handler. The deleted handler no longer be notified.
  Future<void> removeSessionHandler() async {
    sbLog.i(StackTrace.current);
    _chat.removeSessionHandler();
  }

//------------------------------//
// Push
//------------------------------//
  /// Registers push token for the current `User` to receive push notification.
  /// To enable push notification and get a token,
  /// Push token registration succeeds only when the connection ([connect]) is made.
  /// Otherwise, callback will return with [PushTokenRegistrationStatus.pending] status.
  /// Then, you can register push token again by calling [SendbirdChat.registerPushToken] after the connection is done.
  /// This just adds token to the server.
  /// If you want to register this token and delete all the previous ones, refer to [registerPushToken].
  Future<PushTokenRegistrationStatus> registerPushToken({
    required PushTokenType type,
    required String token,
    bool alwaysPush = false,
    bool unique = false,
  }) async {
    sbLog.i(StackTrace.current, 'PushTokenType: $type');
    return await _chat.registerPushToken(
      type: type,
      token: token,
      alwaysPush: alwaysPush,
      unique: unique,
    );
  }

  /// The pending push token. `null` if there is no registration pending token.
  String? getPendingPushToken() {
    sbLog.i(StackTrace.current, 'getPendingPushToken()');
    return _chat.getPendingPushToken();
  }

  /// Unregisters push token for the current `User`.
  Future<void> unregisterPushToken({
    required PushTokenType type,
    required String token,
  }) async {
    sbLog.i(StackTrace.current, 'PushTokenType: $type');
    return await _chat.unregisterPushToken(
      type: type,
      token: token,
    );
  }

  /// Unregisters all push token bound to the current `User`.
  Future<void> unregisterPushTokenAll() async {
    sbLog.i(StackTrace.current);
    return await _chat.unregisterPushTokenAll();
  }

  /// Sets the current `User`'s push trigger option.
  /// If certain channel's push trigger option is set to [GroupChannelPushTriggerOption.defaultValue],
  /// it works according to the state of [PushTriggerOption].
  /// If not, push messages will be triggered according to the state of [GroupChannelPushTriggerOption].
  /// Refer to [GroupChannelPushTriggerOption].
  Future<void> setPushTriggerOption(PushTriggerOption option) async {
    sbLog.i(StackTrace.current, 'option: $option');
    await _chat.setPushTriggerOption(option);
  }

  /// Gets the current `User`'s push trigger option. Refer to [PushTriggerOption].
  /// For details of push trigger option, refer to [setPushTriggerOption].
  Future<PushTriggerOption> getPushTriggerOption() async {
    sbLog.i(StackTrace.current);
    return await _chat.getPushTriggerOption();
  }

  /// Sets the push notification sound file path for the current `User`.
  /// This setting will be delivered on push notification payload.
  Future<void> setPushSound(String sound) async {
    sbLog.i(StackTrace.current, 'sound: $sound');
    return await _chat.setPushSound(sound);
  }

  /// Gets push notification sound path for the current `User`.
  Future<String> getPushSound() async {
    sbLog.i(StackTrace.current);
    return await _chat.getPushSound();
  }

  /// Sets push template option for the current `User`.
  /// The only valid arguments for template name are [SendbirdChat.pushTemplateDefault] and [SendbirdChat.pushTemplateAlternative].
  /// If [SendbirdChat.pushTemplateDefault] is set,
  /// the push notification will contain the original message in the `message` field of the push notification.
  /// If [SendbirdChat.pushTemplateAlternative] is set,
  /// `message` of push notification will be replaced by the content you've set on
  /// [Sendbird Dashboard](https://dashboard.sendbird.com).
  Future<void> setPushTemplate(String name) async {
    sbLog.i(StackTrace.current, 'name: $name');
    return await _chat.setPushTemplate(name);
  }

  /// Gets push template option for the current `User`.
  /// For details of push template option, refer to [setPushTemplate].
  /// This can be used, for instance,
  /// when you need to check the push notification content preview is on or off at the moment.
  Future<String> getPushTemplate() async {
    sbLog.i(StackTrace.current);
    return await _chat.getPushTemplate();
  }

//------------------------------//
// User
//------------------------------//
  /// The current connected [User]. `null` if [connect] is not called.
  User? get currentUser {
    return _chat.currentUser;
  }

  /// Updates current `User`'s information.
  Future<void> updateCurrentUserInfo({
    String? nickname,
    FileInfo? profileFileInfo,
    List<String>? preferredLanguages,
    ProgressHandler? progressHandler,
  }) async {
    sbLog.i(StackTrace.current, 'nickname: $nickname');
    await _chat.updateCurrentUserInfo(
      nickname: nickname,
      profileFileInfo: profileFileInfo,
      preferredLanguages: preferredLanguages,
      progressHandler: progressHandler,
    );
  }

  /// Blocks the specified `User` ID.
  /// Blocked `User` cannot send messages to the blocker.
  Future<User> blockUser(String userId) async {
    sbLog.i(StackTrace.current, 'userId: $userId');
    return await _chat.blockUser(userId);
  }

  /// Unblocks the specified `User` ID.
  /// Unblocked `User` cannot send messages to the ex-blocker.
  Future<void> unblockUser(String userId) async {
    sbLog.i(StackTrace.current, 'userId: $userId');
    await _chat.unblockUser(userId);
  }

  /// Sets Do-not-disturb option for the current `User`.
  /// If this option is enabled,
  /// the current `User` does not receive push notification during the specified time repeatedly.
  /// If you want to snooze specific period, use [setSnoozePeriod].
  Future<void> setDoNotDisturb({
    required bool enable,
    int startHour = 0,
    int startMin = 0,
    int endHour = 23,
    int endMin = 59,
    String timezone = 'UTC',
  }) async {
    sbLog.i(StackTrace.current, 'enable: $enable');
    return await _chat.setDoNotDisturb(
      enable: enable,
      startHour: startHour,
      startMin: startMin,
      endHour: endHour,
      endMin: endMin,
      timezone: timezone,
    );
  }

  /// Gets Do-not-disturb option for the current `User`.
  Future<DoNotDisturb> getDoNotDisturb() async {
    sbLog.i(StackTrace.current);
    return await _chat.getDoNotDisturb();
  }

  /// Sets snooze period for the current `User`.
  /// If this option is enabled,
  /// the current `User` does not receive push notification during the given period.
  /// It's not a repetitive operation.
  /// If you want to snooze repeatedly, use [setDoNotDisturb].
  Future<void> setSnoozePeriod({
    required bool enable,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    sbLog.i(StackTrace.current, 'enable: $enable');
    return await _chat.setSnoozePeriod(
      enable: enable,
      startDate: startDate,
      endDate: endDate,
    );
  }

  /// Gets snooze period for the current `User`.
  Future<SnoozePeriod> getSnoozePeriod() async {
    sbLog.i(StackTrace.current);
    return await _chat.getSnoozePeriod();
  }

//------------------------------//
// Notifications
//------------------------------//
  /// Retrieves Global Notification channel theme.
  /// @since 4.0.3
  Future<GlobalNotificationChannelSetting>
      getGlobalNotificationChannelSetting() async {
    sbLog.i(StackTrace.current);
    return await _chat.getGlobalNotificationChannelSetting();
  }

  /// Retrieves Notification template list by token.
  /// [token] is the value to retrieve notification template list from.
  /// @since 4.0.3
  Future<NotificationTemplateList> getNotificationTemplateListByToken(
    NotificationTemplateListParams params, {
    String? token,
  }) async {
    sbLog.i(StackTrace.current);
    return await _chat.getNotificationTemplateListByToken(params, token: token);
  }

  /// Retrieves Notification template.
  /// [key] is the template key.
  /// @since 4.0.3
  Future<NotificationTemplate> getNotificationTemplate({
    required String key,
  }) async {
    sbLog.i(StackTrace.current);
    return await _chat.getNotificationTemplate(key: key);
  }

  /// Authenticate with the Sendbird server.
  /// Calling this method will grant you access to Sendbird notification's features.
  /// If you want to access Sendbird Chat's features, call [SendbirdChat.connect].
  /// You can deauthenticate from the Sendbird server by calling [SendbirdChat.disconnect].
  /// @since 4.0.6
  Future<User> authenticateFeed(
    String userId, {
    String? accessToken,
    String? apiHost,
  }) async {
    sbLog.i(StackTrace.current, 'userId: $userId');

    return await _chat.authenticateFeed(
      userId,
      accessToken: accessToken,
      apiHost: apiHost,
    );
  }

  /// Refresh the contents of all notification collections that are currently valid.
  /// @since 4.0.6
  void refreshNotificationCollections() {
    sbLog.i(StackTrace.current);

    _chat.refreshNotificationCollections();
  }

//------------------------------//
// useCollectionCaching
//------------------------------//
  /// Gets cached data size. (Bytes)
  /// Refer to [SendbirdChatOptions.useCollectionCaching].
  /// @since 4.2.0
  Future<int?> getCachedDataSize() async {
    return await _chat.getCachedDataSize();
  }

  /// Clears all cached data.
  /// Refer to [SendbirdChatOptions.useCollectionCaching].
  /// @since 4.2.0
  Future<void> clearCachedData() async {
    await _chat.clearCachedData();
  }

  /// Clears cached messages regarding [channelUrl].
  /// Refer to [SendbirdChatOptions.useCollectionCaching].
  /// @since 4.2.0
  Future<void> clearCachedMessages(String channelUrl) async {
    await _chat.clearCachedMessages(channelUrl);
  }

//------------------------------//
// Convenience methods for multi-instance support
//------------------------------//
  /// Gets a GroupChannel with the given URL using this instance.
  /// This is a convenience method that automatically passes this instance's chat.
  Future<GroupChannel> getGroupChannel(String channelUrl) async {
    return await GroupChannel.getChannel(channelUrl, chat: _chat);
  }

  /// Gets an OpenChannel with the given URL using this instance.
  /// This is a convenience method that automatically passes this instance's chat.
  Future<OpenChannel> getOpenChannel(String channelUrl) async {
    return await OpenChannel.getChannel(channelUrl, chat: _chat);
  }

  /// Gets a FeedChannel with the given URL using this instance.
  /// This is a convenience method that automatically passes this instance's chat.
  /// @since 4.0.3
  Future<FeedChannel> getFeedChannel(String channelUrl) async {
    return await FeedChannel.getChannel(channelUrl, chat: _chat);
  }

  /// Creates a GroupChannel using this instance.
  /// This is a convenience method that automatically passes this instance's chat.
  Future<GroupChannel> createGroupChannel(
    GroupChannelCreateParams params,
  ) async {
    return await GroupChannel.createChannel(params, chat: _chat);
  }

  /// Creates an OpenChannel using this instance.
  /// This is a convenience method that automatically passes this instance's chat.
  Future<OpenChannel> createOpenChannel(
    OpenChannelCreateParams params, {
    ProgressHandler? progressHandler,
  }) async {
    return await OpenChannel.createChannel(
      params,
      progressHandler: progressHandler,
      chat: _chat,
    );
  }
}
```

---

### 파일 7: command_manager.dart

**경로**: `lib/src/internal/main/chat_manager/command_manager.dart`

**수정 1** - 클래스 필드 추가 (기존 필드들 뒤에):

찾기:
```dart
  final Map<String, int> _dedupIdMap = {};

  int? logiTs;
```

교체:
```dart
  final Map<String, int> _dedupIdMap = {};

  // Queue for ensuring message order during connection wait
  final List<Completer<void>> _connectionWaitQueue = [];
  bool _isProcessingConnectionWait = false;

  int? logiTs;
```

**수정 2** - `_waitForConnectionWithQueue` 메서드 추가 (`getDedupIdListCount` 메서드 뒤에):

찾기:
```dart
  int getDedupIdListCount() {
    return _dedupIdMap.length;
  }

  Future<Command?> sendCommand(Command cmd) async {
```

교체:
```dart
  int getDedupIdListCount() {
    return _dedupIdMap.length;
  }

  /// Waits for connection with queue to ensure message order
  Future<void> _waitForConnectionWithQueue() async {
    // Add to queue and wait for turn
    final myCompleter = Completer<void>();
    _connectionWaitQueue.add(myCompleter);
    final queuePosition = _connectionWaitQueue.length;
    sbLog.i(StackTrace.current,
        'Added to connection wait queue (position: $queuePosition)');

    // If another message is already processing connection wait, wait for our turn
    if (_isProcessingConnectionWait) {
      sbLog.i(StackTrace.current, 'Waiting for turn in queue...');
      await myCompleter.future;
      return;
    }

    // We are first in queue, process connection wait
    _isProcessingConnectionWait = true;

    try {
      await _doWaitForConnection();

      // Connection successful, release all waiting messages in order
      sbLog.i(StackTrace.current,
          'Connection established, releasing ${_connectionWaitQueue.length} queued messages');
      while (_connectionWaitQueue.isNotEmpty) {
        final completer = _connectionWaitQueue.removeAt(0);
        if (!completer.isCompleted) {
          completer.complete();
        }
        // Small delay to ensure order is maintained
        await Future.delayed(const Duration(milliseconds: 1));
      }
    } catch (e) {
      // Connection failed, fail all waiting messages
      sbLog.e(StackTrace.current,
          'Connection failed, failing ${_connectionWaitQueue.length} queued messages');
      while (_connectionWaitQueue.isNotEmpty) {
        final completer = _connectionWaitQueue.removeAt(0);
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
      rethrow;
    } finally {
      _isProcessingConnectionWait = false;
    }
  }

  /// Internal method to wait for connection with retry logic
  Future<void> _doWaitForConnection() async {
    const maxRetryCount = 5;
    var retryCount = 0;

    while (!_chat.connectionManager.isConnected() ||
        !_chat.connectionManager.webSocketClient.isConnected()) {
      sbLog.i(StackTrace.current,
          'WebSocket not connected (retry: $retryCount). isConnected: ${_chat.connectionManager.isConnected()}, wsConnected: ${_chat.connectionManager.webSocketClient.isConnected()}, isDisconnected: ${_chat.connectionManager.isDisconnected()}, isReconnecting: ${_chat.connectionManager.isReconnecting()}');

      // Try to reconnect if:
      // 1. Disconnected state, OR
      // 2. WebSocket is not connected (even if state is Reconnecting, WS might have failed)
      final shouldReconnect = _chat.connectionManager.isDisconnected() ||
          (!_chat.connectionManager.webSocketClient.isConnected() &&
              !_chat.connectionManager.isConnecting());

      if (shouldReconnect) {
        sbLog.i(StackTrace.current, 'Attempting auto reconnect...');
        final reconnectStarted =
            await _chat.connectionManager.reconnect(reset: true);
        if (!reconnectStarted) {
          sbLog.e(StackTrace.current, 'Failed to start reconnect');
          throw ConnectionRequiredException();
        }
      }

      // Wait for connect/reconnect to complete
      if ((_chat.connectionManager.isReconnecting() ||
              _chat.connectionManager.isConnecting()) &&
          _chat.chatContext.loginCompleter != null &&
          !_chat.chatContext.loginCompleter!.isCompleted) {
        sbLog.i(StackTrace.current, 'Waiting for connection to complete...');
        try {
          await _chat.chatContext.loginCompleter!.future.timeout(
            Duration(seconds: _chat.chatContext.options.connectionTimeout),
            onTimeout: () {
              throw ConnectionRequiredException();
            },
          );
          sbLog.i(
              StackTrace.current, 'Reconnect completed, proceeding with send');
        } catch (e) {
          sbLog.e(StackTrace.current, 'Reconnect failed: $e');
          throw ConnectionRequiredException();
        }
      }

      // WebSocket is connected but state is not ConnectedState yet (waiting for LOGI)
      // Wait with polling until connected or timeout
      if (!_chat.connectionManager.isConnected() &&
          _chat.connectionManager.webSocketClient.isConnected()) {
        sbLog.i(StackTrace.current,
            'WebSocket connected but waiting for LOGI, polling...');
        const maxWaitMs = 5000;
        const pollIntervalMs = 100;
        var waitedMs = 0;
        while (!_chat.connectionManager.isConnected() &&
            _chat.connectionManager.webSocketClient.isConnected() &&
            waitedMs < maxWaitMs) {
          await Future.delayed(const Duration(milliseconds: pollIntervalMs));
          waitedMs += pollIntervalMs;
        }

        if (_chat.connectionManager.isConnected()) {
          sbLog.i(StackTrace.current,
              'Connection state updated to connected after ${waitedMs}ms');
        }

        // 타임아웃 후에도 상태 불일치가 지속되면 재연결
        if (!_chat.connectionManager.isConnected() &&
            _chat.connectionManager.webSocketClient.isConnected()) {
          sbLog.w(StackTrace.current,
              'State mismatch persisted after ${waitedMs}ms, forcing reconnect...');
          try {
            await _chat.connectionManager.webSocketClient.close(
              reason: 'State mismatch timeout',
            );
          } catch (e) {
            sbLog.e(StackTrace.current, 'WebSocket disconnect failed: $e');
          }
          // 다음 iteration에서 reconnect 로직 처리
        }
      }

      // Check if connected now
      if (_chat.connectionManager.isConnected() &&
          _chat.connectionManager.webSocketClient.isConnected()) {
        break;
      }

      // Retry if not connected
      retryCount++;
      if (retryCount >= maxRetryCount) {
        sbLog.e(StackTrace.current,
            'Still not connected after $retryCount retries. isConnected: ${_chat.connectionManager.isConnected()}, wsConnected: ${_chat.connectionManager.webSocketClient.isConnected()}');
        throw ConnectionRequiredException();
      }

      sbLog.i(StackTrace.current,
          'Connection lost during wait, retrying... ($retryCount/$maxRetryCount)');
    }
  }

  Future<Command?> sendCommand(Command cmd) async {
```

**수정 3** - `sendCommand` 메서드 시작 부분에 연결 체크 추가:

찾기:
```dart
  Future<Command?> sendCommand(Command cmd) async {
    if (_chat.chatContext.currentUser == null) {
      // NOTE: some test cases execute async socket data
      throw ConnectionRequiredException();
    }

    sbLog.d(
```

교체:
```dart
  Future<Command?> sendCommand(Command cmd) async {
    if (_chat.chatContext.currentUser == null) {
      // NOTE: some test cases execute async socket data
      throw ConnectionRequiredException();
    }

    // Check if WebSocket is actually connected, wait for reconnect if needed
    if (!_chat.connectionManager.isConnected() ||
        !_chat.connectionManager.webSocketClient.isConnected()) {
      await _waitForConnectionWithQueue();
    }

    sbLog.d(
```

---

### 파일 8: base_message.dart

**경로**: `lib/src/public/core/message/base_message.dart`

**수정 1** - `pendingHandler` 필드 추가 (errorCode 필드 뒤에):

찾기:
```dart
  /// The error code of them message if the [sendingStatus] is [SendingStatus.failed].
  int? errorCode;

  /// Whether the message was sent from an operator.
```

교체:
```dart
  /// The error code of them message if the [sendingStatus] is [SendingStatus.failed].
  int? errorCode;

  /// The pending handler for auto resend.
  /// This handler will be called after auto resend attempt.
  @JsonKey(includeFromJson: false, includeToJson: false)
  Function? pendingHandler;

  /// Whether the message was sent from an operator.
```

**수정 2** - `isAutoResendable()` 메서드 추가 (`isResendable()` 메서드 뒤에):

찾기:
```dart
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  /// Returns [MessageMetaArray] list which is filtered by given metaArrayKeys.
```

교체:
```dart
    sbLog.i(StackTrace.current, 'return: $result');
    return result;
  }

  bool isAutoResendable() {
    // if (this is MultipleFilesMessage) { // Check
    //   return false;
    // }

    if (errorCode == SendbirdError.connectionRequired ||
        errorCode == SendbirdError.webSocketConnectionClosed ||
        errorCode == SendbirdError.webSocketConnectionFailed ||
        errorCode == SendbirdError.requestFailed || // Check
        errorCode == SendbirdError.ackTimeout ||
        errorCode == SendbirdError.socketChannelFrozen) {
      return true;
    }
    return false;
  }

  /// Returns [MessageMetaArray] list which is filtered by given metaArrayKeys.
```

---

### 파일 9: base_channel_message.dart

**경로**: `lib/src/public/core/channel/base_channel/base_channel_message.dart`

**수정 1** - `sendUserMessage` 에러 핸들러 수정:

찾기:
```dart
        if (handler != null) {
          handler(pendingUserMessage, e);
        }
      }
    });

    return pendingUserMessage;
  }

  /// Resends a failed user message.
```

교체:
```dart
        if (handler != null) {
          // If auto resendable, save handler and don't call it now
          // Handler will be called after auto resend attempt
          if (chat.chatContext.options.useAutoResend &&
              pendingUserMessage.isAutoResendable()) {
            pendingUserMessage.pendingHandler = handler;
          } else {
            handler(pendingUserMessage, e);
          }
        }
      }
    });

    return pendingUserMessage;
  }

  /// Resends a failed user message.
```

**수정 2** - `sendFileMessage` 에러 핸들러 수정:

찾기:
```dart
        if (handler != null) {
          handler(pendingFileMessage, e);
        }
      }
    });

    return pendingFileMessage;
  }

  /// Cancels an ongoing `FileMessage` upload.
```

교체:
```dart
        if (handler != null) {
          // If auto resendable, save handler and don't call it now
          // Handler will be called after auto resend attempt
          if (chat.chatContext.options.useAutoResend &&
              pendingFileMessage.isAutoResendable()) {
            pendingFileMessage.pendingHandler = handler;
          } else {
            handler(pendingFileMessage, e);
          }
        }
      }
    });

    return pendingFileMessage;
  }

  /// Cancels an ongoing `FileMessage` upload.
```

---

### 파일 10: group_channel_message.dart

**경로**: `lib/src/public/core/channel/group_channel/group_channel_message.dart`

**수정** - `sendMultipleFilesMessage` 에러 핸들러 수정:

찾기:
```dart
        if (handler != null) {
          handler(pendingFileMessage, e);
        }
      }
    });

    return pendingFileMessage;
  }

  /// Resends multiple files with given file information.
```

교체:
```dart
        if (handler != null) {
          // If auto resendable, save handler and don't call it now
          // Handler will be called after auto resend attempt
          if (chat.chatContext.options.useAutoResend &&
              pendingFileMessage.isAutoResendable()) {
            pendingFileMessage.pendingHandler = handler;
          } else {
            handler(pendingFileMessage, e);
          }
        }
      }
    });

    return pendingFileMessage;
  }

  /// Resends multiple files with given file information.
```

---

### 파일 11: db_manager.dart (확인용)

**경로**: `lib/src/internal/main/chat_manager/db_manager.dart`

**확인할 부분** - 생성자에서 appId 기반 DB 이름, 버전 키 생성:

```dart
class DBManager {
  final int _dbVersion = 2;
  late final String _dbName;
  final int _maxDBFileSize = 256; // MB
  late final String _dbVersionKey;

  // ... 생략 ...

  DBManager({required Chat chat}) : _chat = chat {
    // Use appId to support multi-instance
    final appId = chat.chatContext.appId;
    _dbName = 'sendbird_chat_$appId';
    _dbVersionKey = 'com.sendbird.chat.db_version_$appId';
  }
```

---

### 파일 12: device_token_manager.dart (확인용)

**경로**: `lib/src/internal/main/chat_manager/device_token_manager.dart`

**확인할 부분** - 생성자에서 appId 기반 SharedPreferences 키 생성:

```dart
class DeviceTokenManager {
  late final String prefDeviceTokenList;
  late final String prefDeviceTokenLastDeletedAt;

  final String _appId;

  DeviceTokenManager({required String appId}) : _appId = appId {
    // Use appId to support multi-instance
    prefDeviceTokenList = 'com.sendbird.chat.device_token_list_$appId';
    prefDeviceTokenLastDeletedAt =
        'com.sendbird.chat.device_token_last_deleted_at_$appId';
  }
```

---

### 파일 13: session_manager.dart (확인용)

**경로**: `lib/src/internal/main/chat_manager/session_manager.dart`

**확인할 부분** - 생성자에서 appId 기반 SharedPreferences 키 생성:

```dart
class SessionManager {
  late String _userIdKeyPath;
  late String _sessionKeyPath;

  // ... 생략 ...

  SessionManager({required Chat chat}) : _chat = chat {
    // Use appId to support multi-instance
    final appId = chat.chatContext.appId;
    _userIdKeyPath = 'com.sendbird.chat.user_id_$appId';
    _sessionKeyPath = 'com.sendbird.chat.session_key_$appId';
    accessTokenRequester = _AccessTokenRequesterImpl(sessionManager: this);
  }
```

---

### 파일 14: file_cache_manager.dart (확인용)

**경로**: `lib/src/internal/main/chat_manager/file_cache_manager.dart`

**확인할 부분** - `_getFolderName()`에서 appId 기반 캐시 폴더 이름 생성:

```dart
class FileCacheManager {
  static const String _folderNamePrefix = 'sendbird_chat_file_cache';

  final Chat _chat;
  int retentionMinutes = 3 * 24 * 60; // 3 days

  FileCacheManager({required Chat chat}) : _chat = chat;

  // ... 생략 ...

  /// Get folder name with appId to support multi-instance
  String _getFolderName() {
    return '${_folderNamePrefix}_${_chat.chatContext.appId}';
  }
```

---

### 파일 15: daily_record_stat_prefs.dart (확인용)

**경로**: `lib/src/internal/main/stats/daily_record_stat_prefs.dart`

**확인할 부분** - 생성자에서 appId 기반 키 프리픽스 생성:

```dart
class DailyRecordStatPrefs {
  final deleted = 'deleted';
  late final String _keyPrefix;

  final String _appId;

  DailyRecordStatPrefs({required String appId}) : _appId = appId {
    // Use appId to support multi-instance
    _keyPrefix = '${DailyRecordStat.keyPrefix}_$appId';
  }

  // ... 생략 ...

  /// Get key with appId prefix for multi-instance support
  String _getKey(DailyRecordStat stat) {
    return '${_appId}_${stat.key}';
  }
```

---

### 파일 16: default_stat_prefs.dart (확인용)

**경로**: `lib/src/internal/main/stats/default_stat_prefs.dart`

**확인할 부분** - 생성자에서 appId 기반 SharedPreferences 키 생성:

```dart
class DefaultStatPrefs {
  late final String prefDefaultStats;
  late final String prefDefaultStatsCount;
  late final String prefDefaultStatsLastSentAt;
  late final String prefDefaultStatsDeviceId;

  final String _appId;

  DefaultStatPrefs({required String appId}) : _appId = appId {
    // Use appId to support multi-instance
    prefDefaultStats = 'com.sendbird.chat.default_stats_$appId';
    prefDefaultStatsCount = 'com.sendbird.chat.default_stats_count_$appId';
    prefDefaultStatsLastSentAt =
        'com.sendbird.chat.default_stats_last_sent_at_$appId';
    prefDefaultStatsDeviceId =
        'com.sendbird.chat.default_stats_device_id_$appId';
  }
```
