// Copyright (c) 2023 Sendbird, Inc. All rights reserved.

import 'package:isar_community/isar.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/channel/c_feed_channel.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/channel/c_group_channel.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/channel/meta/c_channel_info.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/channel/meta/channel_info.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/chunk/c_channel_chunk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/chunk/c_message_chunk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/chunk/channel_chunk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/chunk/chunk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/chunk/message_chunk.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/login/c_login.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/login/login.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/c_admin_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/c_file_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/c_notification_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/c_user_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/meta/c_channel_access.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/meta/c_channel_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/meta/c_message_changelog_info.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/meta/channel_access.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/meta/channel_message.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/message/meta/message_changelog_info.dart';
import 'package:sendbird_chat_sdk/src/internal/db/schema/user/c_user.dart';
import 'package:sendbird_chat_sdk/src/internal/main/chat/chat.dart';
import 'package:sendbird_chat_sdk/src/public/core/channel/feed_channel/feed_channel.dart';
import 'package:sendbird_chat_sdk/src/public/core/channel/group_channel/group_channel.dart';
import 'package:sendbird_chat_sdk/src/public/core/channel/group_channel/mfm/multiple_files_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/admin_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/base_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/file_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/notification_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/root_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/message/user_message.dart';
import 'package:sendbird_chat_sdk/src/public/core/user/user.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/enums.dart';
import 'package:sendbird_chat_sdk/src/public/main/params/message/message_list_params.dart';
import 'package:sendbird_chat_sdk/src/public/main/query/channel/feed_channel_list_query.dart';
import 'package:sendbird_chat_sdk/src/public/main/query/channel/group_channel_list_query.dart';

import 'schema/message/c_multiple_files_message.dart';

class DB {
  final Chat _chat;
  final Isar _isar;
  final Map<String, String> _groupChannelSignatures = {};
  final Map<String, Future<void>> _groupChannelWrites = {};
  Future<void> _pendingPersistence = Future<void>.value();
  Object _groupChannelWriteGeneration = Object();

  DB({
    required Chat chat,
    required Isar isar,
  })  : _chat = chat,
        _isar = isar;

  // DB
  Future<void> write(Function writeFunc) async {
    await _isar.writeTxn(() async {
      await writeFunc();
    });
  }

  Future<void> clear({bool Function()? shouldPersist}) async {
    if (shouldPersist?.call() == false) return;
    _groupChannelWriteGeneration = Object();
    _groupChannelWrites.clear();
    _groupChannelSignatures.clear();
    await _enqueuePersistence(() async {
      if (shouldPersist?.call() == false) return;
      await _isar.writeTxn(() async {
        if (shouldPersist?.call() == false) return;
        await _isar.clear();
      });
    });
  }

  Future<void> _enqueuePersistence(Future<void> Function() persist) {
    final generation = _groupChannelWriteGeneration;
    final previous = _pendingPersistence;
    final pending = (() async {
      await previous;
      if (identical(generation, _groupChannelWriteGeneration)) {
        await persist();
      }
    })();
    _pendingPersistence = pending.catchError((Object _) {});
    return pending;
  }

  // Login
  Future<void> upsertLogin(Login login, {bool Function()? shouldPersist}) async {
    if (shouldPersist?.call() == false) return;
    await CLogin.upsert(_chat, _isar, login, shouldPersist: shouldPersist);
  }

  Future<Login?> getLogin(String userId) async {
    return await CLogin.get(_chat, _isar, userId);
  }

  Future<void> deleteLogin(String userId) async {
    await CLogin.delete(_chat, _isar, userId);
  }

  Future<int> getLoginCount() async {
    return await _isar.cLogins.count();
  }

  // ChannelChunk
  Future<void> upsertChannelChunk(ChannelChunk chunk) async {
    await CChannelChunk.upsert(_chat, _isar, chunk);
  }

