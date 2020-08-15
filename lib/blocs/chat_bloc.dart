import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/managers/contact_manager.dart';
import 'package:bluebubbles/managers/new_message_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/attachment.dart';
import 'package:bluebubbles/repository/models/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:intl/intl.dart';

import '../socket_manager.dart';
import '../repository/models/handle.dart';
import '../repository/models/chat.dart';
import '../helpers/utils.dart';

class ChatBloc {
  //Stream controller is the 'Admin' that manages
  //the state of our stream of data like adding
  //new data, change the state of the stream
  //and broadcast it to observers/subscribers
  final _chatController = StreamController<List<Chat>>.broadcast();
  final _tileValController =
      StreamController<Map<String, Map<String, dynamic>>>.broadcast();

  Stream<List<Chat>> get chatStream => _chatController.stream;
  Stream<Map<String, Map<String, dynamic>>> get tileStream =>
      _tileValController.stream;

  final _archivedChatController = StreamController<List<Chat>>.broadcast();
  Stream<List<Chat>> get archivedChatStream => _archivedChatController.stream;

  List<Chat> _chats;
  List<Chat> get chats => _chats;
  // Map<String, Map<String, dynamic>> _tileVals = new Map();
  // Map<String, Map<String, dynamic>> get tileVals => _tileVals;

  // Map<String, Map<String, dynamic>> _archivedTileVals = new Map();
  // Map<String, Map<String, dynamic>> get archivedTiles => _archivedTileVals;

  List<Chat> _archivedChats;
  List<Chat> get archivedChats => _archivedChats;

  factory ChatBloc() {
    return _chatBloc;
  }

  static final ChatBloc _chatBloc = ChatBloc._internal();

  ChatBloc._internal();

  Future<List<Chat>> getChats() async {
    debugPrint("get chats");
    //sink is a way of adding data reactively to the stream
    //by registering a new event
    await ContactManager().getContacts();

    _chats = await Chat.getChats(archived: false, limit: 10);
    _archivedChats = await Chat.getChats(archived: true);

    NewMessageManager().stream.listen((event) async {
      if ((event.containsKey("oldGuid") && event["oldGuid"] != null) ||
          event.containsKey("remove")) return;
      if (event.keys.first != null) {
        //if there even is a chat specified in the newmessagemanager update
        for (int i = 0; i < _chats.length; i++) {
          if (_chats[i].guid == event.keys.first) {
            if (event.values.first != null) {
              if (!(event.values.first as Message).isFromMe) {
                await _chats[i].markReadUnread(true);
              }
              await initTileValsForChat(
                _chats[i],
                latestMessage: event.values.first,
              );
            } else {
              await initTileValsForChat(_chats[i]);
            }
          }
        }
      } else {
        await initTileVals(_chats);
      }
      _chatController.sink.add(_chats);
    });

    await initTileVals(_chats);
    recursiveGetChats();

    // initTileVals(_chats, offset: 15);
    initTileVals(_archivedChats);

    return _chats;
  }

  void recursiveGetChats() async {
    List<Chat> newChats = await Chat.getChats(limit: 10, offset: _chats.length);
    if (newChats.length != 0) {
      _chats.addAll(newChats);
      await initTileVals(newChats);
      recursiveGetChats();
    }
  }

  Future<List<Chat>> moveChatToTop(Chat chat) async {
    for (int i = 0; i < _chats.length; i++)
      if (_chats[i].guid == chat.guid) {
        _chats.removeAt(i);
        break;
      }

    _chats.insert(0, chat);
    await initTileValsForChat(chat);
    _chatController.sink.add(_chats);
    return _chats;
  }

  Future<void> initTileVals(List<Chat> chats, [bool addToSink = true]) async {
    for (int i = 0; i < chats.length; i++) {
      await initTileValsForChat(chats[i]);
    }
    if (addToSink) _chatController.sink.add(_chats);

    // if (customMap == null) _tileValController.sink.add(_tileVals);
  }

