import 'dart:async';

import 'package:sendbird_chat_sdk/sendbird_chat_sdk.dart';

void main() async {
  // Choose one of the examples below:

  // Example 1: Single instance (default)
  await singleInstanceExample();

  // Example 2: Multiple instances (for multiple app IDs)
  // await multipleInstancesExample();
}

/// Example 1: Using a single SendbirdChat instance (most common use case)
Future<void> singleInstanceExample() async {
  runZonedGuarded(() async {
    // Get or create the default instance
    final sendbird = SendbirdChat();

    // Initialize the SendbirdChat SDK with your Application ID.
    await sendbird.init(appId: 'APP-ID');

    // Connect to the Sendbird server with a User ID.
    await sendbird.connect('USER-ID');

    // Create a new open channel.
    // Note: When using the default instance, you don't need to pass 'chat' parameter
    final openChannel =
        await OpenChannel.createChannel(OpenChannelCreateParams());

    // Enter the channel.
    await openChannel.enter();

    // Send a message to the channel.
    openChannel.sendUserMessage(UserMessageCreateParams(message: 'MESSAGE'));
  }, (e, s) {
    // Handle error.
    print('Error: $e');
  });
}

/// Example 2: Using multiple SendbirdChat instances simultaneously
/// This is useful when you need to connect to multiple Sendbird applications
/// at the same time (e.g., production and staging, or different workspaces)
Future<void> multipleInstancesExample() async {
  runZonedGuarded(() async {
    // First Sendbird app instance (default)
    final sendbird1 = SendbirdChat();
    await sendbird1.init(appId: 'APP-ID-1');
    await sendbird1.connect('USER-ID-1');

    // Second Sendbird app instance (independent)
    final sendbird2 = SendbirdChat.create();
    await sendbird2.init(appId: 'APP-ID-2');
    await sendbird2.connect('USER-ID-2');

    // Use first instance - uses default instance automatically
    final channel1 = await GroupChannel.getChannel('CHANNEL-URL-1');
    print('Channel 1 from app 1: ${channel1.name}');

    // Use second instance - must explicitly pass chat parameter
    final channel2 = await GroupChannel.getChannel(
      'CHANNEL-URL-2',
      chat: sendbird2.chat,
    );
    print('Channel 2 from app 2: ${channel2.name}');

    // Create message collection for first instance
    // final collection1 = MessageCollection(
    //   channel: channel1, params: null, handler: null,
    //   // chat parameter is optional for default instance
    // );
    //
    // // Create message collection for second instance
    // final collection2 = MessageCollection(
    //   channel: channel2,
    //   chat: sendbird2.chat, // Must specify chat for non-default instance
    // );

    // await collection1.initialize();
    // await collection2.initialize();

    print('Both collections initialized successfully!');
  }, (e, s) {
    // Handle error.
    print('Error: $e\nStackTrace: $s');
  });
}