  Future<ChannelChunk?> getChannelChunk(ChannelChunkType chunkType) async {
    return await CChannelChunk.get(_chat, _isar, chunkType);
  }

  Future<void> deleteChannelChunk(ChannelChunkType chunkType) async {
    await CChannelChunk.delete(_chat, _isar, chunkType);
  }

  Future<int> getChannelChunkCount() async {
    return await _isar.cChannelChunks.count();
  }

  // MessageChunk
  Future<void> upsertMessageChunk(MessageChunk chunk) async {
    await CMessageChunk.upsert(_chat, _isar, chunk);
  }

  Future<MessageChunk?> getMessageChunk(String channelUrl) async {
    return await CMessageChunk.get(_chat, _isar, channelUrl);
  }

  Future<void> deleteMessageChunk(String channelUrl) async {
    await CMessageChunk.delete(_chat, _isar, channelUrl);
  }

  Future<void> deleteMessagesInChunk({
    required String channelUrl,
    required List<String> rootIds,
  }) async {
    if (rootIds.isEmpty) {
      return;
    }

    final messageChunk = await getMessageChunk(channelUrl);
    if (messageChunk != null) {
      final List<Chunk> chunks = [];

      for (final rootId in rootIds) {
        final message = await getChannelMessage(rootId);

        if (message?.createdAt != null) {
          final Chunk? chunk = messageChunk.getChunk(message!.createdAt);
          if (chunk != null && !chunks.contains(chunk)) {
            chunks.add(chunk);
          }
        }
      }

      bool isChanged = false;
      for (final chunk in chunks) {
        final cChannelMessages = await _isar.cChannelMessages
            .where()
            .createdAtBetween(
              chunk.oldestTs,
              chunk.latestTs,
              includeLower: true,
              includeUpper: true,
            )
            .sortByCreatedAt()
            .findAll();
        final newCChannelMessages = [...cChannelMessages];

        if (cChannelMessages.isNotEmpty) {
          for (final cChannelMessage in cChannelMessages) {
            for (final rootId in rootIds) {
              if (cChannelMessage.rootId == rootId) {
                newCChannelMessages.remove(cChannelMessage);
                isChanged = true;
                break;
              }
            }
          }

          messageChunk.removeChunk(chunk);

          if (newCChannelMessages.isNotEmpty) {
            messageChunk.add(Chunk(
              oldestTs: newCChannelMessages.first.createdAt,
              latestTs: newCChannelMessages.last.createdAt,
            ));
          }
        }
      }

      if (isChanged) {
        await upsertMessageChunk(messageChunk);
      }
    }
  }

  Future<int> getMessageChunkCount() async {
    return await _isar.cMessageChunks.count();
  }

  // ChannelInfo
  Future<void> upsertChannelInfo(ChannelInfo info) async {
    await CChannelInfo.upsert(_chat, _isar, info);
  }

  Future<ChannelInfo?> getChannelInfo() async {
    return await CChannelInfo.get(_chat, _isar);
  }

  Future<void> deleteChannelInfo() async {
    await CChannelInfo.delete(_chat, _isar);
  }

  Future<int> getChannelInfoCount() async {
    return await _isar.cChannelInfos.count();
  }

  // MessageChangeLogInfo
  Future<void> upsertMessageChangeLogInfo(MessageChangeLogInfo info) async {
    await CMessageChangeLogInfo.upsert(_chat, _isar, info);
  }

  Future<MessageChangeLogInfo?> getMessageChangeLogInfo(
      String channelUrl) async {
    return await CMessageChangeLogInfo.get(_chat, _isar, channelUrl);
  }

  Future<void> deleteMessageChangeLogInfo(String channelUrl) async {
    await CMessageChangeLogInfo.delete(_chat, _isar, channelUrl);
  }

  Future<int> getMessageChangeLogInfoCount() async {
    return await _isar.cMessageChangeLogInfos.count();
  }

