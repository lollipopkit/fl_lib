import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'preview/adaptive_reorderable_list_page.dart';
import 'preview/intro_page.dart';
import 'preview/file_page.dart';
import 'preview/search_page.dart';
import 'preview/image_page.dart';
import 'preview/loading_widget.dart';
import 'preview/color_picker_widget.dart';
import 'preview/error_widget.dart';
import 'preview/custom_appbar_page.dart';
import 'preview/editor_code_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fl_lib demo',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    final previews = [
      _PreviewEntry('Debug Page', const DebugPage()),
      _PreviewEntry('Intro Page', const PreviewIntroPage()),
      _PreviewEntry('File Page', const PreviewFilePage()),
      _PreviewEntry('Bio Auth Page', const LocalAuthPage()),
      _PreviewEntry('Search Page', const PreviewSearchPage()),
      _PreviewEntry('Image Page', const PreviewImagePage()),
      _PreviewEntry('Scan Page', const BarcodeScannerPage()),
      _PreviewEntry('Editor Code Page', const PreviewEditorCodePage()),
      _PreviewEntry('Editor Plain Page', const PlainEditPage()),
      _PreviewEntry(
        'Editor KV Page',
        const KvEditor(args: KvEditorArgs(data: {})),
      ),
      _PreviewEntry('Loading Widget', const PreviewLoadingWidget()),
      _PreviewEntry('Color Picker Widget', const PreviewColorPickerWidget()),
      _PreviewEntry('Error Widget', const PreviewErrorWidget()),
      _PreviewEntry('Custom App Bar Page', const PreviewCustomAppBarPage()),
      _PreviewEntry(
        'Adaptive Reorderable Waterfall',
        const AdaptiveReorderableListPage(),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('fl_lib demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        scrolledUnderElevation: 0,
      ),
      body: ListView.builder(
        itemCount: previews.length,
        itemBuilder: (context, index) {
          final entry = previews[index];
          return ListTile(
            title: Text(entry.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => entry.page),
            ),
          );
        },
      ),
    );
  }
}

class _PreviewEntry {
  final String title;
  final Widget page;
  const _PreviewEntry(this.title, this.page);
}
