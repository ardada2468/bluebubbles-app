import 'dart:async';
import 'package:bluebubbles/repository/models/platform_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';

import 'package:bluebubbles/blocs/chat_bloc.dart';
import 'package:bluebubbles/blocs/message_bloc.dart';
import 'package:bluebubbles/helpers/attachment_downloader.dart';
import 'package:bluebubbles/helpers/attachment_helper.dart';
import 'package:bluebubbles/helpers/attachment_sender.dart';
import 'package:bluebubbles/helpers/darty.dart';
import 'package:bluebubbles/helpers/logger.dart';
import 'package:bluebubbles/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/managers/current_chat.dart';
import 'package:bluebubbles/managers/life_cycle_manager.dart';
import 'package:bluebubbles/managers/new_message_manager.dart';
import 'package:bluebubbles/managers/notification_manager.dart';
import 'package:bluebubbles/managers/outgoing_queue.dart';
import 'package:bluebubbles/managers/queue_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/attachment.dart';
import 'package:bluebubbles/repository/models/chat.dart';
import 'package:bluebubbles/repository/models/handle.dart';
import 'package:bluebubbles/repository/models/message.dart';
import 'package:bluebubbles/socket_manager.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';

/// This helper class allows us to section off all socket "actions"
/// These actions allow us to interact with the server, whether it
/// be telling the server to do something, or asking the server for
/// information
class ActionHandler {
  /// Tells the server to create a [text] in the [chat], along with
  /// any [attachments] that go with the message
  ///
  /// ```dart
  /// sendMessage(chatObject, 'Hello world!')
  /// ```
  static Future<void> sendMessage(Chat chat, String text,
      {MessageBloc? messageBloc, List<Attachment> attachments = const [], String? subject, String? replyGuid, String? effectId, Completer<void>? completer}) async {
    if (isNullOrEmpty(text, trimString: true)! && isNullOrEmpty(subject ?? "", trimString: true)!) return;

    if ((await SettingsManager().getMacOSVersion() ?? 10) < 11) {
      List<Message> messages = <Message>[];

      // Check for URLs
      RegExpMatch? linkMatch;
      String? linkMsg;
      List<RegExpMatch> matches = parseLinks(text.replaceAll("\n", " "));

      // Get the first match (if it exists)
      if (matches.isNotEmpty) {
        linkMatch = matches.first;
        linkMsg = text.substring(linkMatch.start, linkMatch.end).trim();
      }

      // Figure out of the message starts or ends with the link
      // In either case, we want to split up the messages
      bool shouldSplitEnd = linkMatch != null && text.endsWith(linkMsg!);
      bool shouldSplitStart = linkMatch != null && text.startsWith(linkMsg!);
      bool shouldSplit = shouldSplitEnd || shouldSplitStart;

      // Split up the messages depending on if the link is at the start or end
      String mainText = text;
      String secondaryText = text;
      if (shouldSplitEnd) {
        mainText = text.substring(0, linkMatch.start);
        secondaryText = text.substring(linkMatch.start, linkMatch.end);
      } else if (shouldSplitStart) {
        mainText = text.substring(linkMatch.start, linkMatch.end);
        secondaryText = text.substring(linkMatch.end);
      }

      Message mainMsg = Message(
        text: mainText.isEmpty && (subject ?? "").trim().isNotEmpty ? (subject ?? "").trim() : mainText.trim(),
        subject: (mainText.isEmpty && (subject ?? "").trim().isNotEmpty) || (subject ?? "").trim().isEmpty ? null : (subject ?? "").trim(),
        dateCreated: DateTime.now(),
        hasAttachments: attachments.isNotEmpty ? true : false,
        threadOriginatorGuid: replyGuid,
        expressiveSendStyleId: effectId,
        isFromMe: true,
      );

      // Generate a Temp GUID
      mainMsg.generateTempGuid();

      if (mainMsg.text!.trim().isNotEmpty
          || (mainMsg.subject?.trim().length ?? 0) > 0) messages.add(mainMsg);

      // If there is a link, build the link message
      if (shouldSplit) {
        Message secondaryMessage = Message(
          text: secondaryText.trim(),
          dateCreated: DateTime.now(),
          hasAttachments: false,
          threadOriginatorGuid: replyGuid,
          expressiveSendStyleId: effectId,
          isFromMe: true,
        );

        // Generate a Temp GUID
        secondaryMessage.generateTempGuid();
        messages.add(secondaryMessage);
      }

      // Make sure to save the chat
      // If we already have the ID, we don't have to wait to resave it
      if (chat.id == null) {
        await chat.save();
      } else {
        chat.save();
      }

      // Send all the messages
      List<Completer<void>> completerList = List.generate(messages.length, (_) => Completer());
      messages.forEachIndexed((index, message) async {
        // Add the message to the UI and DB
        NewMessageManager().addMessage(chat, message, outgoing: true);
        chat.addMessage(message);

        // Create params for the queue item
        Map<String, dynamic> params = {"chat": chat, "message": message};

        // Add the message send to the queue
        await OutgoingQueue().add(QueueItem(event: "send-message", item: params), completer: completer != null ? completerList[index] : null);

        if (index == messages.length - 1) {
          completer?.complete();
        }
      });

      return completer?.future;
    } else {
      // Create the main message
      Message message = Message(
        text: text.isEmpty && (subject ?? "").trim().isNotEmpty ? (subject ?? "").trim() : text.trim(),
        subject: (text.isEmpty && (subject ?? "").trim().isNotEmpty) || (subject ?? "").trim().isEmpty ? null : (subject ?? "").trim(),
        dateCreated: DateTime.now(),
        hasAttachments: attachments.isNotEmpty ? true : false,
        threadOriginatorGuid: replyGuid,
        expressiveSendStyleId: effectId,
        isFromMe: true,
      );

      // Generate a Temp GUID
      message.generateTempGuid();

      // Make sure to save the chat
      // If we already have the ID, we don't have to wait to resave it
      if (chat.id == null) {
        await chat.save();
      } else {
        chat.save();
      }

      // Add the message to the UI and DB
      NewMessageManager().addMessage(chat, message, outgoing: true);
      chat.addMessage(message);

      // Create params for the queue item
      Map<String, dynamic> params = {"chat": chat, "message": message};

      // Add the message send to the queue
      await OutgoingQueue().add(QueueItem(event: "send-message", item: params), completer: completer);
    }
  }