  // ChannelAccess
  Future<void> upsertChannelAccess(ChannelAccess channelAccess) async {
    await CChannelAccess.upsert(_chat, _isar, channelAccess);
  }

  Future<List<String>> getOrderedChannelUrlsToDelete() async {
    final channelUrls =
        (await _isar.cChannelAccess.where().sortByLastAccessedAt().findAll())
            .map((cChannelAccess) => cChannelAccess.channelUrl)
            .toList();
    return channelUrls;
  }

  Future<void> deleteChannelAccess(String channelUrl) async {
    await CChannelAccess.delete(_chat, _isar, channelUrl);
  }

  Future<int> getChannelAccessCount() async {
    return await _isar.cChannelAccess.count();
  }

  // GroupChannel
  Future<void> updateGroupChannelReadStatus(GroupChannel channel,
      {required bool Function() shouldPersist}) {
    final persist = CGroupChannel.prepareReadStatusUpdate(
        _isar, channel, shouldPersist);
    return _enqueuePersistence(() async {
      if (shouldPersist()) await _chat.dbManager.write(persist);
    });
  }

  Future<void> upsertGroupChannel(GroupChannel channel) {
    final snapshot = CGroupChannel.prepareUpsert(_isar, channel);
    final channelUrl = channel.channelUrl;
    final previous = _groupChannelWrites[channelUrl];
    if (_groupChannelSignatures[channelUrl] == snapshot.signature) {
      return previous ?? Future<void>.value();
    }
    _groupChannelSignatures[channelUrl] = snapshot.signature;
    late final Future<void> pending;
    pending = _enqueuePersistence(() async {
      try {
        await _chat.dbManager.write(snapshot.persist);
      } finally {
        if (identical(_groupChannelWrites[channelUrl], pending)) {
          _groupChannelWrites.remove(channelUrl);
          _groupChannelSignatures.remove(channelUrl);
        }
      }
    });
    _groupChannelWrites[channelUrl] = pending;
    return pending;
  }

  Future<GroupChannel?> getGroupChannel(String channelUrl) async {
    return await CGroupChannel.get(_chat, _isar, channelUrl);
  }

  Future<List<GroupChannel>> getGroupChannels(
      GroupChannelListQuery query, int? offset) async {
    return await CGroupChannel.getChannels(_chat, _isar, query, offset);
  }

  Future<bool> canAddChannel(
      GroupChannelListQuery query, String channelUrl) async {
    return await CGroupChannel.canAddChannel(_chat, _isar, query, channelUrl);
  }

  Future<void> deleteGroupChannel(String channelUrl) async {
    await _enqueuePersistence(() async {
      _groupChannelSignatures.remove(channelUrl);
      await CGroupChannel.delete(_chat, _isar, channelUrl);
    });
  }

  Future<int> getGroupChannelCount() async {
    return await _isar.cGroupChannels.count();
  }

  // FeedChannel
  Future<void> upsertFeedChannel(FeedChannel channel) async {
    await CFeedChannel.upsert(_chat, _isar, channel);
  }

  Future<FeedChannel?> getFeedChannel(String channelUrl) async {
    return await CFeedChannel.get(_chat, _isar, channelUrl);
  }

  Future<List<FeedChannel>> getFeedChannels(
      FeedChannelListQuery query, int? offset) async {
    return await CFeedChannel.getChannels(_chat, _isar, query, offset);
  }

  Future<void> deleteFeedChannel(String channelUrl) async {
    await CFeedChannel.delete(_chat, _isar, channelUrl);
  }

  Future<int> getFeedChannelCount() async {
    return await _isar.cFeedChannels.count();
  }

  // ChannelMessage
  Future<bool> hasMessages(String channelUrl) async {
    return await CChannelMessage.hasMessages(_chat, _isar, channelUrl);
  }

