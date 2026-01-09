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

## 멀티 지원하게 해줘 < 라고 요청하면 해당 Commit에 적용되어있는 변경점에 대해 자동 적용
## Pending Code Changes

### 멀티 지원 (Multi-Instance Support)
**Commit**: a5488c5
**Ticket**: FMTW-1726
**Purpose**: Fix connect errors by adding multi-instance support to AutoResendManager and MessageRetentionManager

#### Changes Required:

**1. lib/src/internal/main/chat/chat_auth.dart**
```dart
// Line 40: Update getConfigTs call to include appId
// OLD:
int configTs = await MessageRetentionManager().getConfigTs() ?? 0;

// NEW:
int configTs =
    await MessageRetentionManager().getConfigTs(chatContext.appId) ?? 0;
```

**2. lib/src/internal/main/chat_manager/collection_manager/auto_resend_manager.dart**
```dart
// Add multi-instance support using Maps instead of single bool flags

// Class fields - REPLACE:
// bool _isAutoResending = false;
// bool _stopAutoResending = false;
// WITH:
final Map<int, bool> _isAutoResendingMap = {};
final Map<int, bool> _stopAutoResendingMap = {};

// startAutoResend method - ADD at beginning:
final chatId = chat.chatId;

// Update all _isAutoResending checks - REPLACE:
// if (_isAutoResending)
// WITH:
if (_isAutoResendingMap[chatId] == true)

// Update all _stopAutoResending checks - REPLACE:
// if (_stopAutoResending)
// WITH:
if (_stopAutoResendingMap[chatId] == true)

// Update flag settings - REPLACE:
// _isAutoResending = true;
// _stopAutoResending = false;
// WITH:
_isAutoResendingMap[chatId] = true;
_stopAutoResendingMap[chatId] = false;

// At end of startAutoResend - REPLACE:
// _stopAutoResending = false;
// _isAutoResending = false;
// WITH:
_stopAutoResendingMap[chatId] = false;
_isAutoResendingMap[chatId] = false;

// Update stopAutoResend signature and implementation:
// OLD:
void stopAutoResend() {
  if (_isAutoResending) {
    sbLog.i(StackTrace.current);
    _stopAutoResending = true;
  }
}

// NEW:
void stopAutoResend(Chat chat) {
  final chatId = chat.chatId;
  if (_isAutoResendingMap[chatId] == true) {
    sbLog.i(StackTrace.current, '(chatId: $chatId)');
    _stopAutoResendingMap[chatId] = true;
  }
}

// ADD new cleanUp method:
/// Clean up state for a specific chat instance
void cleanUp(int chatId) {
  _isAutoResendingMap.remove(chatId);
  _stopAutoResendingMap.remove(chatId);
}

// Update all log messages to include chatId context
```

**3. lib/src/internal/main/chat_manager/collection_manager/collection_manager.dart**
```dart
// Line 92: Update stopAutoResend call to pass chat parameter
// OLD:
AutoResendManager().stopAutoResend();

// NEW:
AutoResendManager().stopAutoResend(_chat);
```

**4. lib/src/internal/main/chat_manager/collection_manager/message_retention_manager.dart**
```dart
// Update config_ts key to be app-specific

// Class field - REPLACE:
// final String _configTsKey = 'com.sendbird.chat.config_ts';
// WITH:
final String _configTsKeyPrefix = 'com.sendbird.chat.config_ts';

// ADD new helper method:
/// Get config_ts key for specific appId to support multi-instance
String _getConfigTsKey(String appId) {
  return '${_configTsKeyPrefix}_$appId';
}

// Update all method signatures and calls:

// setConfigTs - OLD:
Future<bool> setConfigTs(int configTs) async {
  final prefs = await SharedPreferences.getInstance();
  return await prefs.setInt(_configTsKey, configTs);
}
// NEW:
Future<bool> setConfigTs(String appId, int configTs) async {
  final prefs = await SharedPreferences.getInstance();
  return await prefs.setInt(_getConfigTsKey(appId), configTs);
}

// getConfigTs - OLD:
Future<int?> getConfigTs() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_configTsKey);
}
// NEW:
Future<int?> getConfigTs(String appId) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_getConfigTsKey(appId));
}

// clearConfigTs - OLD:
Future<void> clearConfigTs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_configTsKey);
}
// NEW:
Future<void> clearConfigTs(String appId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_getConfigTsKey(appId));
}

// In checkApplicationSettings method:
// Line 31: REPLACE:
int? lastConfigTs = await getConfigTs();
// WITH:
int? lastConfigTs = await getConfigTs(chat.chatContext.appId);

// Line 89: REPLACE:
setConfigTs(settings.ts!);
// WITH:
setConfigTs(chat.chatContext.appId, settings.ts!);
```

**5. lib/src/internal/main/chat_manager/connection_manager.dart**
```dart
// Add import at top:
import 'collection_manager/auto_resend_manager.dart';

// Line 354: Update clearConfigTs call
// OLD:
await MessageRetentionManager().clearConfigTs();
// NEW:
await MessageRetentionManager().clearConfigTs(chat.chatContext.appId);
AutoResendManager().cleanUp(chat.chatId);

// Line 675: Update getConfigTs call
// OLD:
int configTs = await MessageRetentionManager().getConfigTs() ?? 0;
// NEW:
int configTs = await MessageRetentionManager().getConfigTs(appId) ?? 0;
```
