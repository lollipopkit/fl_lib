import 'package:material_ui/material_ui.dart';
import 'package:fl_lib/fl_lib.dart';

class PreviewCustomAppBarPage extends StatefulWidget {
  const PreviewCustomAppBarPage({super.key});

  @override
  State<PreviewCustomAppBarPage> createState() => _PreviewCustomAppBarPageState();
}

class _PreviewCustomAppBarPageState extends State<PreviewCustomAppBarPage> {
  bool centerTitle = true;
  bool showLeading = false;
  bool showActions = false;
  bool useCustomBg = false;
  bool showBottom = false;

  double scrolledUnderElevation = 0;
  double surfaceTintAlpha = 0;
  String titleText = 'CustomAppBar';

  Color backgroundColor = Colors.deepPurple;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        title: Text(titleText),
        centerTitle: centerTitle,
        leading: showLeading ? IconButton(icon: const Icon(Icons.menu), onPressed: () {}) : null,
        actions: showActions
            ? [
                IconButton(icon: const Icon(Icons.search), onPressed: () {}),
                IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
              ]
            : null,
        backgroundColor: useCustomBg ? backgroundColor : null,
        bottom: showBottom
            ? PreferredSize(
                preferredSize: const Size.fromHeight(30),
                child: Container(
                  height: 30,
                  color: Colors.purple[100],
                  alignment: Alignment.center,
                  child: const Text('Bottom Widget'),
                ),
              )
            : null,
        scrolledUnderElevation: scrolledUnderElevation,
        surfaceTintColor: Colors.black.withValues(alpha: surfaceTintAlpha),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            decoration: const InputDecoration(labelText: 'Title'),
            controller: TextEditingController(text: titleText),
            onChanged: (v) => setState(() => titleText = v),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Center Title'),
            value: centerTitle,
            onChanged: (v) => setState(() => centerTitle = v),
          ),
          SwitchListTile(
            title: const Text('Show leading'),
            value: showLeading,
            onChanged: (v) => setState(() => showLeading = v),
          ),
          SwitchListTile(
            title: const Text('Show actions'),
            value: showActions,
            onChanged: (v) => setState(() => showActions = v),
          ),
          SwitchListTile(
            title: const Text('Custom backgroundColor'),
            value: useCustomBg,
            onChanged: (v) => setState(() => useCustomBg = v),
          ),
          SwitchListTile(
            title: const Text('Show bottom widget'),
            value: showBottom,
            onChanged: (v) => setState(() => showBottom = v),
          ),
          const SizedBox(height: 20),
          Text('Scrolled Under Elevation: ${scrolledUnderElevation.toStringAsFixed(1)}'),
          Slider(
            min: 0,
            max: 16,
            divisions: 16,
            value: scrolledUnderElevation,
            label: scrolledUnderElevation.toStringAsFixed(1),
            onChanged: (v) => setState(() => scrolledUnderElevation = v),
          ),
          const SizedBox(height: 12),
          Text('Surface Tint Opacity: ${(surfaceTintAlpha * 100).toInt()}%'),
          Slider(
            min: 0,
            max: 1,
            divisions: 20,
            value: surfaceTintAlpha,
            label: '${(surfaceTintAlpha * 100).toInt()}%',
            onChanged: (v) => setState(() => surfaceTintAlpha = v),
          ),
          SizedBox(height: 200),
        ],
      ),
    );
  }
}
