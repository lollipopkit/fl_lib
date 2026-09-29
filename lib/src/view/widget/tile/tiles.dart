import 'package:fl_lib/src/model/rnode.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';

final class DontShowAgainTile extends StatelessWidget {
  const DontShowAgainTile({
    super.key,
    required this.val,
  });

  final VNode<bool> val;

  @override
  Widget build(BuildContext context) {
    return val.listenVal((v) {
      return CheckboxListTile(
        title: Text(l10n.dontShowAgain),
        value: v,
        onChanged: (_) {
          val.value = !v;
        },
      );
    });
  }
}
