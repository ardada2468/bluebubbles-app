import 'dart:async';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:assorted_layout_widgets/assorted_layout_widgets.dart';
import 'package:bluebubbles/blocs/chat_bloc.dart';
import 'package:bluebubbles/helpers/constants.dart';
import 'package:bluebubbles/helpers/hex_color.dart';
import 'package:bluebubbles/helpers/indicator.dart';
import 'package:bluebubbles/helpers/logger.dart';
import 'package:bluebubbles/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/message_marker.dart';
import 'package:bluebubbles/helpers/navigator.dart';
import 'package:bluebubbles/helpers/socket_singletons.dart';
import 'package:bluebubbles/helpers/ui_helpers.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/layouts/conversation_view/conversation_view.dart';
import 'package:bluebubbles/layouts/widgets/contact_avatar_group_widget.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/typing_indicator.dart';
import 'package:bluebubbles/layouts/widgets/theme_switcher/theme_switcher.dart';
import 'package:bluebubbles/managers/current_chat.dart';
import 'package:bluebubbles/managers/event_dispatcher.dart';
import 'package:bluebubbles/managers/new_message_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/chat.dart';
import 'package:bluebubbles/repository/models/handle.dart';
import 'package:bluebubbles/repository/models/message.dart';
import 'package:bluebubbles/repository/models/platform_file.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:universal_html/html.dart' as html;

class ConversationTile extends StatefulWidget {
  final Chat chat;
  final List<PlatformFile> existingAttachments;
  final String? existingText;
  final Function(bool)? onSelect;
  final bool inSelectMode;
  final List<Chat> selected;
  final Widget? subtitle;

  ConversationTile({
    Key? key,
    required this.chat,
    this.existingAttachments = const [],
    this.existingText,
    this.onSelect,
    this.inSelectMode = false,
    this.selected = const [],
    this.subtitle,
  }) : super(key: key);

  @override
  _ConversationTileState createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  // Typing indicator
  bool showTypingIndicator = false;
  bool shouldHighlight = false;

  bool get selected {
    if (widget.selected.isEmpty) return false;
    return widget.selected.where((element) => widget.chat.guid == element.guid).isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    // Listen for changes in the group
    NewMessageManager().stream.listen((NewMessageEvent event) async {
      // Make sure we have the required data to qualify for this tile
      if (event.chatGuid != widget.chat.guid) return;
      if (!event.event.containsKey("message")) return;
      if (widget.chat.guid == null) return;
      // Make sure the message is a group event
      Message message = event.event["message"];
      if (!message.isGroupEvent()) return;

      // If it's a group event, let's fetch the new information and save it
      try {
        await fetchChatSingleton(widget.chat.guid!);
      } catch (ex) {
        Logger.error(ex.toString());
      }

      setNewChatData(forceUpdate: true);
    });

    //Lister got new messages.
    EventDispatcher().stream.listen((Map<String, dynamic> event) {
      if (!event.containsKey("type")) return;

      if (event["type"] == 'update-highlight' && mounted && (kIsWeb || kIsDesktop)) {
        if (event['data'] == widget.chat.guid) {
          setState(() {
            shouldHighlight = true;
          });
        } else if (shouldHighlight = true) {
          setState(() {
            shouldHighlight = false;
          });
        }
      }
    });
  }

  void update() {
    setState(() {});
  }

  void setNewChatData({forceUpdate = false}) async {
    // Save the current participant list and get the latest
    List<Handle> ogParticipants = widget.chat.participants;
    await widget.chat.getParticipants();

    // Save the current title and generate the new one
    String? ogTitle = widget.chat.title;
    await widget.chat.getTitle();

    // If the original data is different, update the state
    if (ogTitle != widget.chat.title || ogParticipants.length != widget.chat.participants.length || forceUpdate) {
      if (mounted) setState(() {});
    }
  }

  void onTapUp(details) {
    if (widget.inSelectMode && widget.onSelect != null) {
      onSelect();
    } else {
      CustomNavigator.pushAndRemoveUntil(
        context,
        ConversationView(
          chat: widget.chat,
          existingAttachments: widget.existingAttachments,
          existingText: widget.existingText,
        ),
        (route) => route.isFirst,
      );
    }
  }

  void onTapUpBypass() {
    onTapUp(TapUpDetails(kind: PointerDeviceKind.touch));
  }

