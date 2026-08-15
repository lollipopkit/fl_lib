import 'package:fl_lib/src/model/brightness_related.dart';
import 'package:flutter/material.dart';

/// Common UI constants and helpers used across widgets/pages.
abstract final class UIs {
  /// Font style

  static const text11 = TextStyle(fontSize: 11);
  static const text11Bold = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
  );
  static const text11Grey = TextStyle(color: Colors.grey, fontSize: 11);
  static const text12 = TextStyle(fontSize: 12);
  static const text12Bold = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.bold,
  );
  static const text12Grey = TextStyle(color: Colors.grey, fontSize: 12);
  static const text13 = TextStyle(fontSize: 13);
  static const text13Bold = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.bold,
  );
  static const text13Grey = TextStyle(color: Colors.grey, fontSize: 13);
  static const text15 = TextStyle(fontSize: 15);
  static const text15Bold = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.bold,
  );
  static const text18 = TextStyle(fontSize: 18);
  static const text27 = TextStyle(fontSize: 27);
  static const textGrey = TextStyle(color: Colors.grey);
  static const textRed = TextStyle(color: Colors.red);

  /// Icon

  static final appIcon = Image.asset('assets/app_icon.png');

  /// Padding

  static const roundRectCardPadding = EdgeInsets.symmetric(horizontal: 17, vertical: 13);

  /// SizedBox

  static const placeholder = SizedBox();
  static const height7 = SizedBox(height: 7);
  static const height13 = SizedBox(height: 13);
  static const height77 = SizedBox(height: 77);
  static const width7 = SizedBox(width: 7);
  static const width13 = SizedBox(width: 13);

  /// Misc

  static const popMenuChild = Padding(
    padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    child: Icon(
      Icons.more_vert,
      size: 21,
    ),
  );

  static Widget dot({Color? color, double? size}) => Container(
        width: size ?? 7,
        height: size ?? 7,
        decoration: BoxDecoration(
          color: color ?? primaryColor,
          shape: BoxShape.circle,
        ),
      );

  static const centerLoading = Padding(
    padding: EdgeInsets.symmetric(vertical: 7),
    child: Center(child: CircularProgressIndicator()),
  );

  static const smallLinearLoading = Padding(
    padding: EdgeInsets.symmetric(vertical: 17),
    child: SizedBox(
      height: 3,
      child: LinearProgressIndicator(),
    ),
  );

  /// Colors

  static var colorSeed = const Color.fromARGB(255, 72, 15, 15);

  static var primaryColor = colorSeed;

  static const halfAlpha = Color.fromARGB(37, 125, 125, 125);

  static const bgColor = DynColor(light: Colors.white, dark: Colors.black);

  static const textColor = DynColor(light: Colors.black, dark: Color.fromARGB(255, 233, 233, 233));

  /// Single column width.
  /// Used for desktop and tablet.
  static const columnWidth = 330.0;

  /// Half again [columnWidth], for content that is read rather than scanned:
  /// a form field with its description, a chart with its axis labels, a
  /// settings row with its switch. A page laid out in [columnWidth] columns
  /// makes the reader cross the screen to get through one of them.
  static const pageColumnWidth = columnWidth * 1.5;
}
