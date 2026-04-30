import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';

class LocalFavoritesPage extends StatefulWidget {
  final String folderName;
  const LocalFavoritesPage({super.key, required this.folderName});

  @override
  State<LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<LocalFavoritesPage> {
  final _favManager = LocalFavoritesManager();
  List<FavoriteItem> _comics = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadComics();
  }

  Future<void> _loadComics() async {
    await _favManager.init();
    setState(() {
      _comics = _favManager.getAllComics(widget.folderName);
      _loading = false;
    });
  }

  void _removeComic(FavoriteItem comic) {
    _favManager.deleteComic(widget.folderName, comic);
    _loadComics();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              showSearch(
                context: context,
                delegate: _FavSearchDelegate(_comics),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _comics.isEmpty
              ? const Center(child: Text('暂无漫画'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.7,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _comics.length,
                  itemBuilder: (context, index) {
                    final comic = _comics[index];
                    return GestureDetector(
                      onLongPress: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('操作'),
                            content: Text(comic.name),
                            actions: [
                              TextButton(
                                  onPressed: () {
                                    _removeComic(comic);
                                    Navigator.pop(ctx);
                                  },
                                  child: const Text('删除')),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('取消'),
                              ),
                            ],
                          ),
                        );
                      },
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                child: const Center(
                                    child: Icon(Icons.book, size: 40)),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                comic.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class _FavSearchDelegate extends SearchDelegate<String> {
  final List<FavoriteItem> comics;
  _FavSearchDelegate(this.comics);

  @override
  List<Widget>? buildActions(BuildContext context) => [
        IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, ''),
      );

  @override
  Widget buildResults(BuildContext context) => _searchResults();

  @override
  Widget buildSuggestions(BuildContext context) => _searchResults();

  Widget _searchResults() {
    final q = query.toLowerCase();
    final results =
        comics.where((c) => c.name.toLowerCase().contains(q)).toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) => ListTile(
        title: Text(results[i].name),
        subtitle: Text(results[i].author),
      ),
    );
  }
}
