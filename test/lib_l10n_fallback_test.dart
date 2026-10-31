import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('context.libL10n is English for a locale this lib lacks',
      (tester) async {
    late String empty;
    await tester.pumpWidget(Localizations(
      // An app may support a language before this lib does; its delegate is
      // then not loaded, and `LibLocalizations.of` is null.
      locale: const Locale('sw'),
      delegates: const [
        LibLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      child: Builder(builder: (context) {
        empty = context.libL10n.empty;
        return const SizedBox();
      }),
    ));
    expect(empty, LibLocalizationsEn().empty);
  });
}
