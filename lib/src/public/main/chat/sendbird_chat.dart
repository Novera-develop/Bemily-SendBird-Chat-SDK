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
