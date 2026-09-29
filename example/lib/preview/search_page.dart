import 'package:material_ui/material_ui.dart';
import 'package:fl_lib/fl_lib.dart';

class PreviewSearchPage extends StatelessWidget {
  const PreviewSearchPage({super.key});

  static const List<String> _data = [
    'Apple',
    'Banana',
    'Orange',
    'Grape',
    'Pineapple',
    'Watermelon',
    'Strawberry',
    'Blueberry',
    'Mango',
    'Peach',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(title: const Text('SearchPage Preview')),
      body: Center(
        child: ElevatedButton(
          child: const Text('Open String Search'),
          onPressed: () async {
            final result = await showSearch<String>(
              context: context,
              delegate: SearchPage<String>(
                future: (query) async {
                  await Future.delayed(const Duration(milliseconds: 300));
                  if (query.isEmpty) return _data;
                  return _data.where((e) => e.contains(query)).toList();
                },
                builder: (context, item) => ListTile(
                  title: Text(item),
                  onTap: () => Navigator.of(context).pop(item),
                ),
              ),
            );
            if (context.mounted && result != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('You selected: $result')),
              );
            }
          },
        ),
      ),
    );
  }
}
