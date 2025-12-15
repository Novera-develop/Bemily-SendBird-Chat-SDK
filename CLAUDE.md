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
