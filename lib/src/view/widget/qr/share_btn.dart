import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

final class QrShareBtn extends StatelessWidget {
  /// The data to be encoded.
  final String data;

  /// The size of the QR code.
  final int size;

  /// Bottom tip
  final String? tip;

  /// Bottom tip (smaller)
  final String? tip2;

  /// The widget key of the QR code.
  final Key? qrKey;

  /// The center image of the QR code.
  final ImageProvider? centerImg;

  /// Shared picture's name.
  final String? sharePicName;

  const QrShareBtn({
    super.key,
    required this.data,
    this.size = 200,
    this.tip,
    this.tip2,
    this.qrKey,
    this.centerImg,
    this.sharePicName,
  });

  @override
  Widget build(BuildContext context) {
    final qrWidget = QrView(key: qrKey, data: data, size: size, tip: tip, tip2: tip2, centerImg: centerImg);

    return Btn.icon(
      icon: const Icon(Icons.share),
      onTap: () {
        context.showRoundDialog(title: libL10n.share, child: qrWidget, actions: Btnx.oks);
      },
    );
  }
}
