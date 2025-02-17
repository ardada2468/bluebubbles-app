import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

import 'package:bluebubbles/helpers/attachment_helper.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/chat.dart';
import 'package:bluebubbles/repository/models/message.dart';
import 'package:mime_type/mime_type.dart';
import 'package:sqflite/sqflite.dart';

import '../database.dart';

Attachment attachmentFromJson(String str) {
  final jsonData = json.decode(str);
  return Attachment.fromMap(jsonData);
}

String attachmentToJson(Attachment data) {
  final dyn = data.toMap();
  return json.encode(dyn);
}

class Attachment {
  int? id;
  int? originalROWID;
  String? guid;
  String? uti;
  String? mimeType;
  String? transferState;
  bool? isOutgoing;
  String? transferName;
  int? totalBytes;
  bool? isSticker;
  bool? hideAttachment;
  String? blurhash;
  int? height;
  int? width;
  Map<String, dynamic>? metadata;
  Uint8List? bytes;
  String? webUrl;

  Attachment({
    this.id,
    this.originalROWID,
    this.guid,
    this.uti,
    this.mimeType,
    this.transferState,
    this.isOutgoing,
    this.transferName,
    this.totalBytes,
    this.isSticker,
    this.hideAttachment,
    this.blurhash,
    this.height,
    this.width,
    this.metadata,
    this.bytes,
    this.webUrl,
  });

  bool get existsOnDisk {
    if (kIsWeb) return false;
    File attachment = File(AttachmentHelper.getAttachmentPath(this));
    return attachment.existsSync();
  }

  String get orientation {
    String orientation = 'portrait'; // Default
    if (metadata == null) return orientation;
    // This key is from FlutterNativeImage
    if (metadata!.containsKey('orientation') &&
        (metadata!['orientation'].toString().toLowerCase().contains('landscape') ||
            metadata!['orientation'].toString() == '0')) {
      orientation = 'landscape';
      // This key is from the Exif loader
    } else if (metadata!.containsKey('Image Orientation') &&
        (metadata!['Image Orientation'].toString().toLowerCase().contains('horizontal') ||
            metadata!['orientation'].toString() == '0')) {
      orientation = 'landscape';
    }

    return orientation;
  }

  factory Attachment.fromMap(Map<String, dynamic> json) {
    String? mimeType = json["mimeType"];
    if ((json.containsKey("uti") && json["uti"] == "com.apple.coreaudio_format") ||
        (json.containsKey("transferName") && (json['transferName'] ?? "").endsWith(".caf"))) {
      mimeType = "audio/caf";
    }

    // Load the metadata
    dynamic metadata = json.containsKey("metadata") ? json["metadata"] : null;
    if (!isNullOrEmpty(metadata)!) {
      // If the metadata is a string, convert it to JSON
      if (metadata is String) {
        try {
          metadata = jsonDecode(metadata);
        } catch (_) {}
      }
    }

    var data = Attachment(
      id: json.containsKey("ROWID") ? json["ROWID"] : null,
      originalROWID: json.containsKey("originalROWID") ? json["originalROWID"] : null,
      guid: json["guid"],
      uti: json["uti"],
      mimeType: mimeType ?? mime(json['transferName']),
      transferState: json['transferState'].toString(),
      isOutgoing: (json["isOutgoing"] is bool) ? json['isOutgoing'] : ((json['isOutgoing'] == 1) ? true : false),
      transferName: json['transferName'],
      totalBytes: json['totalBytes'] is int ? json['totalBytes'] : 0,
      isSticker: (json["isSticker"] is bool) ? json['isSticker'] : ((json['isSticker'] == 1) ? true : false),
      hideAttachment:
          (json["hideAttachment"] is bool) ? json['hideAttachment'] : ((json['hideAttachment'] == 1) ? true : false),
      blurhash: json.containsKey("blurhash") ? json["blurhash"] : null,
      height: json.containsKey("height") ? json["height"] : 0,
      width: json.containsKey("width") ? json["width"] : 0,
      metadata: metadata is String ? null : metadata,
    );

    // Adds fallback getter for the ID
    data.id ??= json.containsKey("id") ? json["id"] : null;

    return data;
  }

  Future<Attachment> save(Message? message) async {
    final Database? db = await DBProvider.db.database;

    // Try to find an existing attachment before saving it
    Attachment? existing = await Attachment.findOne({"guid": guid});
    if (existing != null) {
      id = existing.id;
    }

    // If it already exists, update it
    if (existing == null) {
      // Remove the ID from the map for inserting
      var map = toMap();
      if (map.containsKey("ROWID")) {
        map.remove("ROWID");
      }
      if (map.containsKey("participants")) {
        map.remove("participants");
      }

      id = (await db?.insert("attachment", map)) ?? id;

      if (id != null && message!.id != null) {
        await db?.insert("attachment_message_join", {"attachmentId": id, "messageId": message.id});
      }
    }

    return this;
  }

  Future<Attachment> update() async {
    final Database? db = await DBProvider.db.database;

    Map<String, dynamic> params = {
      "width": width,
      "height": height,
      // If it's null or empty, save it as null
      "metadata": isNullOrEmpty(metadata)! ? null : jsonEncode(metadata)
    };

    if (originalROWID != null) {
      params["originalROWID"] = originalROWID;
    }

    if (id != null) {
      await db?.update("attachment", params, where: "ROWID = ?", whereArgs: [id]);
    }

    return this;
  }