  Future<ChannelMessage?> getChannelMessage(String rootId) async {
    return await CChannelMessage.get(_chat, _isar, rootId);
  }

  Future<List<RootMessage>> getMessages(
    ChannelType channelType,
    String channelUrl,
    SendingStatus sendingStatus,
    int timestamp,
    MessageListParams params,
    bool isPrevious,
  ) async {
    return await CChannelMessage.getMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
      sendingStatus,
      timestamp,
      params,
      isPrevious,
    );
  }

  Future<BaseMessage?> getBaseMessageById(
    ChannelType channelType,
    String channelUrl,
    int messageId,
  ) async {
    return await CChannelMessage.getBaseMessageById(
      _chat,
      _isar,
      channelType,
      channelUrl,
      messageId,
    );
  }

  Future<List<BaseMessage>> getPendingMessages({
    required ChannelType channelType,
    required String channelUrl,
  }) async {
    return await CChannelMessage.getPendingMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
    );
  }

  Future<List<BaseMessage>> getFailedMessages({
    required ChannelType channelType,
    required String channelUrl,
    required bool reverse,
  }) async {
    return await CChannelMessage.getFailedMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
      reverse,
    );
  }

  Future<FileMessage?> getFailedFileMessage({
    required ChannelType channelType,
    required String channelUrl,
    required String requestId,
  }) async {
    return await CChannelMessage.getFailedFileMessage(
      _chat,
      _isar,
      channelType,
      channelUrl,
      requestId,
    );
  }

  Future<void> removeFailedMessages({
    required ChannelType channelType,
    required String channelUrl,
    required List<BaseMessage> messages,
  }) async {
    await CChannelMessage.removeFailedMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
      messages,
    );
  }

  Future<void> removeAllFailedMessages({
    required ChannelType channelType,
    required String channelUrl,
  }) async {
    await CChannelMessage.removeAllFailedMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
    );
  }

  Future<void> removeAllPendingMessages({
    required ChannelType channelType,
    required String channelUrl,
  }) async {
    await CChannelMessage.removeAllPendingMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
    );
  }

  Future<List<RootMessage>> getStartingPointMessages(
    ChannelType channelType,
    String channelUrl,
    int timestamp,
  ) async {
    return await CChannelMessage.getStartingPointMessages(
      _chat,
      _isar,
      channelType,
      channelUrl,
      timestamp,
    );
  }

  Future<void> deleteChannelMessage(String rootId) async {
    await _enqueuePersistence(() async {
      await CChannelMessage.delete(_chat, _isar, rootId);
    });
  }

  // Message
  Future<void> deleteMessages(String channelUrl) async {
    // UserMessage
    final cUserMessages = await _isar.cUserMessages
        .where()
        .channelUrlEqualTo(channelUrl)
        .findAll();
    for (final cUserMessage in cUserMessages) {
      await deleteUserMessage(cUserMessage.rootId);
    }

    // FileMessage
    final cFileMessages = await _isar.cFileMessages
        .where()
        .channelUrlEqualTo(channelUrl)
        .findAll();
    for (final cFileMessage in cFileMessages) {
      await deleteFileMessage(cFileMessage.rootId);
    }

    // MultipleFilesMessage
    final cMultipleFilesMessages = await _isar.cMultipleFilesMessages
        .where()
        .channelUrlEqualTo(channelUrl)
        .findAll();
    for (final cMultipleFilesMessage in cMultipleFilesMessages) {
      await deleteFileMessage(cMultipleFilesMessage.rootId);
    }

    // AdminMessage
    final cAdminMessages = await _isar.cAdminMessages
        .where()
        .channelUrlEqualTo(channelUrl)
        .findAll();
    for (final cAdminMessage in cAdminMessages) {
      await deleteAdminMessage(cAdminMessage.rootId);
    }

    // NotificationMessage
    final cNotificationMessages = await _isar.cNotificationMessages
        .where()
        .channelUrlEqualTo(channelUrl)
        .findAll();
    for (final cNotificationMessage in cNotificationMessages) {
      await deleteNotificationMessage(cNotificationMessage.rootId);
    }
  }

  // UserMessage
  Future<void> upsertUserMessage(UserMessage message) async {
    await _enqueuePersistence(() async {
      await CUserMessage.upsert(_chat, _isar, message);
    });
  }

  Future<UserMessage?> getUserMessage(String rootId) async {
    return await CUserMessage.get(_chat, _isar, rootId);
  }

  Future<void> deleteUserMessage(String rootId) async {
    await _enqueuePersistence(() async {
      await CUserMessage.delete(_chat, _isar, rootId);
    });
  }

  Future<int> getUserMessageCount() async {
    return await _isar.cUserMessages.count();
  }

  // FileMessage
  Future<void> upsertFileMessage(FileMessage message) async {
    await _enqueuePersistence(() async {
      await CFileMessage.upsert(_chat, _isar, message);
    });
  }

  Future<FileMessage?> getFileMessage(String rootId) async {
    return await CFileMessage.get(_chat, _isar, rootId);
  }

  Future<void> deleteFileMessage(String rootId) async {
    await _enqueuePersistence(() async {
      await CFileMessage.delete(_chat, _isar, rootId);
    });
  }

  Future<int> getFileMessageCount() async {
    return await _isar.cFileMessages.count();
  }

  // MultipleFilesMessage
  Future<void> upsertMultipleFilesMessage(MultipleFilesMessage message) async {
    await _enqueuePersistence(() async {
      await CMultipleFilesMessage.upsert(_chat, _isar, message);
    });
  }

  Future<MultipleFilesMessage?> getMultipleFilesMessage(String rootId) async {
    return await CMultipleFilesMessage.get(_chat, _isar, rootId);
  }

  Future<void> deleteMultipleFilesMessage(String rootId) async {
    await _enqueuePersistence(() async {
      await CMultipleFilesMessage.delete(_chat, _isar, rootId);
    });
  }

  Future<int> getMultipleFilesMessageCount() async {
    return await _isar.cMultipleFilesMessages.count();
  }

  // AdminMessage
  Future<void> upsertAdminMessage(AdminMessage message) async {
    await _enqueuePersistence(() async {
      await CAdminMessage.upsert(_chat, _isar, message);
    });
  }

  Future<AdminMessage?> getAdminMessage(String rootId) async {
    return await CAdminMessage.get(_chat, _isar, rootId);
  }

  Future<void> deleteAdminMessage(String rootId) async {
    await _enqueuePersistence(() async {
      await CAdminMessage.delete(_chat, _isar, rootId);
    });
  }

  Future<int> getAdminMessageCount() async {
    return await _isar.cAdminMessages.count();
  }

  // NotificationMessage
  Future<void> upsertNotificationMessage(NotificationMessage message) async {
    await CNotificationMessage.upsert(_chat, _isar, message);
  }

  Future<NotificationMessage?> getNotificationMessage(String rootId) async {
    return await CNotificationMessage.get(_chat, _isar, rootId);
  }

  Future<void> deleteNotificationMessage(String rootId) async {
    await CNotificationMessage.delete(_chat, _isar, rootId);
  }

  Future<int> getNotificationMessageCount() async {
    return await _isar.cNotificationMessages.count();
  }

  // User
  Future<void> upsertUser(User user, {bool Function()? shouldPersist}) async {
    if (shouldPersist?.call() == false) return;
    await CUser.upsert(_chat, _isar, user, shouldPersist: shouldPersist);
  }

  Future<User?> getUser(String userId) async {
    return await CUser.get(_chat, _isar, userId);
  }

  Future<void> deleteUser(String userId) async {
    await CUser.delete(_chat, _isar, userId);
  }

  Future<int> getUserCount() async {
    return await _isar.cUsers.count();
  }
}
