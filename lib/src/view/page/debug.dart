import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

final class DebugPageArgs {
  final String? title;

  const DebugPageArgs({
    this.title,
  });
}

class DebugPage extends StatelessWidget {
  final DebugPageArgs? args;

  const DebugPage({super.key, this.args});

  static const route = AppRoute<void, DebugPageArgs>(
    page: DebugPage.new,
    path: '/debug',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        leading: IconButton(
          onPressed: () => context.popDialog(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(args?.title ?? l10n.log, style: const TextStyle(fontSize: 17)),
        actions: [
          const Btn.icon(
            icon: Icon(Icons.copy, size: 23),
            onTap: DebugProvider.copy,
          ),
          Btn.icon(
            onTap: () {
              context.showRoundDialog(
                title: 'Clear logs?',
                actions: Btn.ok(
                  onTap: () {
                    DebugProvider.clear();
                    context.popDialog();
                  },
                ).toList,
              );
            },
            icon: const Icon(Icons.delete, size: 26),
          ),
        ],
      ),
      body: _buildTerminal(context),
    );
  }

  Widget _buildTerminal(BuildContext context) {
    return Container(
      color: Colors.black,
      child: ValBuilder(
        listenable: DebugProvider.widgets,
        builder: (widgets) {
          if (widgets.isEmpty) return UIs.placeholder;
          return ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: widgets.length,
            itemBuilder: (_, index) => widgets[index],
          );
        },
      ),
    );
  }
}
