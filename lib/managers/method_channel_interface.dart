import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:bluebubble_messages/blocs/chat_bloc.dart';
import 'package:bluebubble_messages/layouts/conversation_view/conversation_view.dart';
import 'package:bluebubble_messages/main.dart';
import 'package:bluebubble_messages/managers/notification_manager.dart';
import 'package:bluebubble_messages/managers/settings_manager.dart';
import 'package:bluebubble_messages/repository/database.dart';
import 'package:bluebubble_messages/repository/models/chat.dart';
import 'package:bluebubble_messages/repository/models/message.dart';
import 'package:bluebubble_messages/socket_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MethodChannelInterface {
  factory MethodChannelInterface() {
    return _interface;
  }

  static final MethodChannelInterface _interface =
      MethodChannelInterface._internal();

  MethodChannelInterface._internal();

  //interface with native code
  final platform = const MethodChannel('samples.flutter.dev/fcm');

  BuildContext _context;

  void init(BuildContext context) {
    platform.setMethodCallHandler(callHandler);
    _context = context;
  }

  Future invokeMethod(String method, [dynamic arguments]) async {
    return platform.invokeMethod(method, arguments);
  }

  Future<dynamic> callHandler(call) async {
    switch (call.method) {
      case "new-server":
        debugPrint("New Server: " + call.arguments.toString());
        debugPrint(call.arguments.toString().length.toString());
        SettingsManager().settings.serverAddress = call.arguments
            .toString()
            .substring(1, call.arguments.toString().length - 1);
        SettingsManager().saveSettings(SettingsManager().settings, true);
        return new Future.value("");
      case "new-message":
        Map<String, dynamic> data = jsonDecode(call.arguments);

        Chat chat = await Chat.findOne({"guid": data["chats"][0]["guid"]});
        if (chat == null) {
          debugPrint("could not find chat, returning");
          return;
        }

        String title = await chatTitle(chat);
        Message message = Message.fromMap(data);
        message = await message.save();
        if (!message.isFromMe)
          NotificationManager().createNewNotification(
              title, message.text, chat.guid, message.id);

        if (SocketManager().processedGUIDS.contains(data["guid"])) {
          debugPrint("contains guid");
          return;
        } else {
          SocketManager().processedGUIDS.add(data["guid"]);
        }
        if (data["chats"].length == 0) return new Future.value("");

        SocketManager().handleNewMessage(data, chat);
        return new Future.value("");
      case "updated-message":
        debugPrint("update message");
        return new Future.value("");
      case "ChatOpen":
        debugPrint("open chat " + call.arguments.toString());
        openChat(call.arguments);
        return new Future.value("");

      case "restart-fcm":
        debugPrint("restart fcm");
        return new Future.value("");
      case "reply":
        debugPrint("replying with data " + call.arguments.toString());
        // SocketManager().sendMessage(chat, text)
        return new Future.value("");
    }
  }

  void openChat(String id) async {
    Chat openedChat = await Chat.findOne({"GUID": id});
    if (openedChat != null) {
      String title = await chatTitle(openedChat);

      Navigator.of(_context).pushAndRemoveUntil(
        CupertinoPageRoute(
          builder: (context) => ConversationView(
            chat: openedChat,
            messageBloc: ChatBloc().tileVals[openedChat.guid]["bloc"],
            title: title,
          ),
        ),
        (route) => route.isFirst,
      );
    } else {
      debugPrint("could not find chat");
    }
  }
}