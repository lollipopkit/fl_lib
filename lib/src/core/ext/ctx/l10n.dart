import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';

extension LibL10n on BuildContext {
  void setLibL10n() => l10n = LibLocalizations.of(this) ?? LibLocalizationsEn();
}

LibLocalizations get libL10n => l10n;
