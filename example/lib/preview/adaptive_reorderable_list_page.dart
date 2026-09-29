import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

class AdaptiveReorderableListPage extends StatefulWidget {
  const AdaptiveReorderableListPage({super.key});

  @override
  State<AdaptiveReorderableListPage> createState() =>
      _AdaptiveReorderableListPageState();
}

class _AdaptiveReorderableListPageState
    extends State<AdaptiveReorderableListPage> {
  static const _minHeight = 180.0;
  static const _maxHeight = 270.0;

  final math.Random _random = math.Random(4);
  late List<_DemoTile> _tiles;
  bool _dimDraggedTile = true;

  @override
  void initState() {
    super.initState();
    _tiles = List.generate(
      16,
      (index) => _DemoTile(index: index, height: _nextHeight()),
    )..shuffle(_random);
  }

  double _nextHeight() =>
      _minHeight + _random.nextDouble() * (_maxHeight - _minHeight);

  void _shuffleHeights() {
    setState(() {
      for (final tile in _tiles) {
        tile.height = _nextHeight();
      }
    });
  }

  void _addTile() {
    setState(() {
      final nextIndex = _tiles.isEmpty
          ? 0
          : _tiles.map((tile) => tile.index).reduce(math.max) + 1;
      _tiles.insert(0, _DemoTile(index: nextIndex, height: _nextHeight()));
    });
  }

  void _removeTile() {
    if (_tiles.length <= 2) {
      return;
    }
    setState(() {
      _tiles.removeAt(_random.nextInt(_tiles.length));
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final tile = _tiles.removeAt(oldIndex);
      _tiles.insert(newIndex, tile);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adaptive Reorderable Waterfall'),
        scrolledUnderElevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _addTile,
                  icon: const Icon(Icons.add),
                  label: const Text('Add tile'),
                ),
                FilledButton.icon(
                  onPressed: _removeTile,
                  icon: const Icon(Icons.remove),
                  label: const Text('Remove random'),
                ),
                FilledButton.icon(
                  onPressed: _shuffleHeights,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Shuffle heights'),
                ),
                FilterChip(
                  selected: _dimDraggedTile,
                  showCheckmark: false,
                  avatar: Icon(
                    _dimDraggedTile ? Icons.visibility : Icons.visibility_off,
                  ),
                  label: const Text('Dim while dragging'),
                  onSelected: (value) =>
                      setState(() => _dimDraggedTile = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: AdaptiveReorderableList.builder(
              draggingChildOpacity: _dimDraggedTile ? 0.2 : 1.0,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              items: _tiles,
              columnWidth: 170,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              itemKey: (tile) => tile.index,
              onReorder: _onReorder,
              itemBuilder: (context, tile, index, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: _WaterfallCard(tile: tile, index: index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DemoTile {
  _DemoTile({required this.index, required this.height});

  final int index;
  double height;

  Color get color => Colors.primaries[index % Colors.primaries.length];
}

class _WaterfallCard extends StatelessWidget {
  const _WaterfallCard({required this.tile, required this.index});

  final _DemoTile tile;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOut,
      height: tile.height,
      decoration: BoxDecoration(
        color: tile.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: tile.color.withValues(alpha: 0.45),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Card ${tile.index}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Icon(Icons.drag_indicator),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Text(
              'Drag to reorder. Tile keeps dynamic height (${tile.height.toStringAsFixed(0)}px).',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Align(alignment: Alignment.bottomRight, child: Text('Index $index')),
        ],
      ),
    );
  }
}
