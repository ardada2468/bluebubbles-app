import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

class MessageTail extends StatelessWidget {
  final bool isFromMe;

  const MessageTail({ Key key, @required this.isFromMe }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: isFromMe ? AlignmentDirectional.bottomEnd : AlignmentDirectional.bottomStart,
      children: [
        Container(
          margin: EdgeInsets.only(left: 4.0, bottom: 1),
          width: 20,
          height: 15,
          decoration: BoxDecoration(
            color: isFromMe ? Theme.of(context).primaryColor : Theme.of(context).accentColor,
            borderRadius: BorderRadius.only(bottomRight: Radius.circular(12)),
          ),
        ),
        Container(
          margin: EdgeInsets.only(bottom: 2),
          height: 28,
          width: 11,
          decoration: BoxDecoration(
              color: Theme.of(context).backgroundColor,
              borderRadius: BorderRadius.only(bottomRight: Radius.circular(8))),
        ),
      ]
    );
  }
}