  Future<void> initTileValsForChat(Chat chat,
      {Message latestMessage,
      Map<String, Map<String, dynamic>> customMap}) async {
    await chat.getTitle();
    Message firstMessage;
    if (latestMessage == null) {
      if (chat.latestMessageText == null) {
        List<Message> messages = await Chat.getMessages(chat, limit: 1);
        firstMessage = messages.length > 0 ? messages[0] : null;
      }
    } else {
      firstMessage = latestMessage;
    }

    if (firstMessage != null) {
      chat.latestMessageText = firstMessage.text;
      chat.latestMessageDate = firstMessage.dateCreated;
      if (firstMessage.itemType != 0)
        chat.latestMessageText = getGroupEventText(firstMessage);

      if (firstMessage.hasAttachments) {
        List<Attachment> attachments =
            await Message.getAttachments(firstMessage);
        chat.latestMessageText = "${attachments.length} Attachment" +
            (attachments.length > 1 ? "s" : "");

        // // When there is an attachment,the text length  1
        // if (chat.latestMessageText.length == 0 && attachments.length > 0) {
        //   String appDocPath = SettingsManager().appDocDir.path;
        //   String pathName =
        //       "$appDocPath/attachments/${attachments[0].guid}/${attachments[0].transferName}";

        //   if (FileSystemEntity.typeSync(pathName) !=
        //           FileSystemEntityType.notFound &&
        //       attachments[0].mimeType.startsWith("image/")) {
        //     // We need a row here so the parent honors our clipping
        //     subtitle = Container(
        //         padding: EdgeInsets.only(top: 2),
        //         child: Row(children: <Widget>[
        //           ClipRRect(
        //               borderRadius: BorderRadius.circular(4),
        //               child: Image.memory(
        //                   await FlutterImageCompress.compressWithFile(pathName,
        //                       quality: 25),
        //                   alignment: Alignment.centerLeft,
        //                   height: 38))
        //         ]));
        //   } else {}
        // }
      }
    }

    // Map<String, dynamic> chatMap = customMap != null
    //     ? customMap[chat.guid] ?? {}
    //     : _tileVals[chat.guid] ?? {};
    // chatMap["title"] = title;
    // chatMap["subtitle"] = subtitle;
    // chatMap["date"] = date;
    // chatMap["actualDate"] = firstMessage != null
    //     ? firstMessage.dateCreated.millisecondsSinceEpoch
    //     : 0;
    // bool hasNotification = false;

    // for (int i = 0; i < SocketManager().chatsWithNotifications.length; i++) {
    //   if (SocketManager().chatsWithNotifications[i] == chat.guid) {
    //     hasNotification = true;
    //     break;
    //   }
    // }

    // chatMap["hasNotification"] = hasNotification;

    // updateTileVals(chat, chatMap, customMap != null ? customMap : _tileVals);
    // if (customMap != null) _tileValController.sink.add(_tileVals);
    await chat.save();
    if (chat.title == null) await chat.getTitle();
  }

  void archiveChat(Chat chat) async {
    // chats.removeWhere((element) => element.guid == chat.guid);
    // archivedChats.add(chat);
    // initTileValsForChat(chat, customMap: _archivedTileVals);
    // if (_tileVals.containsKey(chat.guid)) _tileVals.remove(chat.guid);
    // _tileValController.sink.add(_tileVals);
    // chat.isArchived = true;
    // await chat.save(updateLocalVals: true);
  }

  void unArchiveChat(Chat chat) async {
    // archivedChats.removeWhere((element) => element.guid == chat.guid);
    // if (_archivedTileVals.containsKey(chat.guid))
    //   _archivedTileVals.remove(chat.guid);
    // _archivedChatController.sink.add(archivedChats);
    // chats.add(chat);
    // await initTileValsForChat(chat);
    // chat.isArchived = false;
    // await chat.save(updateLocalVals: true);
  }

  void updateTileVals(Chat chat, Map<String, dynamic> chatMap,
      Map<String, Map<String, dynamic>> map) {
    if (map.containsKey(chat.guid)) {
      map.remove(chat.guid);
    }
    map[chat.guid] = chatMap;
  }

  void updateChat(Chat chat) {
    for (int i = 0; i < _chats.length; i++) {
      Chat _chat = _chats[i];
      if (_chat.guid == chat.guid) {
        _chats[i] = chat;
      }
    }
  }

  addChat(Chat chat) async {
    // Create the chat in the database
    await chat.save();
    getChats();
  }

  addParticipant(Chat chat, Handle participant) async {
    // Add the participant to the chat
    await chat.addParticipant(participant);
    getChats();
  }

  removeParticipant(Chat chat, Handle participant) async {
    // Add the participant to the chat
    await chat.removeParticipant(participant);
    chat.participants.remove(participant);
    getChats();
  }

  dispose() {
    _chatController.close();
    _tileValController.close();
    _archivedChatController.close();
  }
}