  Widget buildSlider(Widget child) {
    if (kIsWeb || kIsDesktop) return child;
    return Obx(() => Slidable(
          actionPane: SlidableStrechActionPane(),
          actionExtentRatio: 0.2,
          actions: [
            if (SettingsManager().settings.iosShowPin.value)
              IconSlideAction(
                caption: widget.chat.isPinned! ? 'Unpin' : 'Pin',
                color: Colors.yellow[800],
                foregroundColor: Colors.white,
                icon: widget.chat.isPinned! ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
                onTap: () async {
                  await widget.chat.togglePin(!widget.chat.isPinned!);
                  EventDispatcher().emit("refresh", null);
                  if (mounted) setState(() {});
                },
              ),
          ],
          secondaryActions: <Widget>[
            if (!widget.chat.isArchived! && SettingsManager().settings.iosShowAlert.value)
              IconSlideAction(
                caption: widget.chat.muteType == "mute" ? 'Show Alerts' : 'Hide Alerts',
                color: Colors.purple[700],
                icon: widget.chat.muteType == "mute" ? CupertinoIcons.bell : CupertinoIcons.bell_slash,
                onTap: () async {
                  await widget.chat.toggleMute(widget.chat.muteType != "mute");
                  if (mounted) setState(() {});
                },
              ),
            if (SettingsManager().settings.iosShowDelete.value)
              IconSlideAction(
                caption: "Delete",
                color: Colors.red,
                icon: CupertinoIcons.trash,
                onTap: () async {
                  ChatBloc().deleteChat(widget.chat);
                  Chat.deleteChat(widget.chat);
                },
              ),
            if (SettingsManager().settings.iosShowMarkRead.value)
              IconSlideAction(
                caption: widget.chat.hasUnreadMessage! ? 'Mark Read' : 'Mark Unread',
                color: Colors.blue,
                icon: widget.chat.hasUnreadMessage!
                    ? CupertinoIcons.person_crop_circle_badge_checkmark
                    : CupertinoIcons.person_crop_circle_badge_exclam,
                onTap: () {
                  ChatBloc().toggleChatUnread(widget.chat, !widget.chat.hasUnreadMessage!);
                },
              ),
            if (SettingsManager().settings.iosShowArchive.value)
              IconSlideAction(
                caption: widget.chat.isArchived! ? 'UnArchive' : 'Archive',
                color: widget.chat.isArchived! ? Colors.blue : Colors.red,
                icon: widget.chat.isArchived! ? CupertinoIcons.tray_arrow_up : CupertinoIcons.tray_arrow_down,
                onTap: () {
                  if (widget.chat.isArchived!) {
                    ChatBloc().unArchiveChat(widget.chat);
                  } else {
                    ChatBloc().archiveChat(widget.chat);
                  }
                },
              ),
          ],
          child: child,
        ));
  }

  Future<String?> getOrUpdateChatTitle() async {
    if (widget.chat.title != null) {
      return widget.chat.title;
    } else {
      return widget.chat.getTitle();
    }
  }

  Widget buildTitle() {
    final hideInfo = SettingsManager().settings.redactedMode.value && SettingsManager().settings.hideContactInfo.value;
    final generateNames =
        SettingsManager().settings.redactedMode.value && SettingsManager().settings.generateFakeContactNames.value;

    TextStyle? style = Theme.of(context).textTheme.bodyText1;
    return FutureBuilder<String?>(
        future: getOrUpdateChatTitle(),
        builder: (context, snapshot) {
          String? title = snapshot.data ?? "";
          if (generateNames) {
            title = widget.chat.fakeParticipants.length == 1 ? widget.chat.fakeParticipants[0] : "Group Chat";
          } else if (hideInfo) {
            style = style?.copyWith(color: Colors.transparent);
          }
          return TextOneLine(title ?? 'Fake Person', style: style, overflow: TextOverflow.ellipsis);
        }
    );
  }

