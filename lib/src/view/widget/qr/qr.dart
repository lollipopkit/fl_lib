import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

export 'package:pretty_qr_code/pretty_qr_code.dart' show QrErrorCorrectLevel;

final class QrView extends StatelessWidget {
  final String data;
  final int size;

  /// Bottom tip
  final String? tip;

  /// Bottom tip (smaller)
  final String? tip2;

  final ImageProvider? centerImg;

  /// One of [QrErrorCorrectLevel].
  ///
  /// M is right for a code that will be printed, photographed or stuck on
  /// something. [QrErrorCorrectLevel.L] is worth asking for when the payload
  /// is long and the code is shown on a screen and read in the same room: it
  /// takes the symbol down a version or two, and what decides whether such a
  /// code can be read is how many camera pixels land on a module, not how much
  /// damage the symbol can survive.
  final int errorCorrectLevel;

  const QrView({
    super.key,
    required this.data,
    this.size = 200,
    this.tip,
    this.tip2,
    this.centerImg,
    this.errorCorrectLevel = QrErrorCorrectLevel.M,
  });

  @override
  Widget build(BuildContext context) {
    const qrForegroundColor = Colors.black;
    final qrImg = QrImage(QrCode.fromData(
      data: data,
      errorCorrectLevel: errorCorrectLevel,
    ));
    final qrDecoration = PrettyQrDecoration(
      background: Colors.white,
      shape: const PrettyQrSmoothSymbol(
        roundFactor: 1,
        color: qrForegroundColor,
      ),
      image:
          centerImg != null ? PrettyQrDecorationImage(image: centerImg!) : null,
    );
    Widget qrWidget = PrettyQrView(qrImage: qrImg, decoration: qrDecoration);
    qrWidget = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        qrWidget,
        UIs.height13,
        if (tip != null)
          Text(
            tip!,
            style: const TextStyle(
              color: qrForegroundColor,
              fontSize: 17,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
          ),
        if (tip2 != null) const SizedBox(height: 1),
        if (tip2 != null)
          Text(
            tip2!,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 13,
            ),
            maxLines: 3,
          ),
      ],
    );
    return Container(
      decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(17)),
          color: Colors.white),
      padding: EdgeInsets.only(
        left: 17,
        top: 17,
        right: 17,
        bottom: tip != null ? 10 : 17,
      ),
      child: qrWidget,
    );
  }
}