  static Future<Attachment> replaceAttachment(String? oldGuid, Attachment newAttachment) async {
    final Database? db = await DBProvider.db.database;
    Attachment? existing = await Attachment.findOne({"guid": oldGuid});
    if (existing == null) {
      throw ("Old GUID does not exist!");
    }

    Map<String, dynamic> params = newAttachment.toMap();
    if (params.containsKey("ROWID")) {
      params.remove("ROWID");
    }
    if (params.containsKey("width")) {
      params.remove("width");
    }
    if (params.containsKey("height")) {
      params.remove("height");
    }
    if (params.containsKey("metadata")) {
      params.remove("metadata");
    }

    // Don't override the mimetype if it's null
    if (newAttachment.mimeType == null) {
      params.remove("mimeType");
    }

    await db?.update("attachment", params, where: "ROWID = ?", whereArgs: [existing.id]);
    String appDocPath = SettingsManager().appDocDir.path;
    String pathName = "$appDocPath/attachments/$oldGuid";
    Directory directory = Directory(pathName);
    await directory.rename("$appDocPath/attachments/${newAttachment.guid}");
    newAttachment.id = existing.id;
    newAttachment.width = existing.width;
    newAttachment.height = existing.height;
    newAttachment.metadata = existing.metadata;
    return newAttachment;
  }

  static Future<Attachment?> findOne(Map<String, dynamic> filters) async {
    final Database? db = await DBProvider.db.database;
    if (db == null) return null;
    List<String> whereParams = [];
    for (var filter in filters.keys) {
      whereParams.add('$filter = ?');
    }
    List<dynamic> whereArgs = [];
    for (var filter in filters.values) {
      whereArgs.add(filter);
    }
    var res = await db.query("attachment", where: whereParams.join(" AND "), whereArgs: whereArgs, limit: 1);

    if (res.isEmpty) {
      return null;
    }

    return Attachment.fromMap(res.elementAt(0));
  }

  static Future<List<Attachment>> find([Map<String, dynamic> filters = const {}]) async {
    final Database? db = await DBProvider.db.database;
    if (db == null) return [];
    List<String> whereParams = [];
    for (var filter in filters.keys) {
      whereParams.add('$filter = ?');
    }
    List<dynamic> whereArgs = [];
    for (var filter in filters.values) {
      whereArgs.add(filter);
    }

    var res = await db.query("attachment",
        where: (whereParams.isNotEmpty) ? whereParams.join(" AND ") : null,
        whereArgs: (whereArgs.isNotEmpty) ? whereArgs : null);
    return (res.isNotEmpty) ? res.map((c) => Attachment.fromMap(c)).toList() : [];
  }

  static flush() async {
    final Database? db = await DBProvider.db.database;
    await db?.delete("attachment");
  }

  getFriendlySize({decimals = 2}) {
    double size = ((totalBytes ?? 0) / 1024000.0);
    String postfix = "MB";
    if (size < 1) {
      size = size * 1024;
      postfix = "KB";
    } else if (size > 1024) {
      size = size / 1024;
      postfix = "GB";
    }

    return "${size.toStringAsFixed(decimals)} $postfix";
  }

  bool get hasValidSize => (width ?? 0) > 0 && (height ?? 0) > 0;

  String? get mimeStart {
    if (mimeType == null) return null;
    String _mimeType = mimeType!;
    _mimeType = _mimeType.substring(0, _mimeType.indexOf("/"));
    return _mimeType;
  }

  static Future<int?> countForChat(Chat chat) async {
    final Database? db = await DBProvider.db.database;
    if (db == null) return 0;
    if (chat.id == null) return 0;

    String query = ("SELECT"
        " count(attachment.ROWID) AS count"
        " FROM attachment"
        " JOIN attachment_message_join AS amj ON amj.attachmentId = attachment.ROWID"
        " JOIN message ON amj.messageId = message.ROWID"
        " JOIN chat_message_join AS cmj ON cmj.messageId = message.ROWID"
        " JOIN chat ON chat.ROWID = cmj.chatId"
        " WHERE chat.ROWID = ? AND attachment.mimeType IS NOT NULL");

    // Execute the query
    var res = await db.rawQuery("$query;", [chat.id]);
    if (res.isEmpty) return 0;

    return res[0]["count"] as int?;
  }

  String getPath() {
    String? fileName = transferName;
    String appDocPath = SettingsManager().appDocDir.path;
    String pathName = "$appDocPath/attachments/$guid/$fileName";
    return pathName;
  }

  String getCompressedPath() {
    return "${getPath()}.${SettingsManager().compressionQuality}.compressed";
  }

  Map<String, dynamic> toMap() => {
        "ROWID": id,
        "originalROWID": originalROWID,
        "guid": guid,
        "uti": uti,
        "mimeType": mimeType,
        "transferState": transferState,
        "isOutgoing": isOutgoing! ? 1 : 0,
        "transferName": transferName,
        "totalBytes": totalBytes,
        "isSticker": isSticker! ? 1 : 0,
        "hideAttachment": hideAttachment! ? 1 : 0,
        "blurhash": blurhash,
        "height": height,
        "width": width,
        "metadata": jsonEncode(metadata),
      };
}