  Widget buildSubtitle() {
    return FutureBuilder<String>(
      initialData: widget.chat.latestMessageText,
      future: widget.chat.latestMessage != null
          ? MessageHelper.getNotificationText(widget.chat.latestMessage!)
          : Future.value(widget.chat.latestMessageText ?? ""),
      builder: (BuildContext context, AsyncSnapshot snapshot) {
        String latestText = snapshot.data ?? "";
        return Obx(
          () {
            final hideContent =
                SettingsManager().settings.redactedMode.value && SettingsManager().settings.hideMessageContent.value;
            final generateContent = SettingsManager().settings.redactedMode.value &&
                SettingsManager().settings.generateFakeMessageContent.value;

            TextStyle style = Theme.of(context).textTheme.subtitle1!.apply(
                  color: Theme.of(context).textTheme.subtitle1!.color!.withOpacity(
                        0.85,
                      ),
                );

            if (generateContent) {
              latestText = widget.chat.fakeLatestMessageText ?? "";
            } else if (hideContent) {
              style = style.copyWith(color: Colors.transparent);
            }

            return RichText(
              text: TextSpan(
                children: MessageHelper.buildEmojiText(
                  latestText,
                  style,
                )
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            );
          },
        );
      },
    );
  }

  Widget buildLeading() {
    return StreamBuilder<Map<String, dynamic>>(
        stream: CurrentChat.getCurrentChat(widget.chat)?.stream as Stream<Map<String, dynamic>>?,
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.connectionState == ConnectionState.active &&
              snapshot.hasData &&
              snapshot.data["type"] == CurrentChatEvent.TypingStatus) {
            showTypingIndicator = snapshot.data["data"];
          }
          double height = Theme.of(context).textTheme.subtitle1!.fontSize! * 1.25;
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.only(top: 2, right: 2),
                child: !selected
                    ? ContactAvatarGroupWidget(
                        chat: widget.chat,
                        size: 40,
                        editable: false,
                        onTap: onTapUpBypass,
                      )
                    : Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          color: Theme.of(context).primaryColor,
                        ),
                        width: 40,
                        height: 40,
                        child: Center(
                          child: Icon(
                            Icons.check,
                            color: Theme.of(context).textTheme.bodyText1!.color,
                            size: 20,
                          ),
                        ),
                      ),
              ),
              if (showTypingIndicator)
                Positioned(
                  top: 30,
                  left: 20,
                  height: height,
                  child: FittedBox(
                    alignment: Alignment.centerLeft,
                    child: TypingIndicator(
                      chatList: true,
                      visible: true,
                    ),
                  ),
                ),
            ],
          );
        });
  }

  Widget _buildDate() => kIsWeb
      ? Text(buildDate(widget.chat.latestMessageDate),
          textAlign: TextAlign.right,
          style: Theme.of(context).textTheme.subtitle2!.copyWith(
                color: Theme.of(context).textTheme.subtitle2!.color!.withOpacity(0.85),
              ),
          overflow: TextOverflow.clip)
      : ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 100.0),
          child: FutureBuilder<Message>(
            initialData: widget.chat.latestMessage,
            future: widget.chat.latestMessageFuture,
            builder: (BuildContext builder, AsyncSnapshot snapshot) {
              return Obx(
                () {
                  Message? message = snapshot.data;
                  MessageMarkers? markers =
                      CurrentChat.getCurrentChat(widget.chat)?.messageMarkers.markers.value ?? null.obs.value;
                  Indicator show = shouldShow(
                      message, markers?.myLastMessage, markers?.lastReadMessage, markers?.lastDeliveredMessage);
                  if (message != null) {
                    return Text(
                        message.error.value > 0
                            ? "Error"
                            : ((show == Indicator.READ
                                    ? "Read\n"
                                    : show == Indicator.DELIVERED
                                        ? "Delivered\n"
                                        : show == Indicator.SENT
                                            ? "Sent\n"
                                            : "") +
                                buildDate(widget.chat.latestMessageDate)),
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.subtitle2!.copyWith(
                              color: message.error.value > 0
                                  ? Colors.red
                                  : Theme.of(context).textTheme.subtitle2!.color!.withOpacity(0.85),
                            ),
                        overflow: TextOverflow.clip);
                  }
                  return Text(buildDate(widget.chat.latestMessageDate),
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.subtitle2!.copyWith(
                            color: Theme.of(context).textTheme.subtitle2!.color!.withOpacity(0.85),
                          ),
                      overflow: TextOverflow.clip);
                },
              );
            },
          ),
        );

  void onTap() {
    CustomNavigator.pushAndRemoveUntil(
      context,
      ConversationView(
        chat: widget.chat,
        existingAttachments: widget.existingAttachments,
        existingText: widget.existingText,
      ),
      (route) => route.isFirst,
    );
  }

  void onSelect() {
    if (widget.onSelect != null) {
      widget.onSelect!(!selected);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeSwitcher(
      iOSSkin: _Cupertino(
        parent: this,
        parentProps: widget,
      ),
      materialSkin: _Material(
        parent: this,
        parentProps: widget,
      ),
      samsungSkin: _Samsung(
        parent: this,
        parentProps: widget,
      ),
    );
  }
}

