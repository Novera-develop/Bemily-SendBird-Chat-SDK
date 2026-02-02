// Copyright (c) 2023 Sendbird, Inc. All rights reserved.

import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat_manager/collection_manager/message_retention_manager.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/sendbird_logger.dart';
import 'package:sendbird_chat_sdk/src/internal/network/http/http_client/request/channel/message/channel_message_change_log_get_request.dart';
import 'package:sendbird_chat_sdk/src/internal/network/websocket/event/login_event.dart';
import 'package:sendbird_chat_sdk/src/public/core/channel/group_channel/group_channel.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/base_message.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/enums.dart';
import 'package:sendbird_chat_sdk/src/public/main/params/message/message_change_logs_params.dart';

class EventDispatcher {
  final Chat _chat;

  EventDispatcher({required Chat chat}) : _chat = chat;

  Future<void> onConnecting() async {
    sbLog.d(StackTrace.current);
    await _chat.statManager.onConnecting();
  }

  Future<void> onLogin(LoginEvent event) async {
    sbLog.d(StackTrace.current);
    _chat.collectionManager.onLogin(event);

    if (event.configSyncNeeded ?? false) {
      MessageRetentionManager().checkApplicationSettings(_chat);
    }

    await _chat.statManager.onLogin(event);
  }

  Future<void> onReconnected(LoginEvent event) async {
    sbLog.d(StackTrace.current);
    _chat.collectionManager.onReconnected(event);

    if (event.configSyncNeeded ?? false) {
      MessageRetentionManager().checkApplicationSettings(_chat);
    }

    await _chat.statManager.onReconnected(event);

    // Sync missed messages for cached GroupChannels (await to ensure order)
    await _syncMissedMessages();
  }

  /// Syncs missed messages for all cached GroupChannels after reconnect
  Future<void> _syncMissedMessages() async {
    final lastConnectedAt = _chat.chatContext.lastConnectedAt;
    if (lastConnectedAt == null || lastConnectedAt == 0) {
      sbLog.e(StackTrace.current, 'No lastConnectedAt, skipping message sync');
      return;
    }

    final cachedChannels = _chat.channelCache.getCachedChannels();
    final groupChannels = cachedChannels.whereType<GroupChannel>().toList();

    if (groupChannels.isEmpty) {
      sbLog.e(
          StackTrace.current, 'No cached GroupChannels, skipping message sync');
      return;
    }

    sbLog.e(StackTrace.current,
        'Syncing missed messages for ${groupChannels.length} channels since $lastConnectedAt');

    for (final channel in groupChannels) {
      try {
        await _syncMissedMessagesForChannel(channel, lastConnectedAt);
      } catch (e) {
        sbLog.e(StackTrace.current,
            'Failed to sync messages for channel ${channel.channelUrl}: $e');
      }
    }
  }

  /// Syncs missed messages for a specific channel
  Future<void> _syncMissedMessagesForChannel(
    GroupChannel channel,
    int lastConnectedAt,
  ) async {
    final params = MessageChangeLogParams();
    final changeLogs = await _chat.apiClient.send(
      ChannelMessageChangeLogGetRequest(
        _chat,
        channelType: ChannelType.group,
        channelUrl: channel.channelUrl,
        params: params,
        timestamp: lastConnectedAt,
      ),
    );

    final newMessages = changeLogs.updatedMessages
        .where((msg) => msg.createdAt > lastConnectedAt)
        .toList();

    if (newMessages.isEmpty) {
      sbLog.e(StackTrace.current,
          'No new messages for channel ${channel.channelUrl}');
      return;
    }

    // Sort by createdAt to maintain order
    newMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    sbLog.e(StackTrace.current,
        'Found ${newMessages.length} missed messages for channel ${channel.channelUrl}');

    // Notify handlers for each message
    for (final message in newMessages) {
      if (message is BaseMessage) {
        _chat.eventManager.notifyMessageReceived(channel, message);
      }
    }
  }

  Future<void> onDisconnected() async {
    sbLog.d(StackTrace.current);
    _chat.collectionManager.onDisconnected();
  }

  Future<void> onReconnecting() async {
    sbLog.d(StackTrace.current);
  }

  Future<void> onLogout() async {
    sbLog.d(StackTrace.current);
    await _chat.statManager.onLogout();
  }
}