  static Future<Chat?> createChatBigSur(BuildContext context, String address, String text) async {
    showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: Theme.of(context).colorScheme.secondary,
            title: Text(
              "Creating a new chat...",
              style: Theme.of(context).textTheme.bodyText1,
            ),
            content:
            Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
              Container(
                // height: 70,
                // color: Colors.black,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                ),
              ),
            ]),
          );
        });

    Logger.info("Starting chat with participant: $address");
    Message message = Message(
      text: text.trim(),
      dateCreated: DateTime.now(),
      isFromMe: true,
    );

    message.generateTempGuid();

    // Create params for the queue item
    Map<String, dynamic> params = {"guid": "iMessage;-;$address", "message": message.text, "tempGuid": message.guid};

    // Add the message send to the queue
    final response = await SocketManager().sendMessage("send-message", params, (response) {});
    if (response['data'] == null) {
      return null;
    }
    message = Message.fromMap(response['data']);
    final chat = Chat.fromMap(response['data']['chats'].first);

    // If there is an error, replace the temp value with an error
    if (response['status'] != 200) {
      message.guid = message.guid!.replaceAll("temp", "error-${response['error']['message']}");
      message.error.value =
      response['status'] == 400 ? MessageError.BAD_REQUEST.code : MessageError.SERVER_ERROR.code;
    }

    // Make sure to save the chat
    // If we already have the ID, we don't have to wait to resave it
    await chat.save();
    await ChatBloc().updateChatPosition(chat);
    // for some reason it likes to add multiple of the chat in the chat list so
    // deduplicate them just in case
    final ids = ChatBloc().chats.map((e) => e.guid).toSet();
    ChatBloc().chats.retainWhere((element) => ids.remove(element.guid));

    // Add the message to the UI and DB
    NewMessageManager().addMessage(chat, message, outgoing: true);
    chat.addMessage(message);
    Navigator.of(context).pop();
    return chat;
  }

  static Future<void> sendMessageHelper(Chat chat, Message message) async {
    Completer<void> completer = Completer<void>();
    Map<String, dynamic> params = {};
    params["guid"] = chat.guid;
    params["message"] = message.text;
    params["tempGuid"] = message.guid;

    void sendSocketMessage() {
      if ((message.subject?.isNotEmpty ?? false) || message.threadOriginatorGuid != null || message.expressiveSendStyleId != null) {
        api.sendMessage(
            chat.guid!,
            message.guid!,
            message.text!,
            subject: message.subject,
            method: "private-api",
            selectedMessageGuid: message.threadOriginatorGuid,
            effectId: message.expressiveSendStyleId
        ).then((response) async {
          String? tempGuid = message.guid;
          // If there is an error, replace the temp value with an error
          if (response.statusCode != 200) {
            message.guid = message.guid!.replaceAll("temp", "error-${response.data['error']['message']}");
            message.error.value =
            response.statusCode == 400 ? MessageError.BAD_REQUEST.code : MessageError.SERVER_ERROR.code;

            await Message.replaceMessage(tempGuid, message);
            NewMessageManager().updateMessage(chat, tempGuid!, message);
          } else {
            Message newMessage = Message.fromMap(response.data['data']);
            await Message.replaceMessage(tempGuid, newMessage, chat: chat);
            List<dynamic> attachments = response.data['data'].containsKey("attachments") ? response.data['data']['attachments'] : [];
            newMessage.attachments = [];
            for (dynamic attachmentItem in attachments) {
              Attachment file = Attachment.fromMap(attachmentItem);

              try {
                await Attachment.replaceAttachment(tempGuid, file);
              } catch (ex) {
                Logger.warn("Attachment's Old GUID doesn't exist. Skipping");
              }
              newMessage.attachments.add(file);
            }
            Logger.info("Message match: [${response.data['data']["text"]}] - ${response.data['data']["guid"]} - $tempGuid", tag: "MessageStatus");

            NewMessageManager().updateMessage(chat, tempGuid!, newMessage);
          }

          completer.complete();
        });
      } else {
        SocketManager().sendMessage("send-message", params, (response) async {
          String? tempGuid = message.guid;

          // If there is an error, replace the temp value with an error
          if (response['status'] != 200) {
            message.guid = message.guid!.replaceAll("temp", "error-${response['error']['message']}");
            message.error.value =
            response['status'] == 400 ? MessageError.BAD_REQUEST.code : MessageError.SERVER_ERROR.code;

            await Message.replaceMessage(tempGuid, message);
            NewMessageManager().updateMessage(chat, tempGuid!, message);
          }

          completer.complete();
        });
      }
    }

    bool isConnected = kIsWeb;
    if (!isConnected) {
      isConnected = await InternetConnectionChecker().hasConnection;
    }
    if (!isConnected) {
      InternetConnectionChecker().checkInterval = const Duration(seconds: 1);
      StreamSubscription? sub;
      Worker? sub2;
      Timer timer = Timer(const Duration(seconds: 30), () async {
        sub?.cancel();
        sub2?.dispose();
        String? tempGuid = message.guid;
        message.guid = message.guid!
            .replaceAll("temp", "error-Connection timeout, please check your internet connection and try again");
        message.error.value = MessageError.BAD_REQUEST.code;
        CurrentChat? currChat = CurrentChat.activeChat;
        if (!LifeCycleManager().isAlive || currChat?.chat.guid != chat.guid) {
          NotificationManager().createFailedToSendMessage();
        }
        await Message.replaceMessage(tempGuid, message);
        NewMessageManager().updateMessage(chat, tempGuid!, message);
        completer.complete();
        return completer.future;
      });
      sub = InternetConnectionChecker().onStatusChange.listen((event) {
        /// listen to the internet status. we only want to fire callbacks when we
        /// are connected
        if (event == InternetConnectionStatus.connected) {
          /// Check our internal status. If we are connected *and* we haven't
          /// listened to the connection state stream, then send the message
          if (SocketManager().state.value == SocketState.CONNECTED && sub2 == null) {
            timer.cancel();
            sendSocketMessage();
            sub?.cancel();
            sub2?.dispose();
          } else {
            /// Otherwise listen to our stream and await the socket to be connected
            /// before doing anything
            sub2 = ever(SocketManager().state, (event2) {
              if (event2 == SocketState.CONNECTED && event == InternetConnectionStatus.connected) {
                timer.cancel();
                sendSocketMessage();
                sub?.cancel();
                sub2?.dispose();
              }
            });
          }
        }
      });
    } else {
      sendSocketMessage();
    }

    return completer.future;
  }

  static Future<void> sendReaction(Chat chat, Message? message, String reaction) async {
    // Create params for the queue item
    Map<String, dynamic> params = {"chat": chat, "message": message, "reaction": reaction};

    // Add the message send to the queue
    await OutgoingQueue().add(QueueItem(event: "send-reaction", item: params));
  }

  static Future<void> sendReactionHelper(Chat chat, Message message, String reaction) async {
    Completer<void> completer = Completer<void>();
    Map<String, dynamic> params = {};

    String? text = !isEmptyString(message.text) ? message.text : "A text";

    params["chatGuid"] = chat.guid;
    params["messageGuid"] = "temp-${randomString(8)}";
    params["messageText"] = text;
    params["actionMessageGuid"] = message.guid;
    params["actionMessageText"] = text;
    params["tapback"] = reaction.toLowerCase();

    SocketManager().sendMessage("send-reaction", params, (response) async {
      // String tempGuid = message.guid;

      // If there is an error, replace the temp value with an error
      if (response['status'] != 200) {
        Logger.error("FAILED TO SEND REACTION " + response['error']['message']);
      }

      completer.complete();
    });
  }

  /// Try to resents a [message] that has errored during the
  /// previous attempts to send the message
  ///
  /// ```dart
  /// retryMessage(messageObject)
  /// ```
  static Future<void> retryMessage(Message message) async {
    // Don't allow us to retry an un-errored message
    if (message.error.value == 0) return;

    // Get message's chat
    Chat? chat = await Message.getChat(message);
    if (chat == null) throw ("Could not find chat!");

    await message.fetchAttachments();
    for (int i = 0; i < message.attachments.length; i++) {
      String appDocPath = SettingsManager().appDocDir.path;
      String pathName =
          "$appDocPath/attachments/${message.attachments[i]!.guid}/${message.attachments[i]!.transferName}";
      File file = File(pathName);

      OutgoingQueue().add(
        QueueItem(
          event: "send-attachment",
          item: AttachmentSender(
            PlatformFile(
              path: file.path,
              name: file.path.split("/").last,
              size: file.lengthSync(),
              bytes: file.readAsBytesSync(),
            ),
            chat,
            i == message.attachments.length - 1 ? message.text ?? "" : "",
          ),
        ),
      );
    }

    // If we sent attachments, return because we finished sending
    if (message.attachments.isNotEmpty) return;

    // Generate the temp GUID for the message to be used
    message.generateTempGuid();

    // Build request parameters
    Map<String, dynamic> params = {};
    params["guid"] = chat.guid;
    params["message"] = message.text!.trim();

    // Pull the Old GUID (substring so we "make a copy")
    String? oldGuid = (message.guid ?? "").substring(0);

    // Generate new GUID
    message.generateTempGuid();

    // Update the new GUID
    String tempGuid = message.guid!;
    params["tempGuid"] = tempGuid;

    // Reset error, guid, and send date
    message.id = null;
    message.error.value = 0;
    message.guid = tempGuid;
    message.dateCreated = DateTime.now();

    // Delete the old message
    Map<String, dynamic> msgOpts = {'guid': oldGuid};
    await Message.delete(msgOpts);
    NewMessageManager().removeMessage(chat, oldGuid);

    // Add the new message
    await chat.addMessage(message);
    NewMessageManager().addMessage(chat, message);

    SocketManager().sendMessage("send-message", params, (response) async {
      // If there is an error, replace the temp value with an error
      if (response['status'] != 200) {
        NewMessageManager().removeMessage(chat, message.guid);
        message.guid = message.guid!.replaceAll("temp", "error-${response['error']['message']}");
        message.error.value = response['status'] == 400 ? 1001 : 1002;
        await Message.replaceMessage(tempGuid, message);
        NewMessageManager().addMessage(chat, message);
      }
    });
  }

  /// Handles the ingestion of a 'updated-message' event. It takes the
  /// input [data] and uses that data to update an already existing
  /// message within the database
  ///
  /// ```dart
  /// handleUpdatedMessage(JsonMap)
  /// ```
  static Future<void> handleUpdatedMessage(Map<String, dynamic> data, {bool headless = false}) async {
    Message updatedMessage = Message.fromMap(data);

    if (updatedMessage.isFromMe!) {
      await Future.delayed(const Duration(milliseconds: 200));
      Logger.info("Handling message update: " + updatedMessage.text!, tag: "Actions-UpdatedMessage");
    }

    updatedMessage = await Message.replaceMessage(updatedMessage.guid, updatedMessage) ?? updatedMessage;

    Chat? chat;
    if (data["chats"] == null && updatedMessage.id != null) {
      chat = await Message.getChat(updatedMessage);
    } else if (data["chats"] != null) {
      chat = Chat.fromMap(data["chats"][0]);
    }

    if (!headless && chat != null) NewMessageManager().updateMessage(chat, updatedMessage.guid!, updatedMessage);
  }

  /// Handles marking a chat by [chatGuid], with a new [status] of read or unread.
  ///
  /// ```dart
  /// handleChatStatusChange(chatGuid, status)
  /// ```
  static Future<void> handleChatStatusChange(String? chatGuid, bool? status) async {
    if (chatGuid == null) return;

    Chat? chat = await Chat.findOne({"guid": chatGuid});
    if (chat == null) return;

    await chat.toggleHasUnread(status!);
    ChatBloc().updateChat(chat);
  }

  /// Handles the ingestion of an incoming chat. Chats come in
  /// associated with a message. These chats can either be passed
  /// as a [chat] object or JSON [chatData]. Lastly, the user can
  /// tell the function if they want it to check for the existance
  /// of the chat using the [checkifExists] parameter.
  ///
  /// ```dart
  /// handleChat(chat: chatObject, checkIfExists: true)
  /// ```
  static Future<void> handleChat(
      {Map<String, dynamic>? chatData, required Chat chat, bool checkIfExists = false, bool isHeadless = false}) async {
    Chat? currentChat;
    Chat? newChat = chat;
    if (chatData != null) {
      newChat = Chat.fromMap(chatData);
    }

    // If we are told to check if the chat exists, do it
    if (checkIfExists) {
      currentChat = await Chat.findOne({"guid": newChat.guid});
    }

    // Save the new chat only if current chat isn't found
    if (currentChat == null) {
      Logger.info("Chat did not exist. Saving.", tag: "Actions-HandleChat");
      await newChat.save();
    }

    // If we already have a chat, don't fetch the participants
    if (currentChat != null) return;

    // Fetch chat data from server
    try {
      newChat = await SocketManager().fetchChat(newChat.guid!);
      if (newChat == null) return;
      await ChatBloc().updateChatPosition(newChat);
    } catch (ex) {
      Logger.error(ex.toString());
    }
  }

  /// Handles the ingestion of a 'new-message' event from the server.
  /// The server will send new-message events when it detects either
  /// a new message or a "matched" message. This function will handle
  /// the ingestion of said message JSON [data], according to what is
  /// passed to it.
  ///
  /// ```dart
  /// handleMessage(JsonMap)
  /// ```
  static Future<void> handleMessage(Map<String, dynamic> data,
      {bool createAttachmentNotification = false, bool isHeadless = false, bool forceProcess = false}) async {
    Message message = Message.fromMap(data);
    List<Chat> chats = MessageHelper.parseChats(data);
    Logger.debug('[HandleMessage] Successfully mapped message (Chats: ${chats.length})', tag: 'Queue');

    // Handle message differently depending on if there is a temp GUID match
    if (data.containsKey("tempGuid")) {
      // Check if the GUID exists
      Message? existing = await Message.findOne({'guid': data['guid']});

      // If the GUID exists already, delete the temporary entry
      // Otherwise, replace the temp message
      if (existing != null) {
        Logger.info("Deleting message: [${data["text"]}] - ${data["guid"]} - ${data["tempGuid"]}",
            tag: "MessageStatus");
        await Message.delete({'guid': data['tempGuid']});
        NewMessageManager().removeMessage(chats.first, data['tempGuid']);
      } else {
        await Message.replaceMessage(data["tempGuid"], message, chat: chats.first);
        List<dynamic> attachments = data.containsKey("attachments") ? data['attachments'] : [];
        message.attachments = [];
        for (dynamic attachmentItem in attachments) {
          Attachment file = Attachment.fromMap(attachmentItem);

          try {
            await Attachment.replaceAttachment(data["tempGuid"], file);
          } catch (ex) {
            Logger.warn("Attachment's Old GUID doesn't exist. Skipping");
          }
          message.attachments.add(file);
        }
        Logger.info("Message match: [${data["text"]}] - ${data["guid"]} - ${data["tempGuid"]}", tag: "MessageStatus");

        if (!isHeadless) NewMessageManager().updateMessage(chats.first, data['tempGuid'], message);
      }
    } else if (forceProcess || !NotificationManager().hasProcessed(data["guid"])) {
      // Add the message to the chats
      for (int i = 0; i < chats.length; i++) {
        Logger.info("Client received new message " + chats[i].guid!);

        // Gets the chat from the chat bloc
        Chat? chat = await ChatBloc().getChat(chats[i].guid);
        if (chat == null) {
          await ActionHandler.handleChat(chat: chats[i], checkIfExists: true, isHeadless: isHeadless);
          chat = chats[i];
        }
        await chat.getParticipants();
        Handle? handle = chat.participants.firstWhereOrNull((e) => e.address == message.handle?.address);

        if (handle != null) {
          message.handle?.color = handle.color;
          message.handle?.defaultPhone = handle.defaultPhone;
        }

        // Handle the notification based on the message and chat
        await MessageHelper.handleNotification(message, chat);

        Logger.info("New message: [${message.text}] - [${message.guid}]", tag: "Actions-HandleMessage");
        await chat.addMessage(message);

        if (message.itemType == 2 && message.groupTitle != null) {
          chat = await chat.changeName(message.groupTitle);
          ChatBloc().updateChat(chat);
        }

        // Replace the chat with the updated chat
        chats[i] = chat;
      }

      // Add any related attachments
      List<dynamic> attachments = data.containsKey("attachments") ? data['attachments'] : [];
      for (var attachmentItem in attachments) {
        Attachment file = Attachment.fromMap(attachmentItem);
        await file.save(message);

        if ((await AttachmentHelper.canAutoDownload()) &&
            file.mimeType != null &&
            !Get.find<AttachmentDownloadService>().downloaders.contains(file.guid)) {
          Get.put(AttachmentDownloadController(attachment: file), tag: file.guid);
        }
      }

      for (Chat element in chats) {
        if (!isHeadless) NewMessageManager().addMessage(element, message);
      }
    } else if (NotificationManager().hasProcessed(data["guid"])) {
      Message? existing = await Message.findOne({'guid': data['guid']});
      if (existing != null) {
        handleUpdatedMessage(data, headless: isHeadless);
      }
    }
  }
}