class _Cupertino extends StatelessWidget {
  _Cupertino({Key? key, required this.parent, required this.parentProps}) : super(key: key);
  final _ConversationTileState parent;
  final ConversationTile parentProps;

  @override
  Widget build(BuildContext context) {
    return parent.buildSlider(
      Material(
        color: parent.shouldHighlight && (kIsWeb || kIsDesktop) ? Theme.of(context).primaryColor.withAlpha(120) : Theme.of(context).backgroundColor,
        borderRadius: BorderRadius.circular(parent.shouldHighlight ? 5 : 0),
        child: GestureDetector(
          onTapUp: (details) {
            parent.onTapUp(details);
          },
          onSecondaryTapUp: (details) async {
            if (kIsWeb) {
              (await html.document.onContextMenu.first).preventDefault();
            }
            parent.shouldHighlight = true;
            parent.update();
            await showConversationTileMenu(
              context,
              this,
              parent.widget.chat,
              details.globalPosition,
              context.textTheme,
            );
            parent.shouldHighlight = false;
            parent.update();
          },
          onLongPress: () async {
            HapticFeedback.mediumImpact();
            await ChatBloc().toggleChatUnread(parent.widget.chat, !parent.widget.chat.hasUnreadMessage!);
            if (parent.mounted) parent.update();
          },
          child: Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(left: 20.0),
                child: Obx(
                  () => Container(
                    decoration: BoxDecoration(
                      border: (!SettingsManager().settings.hideDividers.value)
                          ? Border(
                              bottom: BorderSide(
                                color: Theme.of(context).dividerColor,
                                width: 0.5,
                              ),
                            )
                          : null,
                    ),
                    child: ListTile(
                      dense: SettingsManager().settings.denseChatTiles.value,
                      contentPadding: EdgeInsets.only(left: 0),
                      minVerticalPadding: 10,
                      title: parent.buildTitle(),
                      subtitle: parent.widget.subtitle ?? parent.buildSubtitle(),
                      leading: parent.buildLeading(),
                      trailing: Container(
                        padding: EdgeInsets.only(right: 8),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: <Widget>[
                              Container(
                                padding: EdgeInsets.only(right: 3),
                                child: parent._buildDate(),
                              ),
                              Icon(
                                SettingsManager().settings.skin.value == Skins.iOS
                                    ? CupertinoIcons.forward
                                    : Icons.arrow_forward,
                                color: Theme.of(context).textTheme.subtitle1!.color,
                                size: 15,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6.0),
                child: Container(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: [
                          (parent.widget.chat.muteType != "mute" && parent.widget.chat.hasUnreadMessage!)
                              ? Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(35),
                                    color: Theme.of(context).primaryColor.withOpacity(0.8),
                                  ),
                                  width: 10,
                                  height: 10,
                                )
                              : Container(),
                          parent.widget.chat.isPinned!
                              ? Icon(
                                  CupertinoIcons.pin,
                                  size: 10,
                                  color: Colors
                                      .yellow[AdaptiveTheme.of(context).mode == AdaptiveThemeMode.dark ? 100 : 700],
                                )
                              : Container(),
                        ],
                      ),
                      parent.widget.chat.muteType == "mute"
                          ? SvgPicture.asset(
                              "assets/icon/moon.svg",
                              color: parentProps.chat.hasUnreadMessage!
                                  ? Theme.of(context).primaryColor.withOpacity(0.8)
                                  : Theme.of(context).textTheme.subtitle1!.color,
                              width: 10,
                              height: 10,
                            )
                          : Container()
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Material extends StatelessWidget {
  const _Material({Key? key, required this.parent, required this.parentProps}) : super(key: key);
  final _ConversationTileState parent;
  final ConversationTile parentProps;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: parent.shouldHighlight && (kIsWeb || kIsDesktop) ? Theme.of(context).backgroundColor.lightenOrDarken(20) : parent.selected ? Theme.of(context).primaryColor.withAlpha(120) : Theme.of(context).backgroundColor,
      child: GestureDetector(
        onSecondaryTapUp: (details) async {
          if (kIsWeb) {
            (await html.document.onContextMenu.first).preventDefault();
          }
          parent.shouldHighlight = true;
          parent.update();
          await showConversationTileMenu(
            context,
            this,
            parent.widget.chat,
            details.globalPosition,
            context.textTheme,
          );
          parent.shouldHighlight = false;
          parent.update();
        },
        child: InkWell(
          onTap: () {
            if (parent.selected) {
              parent.onSelect();
              HapticFeedback.lightImpact();
            } else if (parent.widget.inSelectMode) {
              parent.onSelect();
              HapticFeedback.lightImpact();
            } else {
              parent.onTap();
            }
          },
          onLongPress: () {
            parent.onSelect();
          },
          child: Obx(
            () => Container(
              decoration: BoxDecoration(
                border: (!SettingsManager().settings.hideDividers.value)
                    ? Border(
                        top: BorderSide(
                          color: Theme.of(context).dividerColor,
                          width: 0.5,
                        ),
                      )
                    : null,
              ),
              child: ListTile(
                dense: SettingsManager().settings.denseChatTiles.value,
                title: parent.buildTitle(),
                subtitle: parent.widget.subtitle ?? parent.buildSubtitle(),
                minVerticalPadding: 10,
                leading: Stack(
                  alignment: Alignment.topRight,
                  children: [
                    parent.buildLeading(),
                    if (parent.widget.chat.muteType != "mute")
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: parent.widget.chat.hasUnreadMessage!
                              ? Theme.of(context).primaryColor
                              : Colors.transparent,
                        ),
                      ),
                  ],
                ),
                trailing: Container(
                  padding: EdgeInsets.only(right: 3),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        if (parent.widget.chat.isPinned!) Icon(Icons.star, size: 15, color: Colors.yellow),
                        if (parent.widget.chat.muteType == "mute")
                          Icon(
                            Icons.notifications_off,
                            color: parent.widget.chat.hasUnreadMessage!
                                ? Theme.of(context).primaryColor.withOpacity(0.8)
                                : Theme.of(context).textTheme.subtitle1!.color,
                            size: 15,
                          ),
                        Container(
                          padding: EdgeInsets.only(right: 2, left: 2),
                          child: parent._buildDate(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Samsung extends StatelessWidget {
  const _Samsung({Key? key, required this.parent, required this.parentProps}) : super(key: key);
  final _ConversationTileState parent;
  final ConversationTile parentProps;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: parent.shouldHighlight && (kIsWeb || kIsDesktop) ? Theme.of(context).backgroundColor.lightenOrDarken(20) : parent.selected ? Theme.of(context).primaryColor.withAlpha(120) : Colors.transparent,
      child: GestureDetector(
        onSecondaryTapUp: (details) async {
          if (kIsWeb) {
            (await html.document.onContextMenu.first).preventDefault();
          }
          parent.shouldHighlight = true;
          parent.update();
          await showConversationTileMenu(
            context,
            this,
            parent.widget.chat,
            details.globalPosition,
            context.textTheme,
          );
          parent.shouldHighlight = false;
          parent.update();
        },
        child: InkWell(
          onTap: () {
            if (parent.selected) {
              parent.onSelect();
              HapticFeedback.lightImpact();
            } else if (parent.widget.inSelectMode) {
              parent.onSelect();
              HapticFeedback.lightImpact();
            } else {
              parent.onTap();
            }
          },
          onLongPress: () {
            parent.onSelect();
          },
          child: Obx(
            () => Container(
              decoration: BoxDecoration(
                border: (!SettingsManager().settings.hideDividers.value)
                    ? Border(
                        top: BorderSide(
                          color: Color(0xff2F2F2F),
                          width: 0.5,
                        ),
                      )
                    : null,
              ),
              child: ListTile(
                dense: SettingsManager().settings.denseChatTiles.value,
                title: parent.buildTitle(),
                subtitle: parent.widget.subtitle ?? parent.buildSubtitle(),
                minVerticalPadding: 10,
                leading: Stack(
                  alignment: Alignment.topRight,
                  children: [
                    parent.buildLeading(),
                    if (parent.widget.chat.muteType != "mute")
                      Container(
                        width: 15,
                        height: 15,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          color: parent.widget.chat.hasUnreadMessage!
                              ? Theme.of(context).primaryColor
                              : Colors.transparent,
                        ),
                      ),
                  ],
                ),
                trailing: Container(
                  padding: EdgeInsets.only(right: 3),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        if (parent.widget.chat.isPinned!) Icon(Icons.star, size: 15, color: Colors.yellow),
                        if (parent.widget.chat.muteType == "mute")
                          Icon(
                            Icons.notifications_off,
                            color: Theme.of(context).textTheme.subtitle1!.color,
                            size: 15,
                          ),
                        Container(
                          padding: EdgeInsets.only(right: 2, left: 2),
                          child: parent._buildDate(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
