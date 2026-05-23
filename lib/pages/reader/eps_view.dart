part of pica_reader;

class EpsView extends StatefulWidget {
  const EpsView(this.data, {Key? key}) : super(key: key);
  final ReadingData data;

  @override
  State<EpsView> createState() => _EpsViewState();
}

class _EpsViewState extends State<EpsView> {
  var controller = ItemScrollController();
  var logic = StateController.find<ComicReadingPageLogic>();
  var value = false;

  @override
  Widget build(BuildContext context) {
    var data = widget.data;
    var epsWidgets = <Widget>[];
    for (int index = 0; index < data.eps!.length; index++) {
      String title = data.eps!.values.elementAt(index);
      epsWidgets.add(InkWell(
        onTap: () {
          unawaited(App.maybePopActiveRoute(context: context));
          logic.jumpToChapter(index + 1);
        },
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              const SizedBox(
                width: 16,
              ),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.clip,
                ),
              ),
              if (data.downloadedEps.contains(index))
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: const BorderRadius.all(Radius.circular(5)),
                  ),
                  margin: const EdgeInsets.all(5),
                  padding: const EdgeInsets.fromLTRB(5, 2, 5, 2),
                  child: Text(
                    "已下载".tl,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              if (logic.order == index + 1)
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: const BorderRadius.all(Radius.circular(5)),
                  ),
                  margin: const EdgeInsets.all(5),
                  padding: const EdgeInsets.fromLTRB(5, 2, 5, 2),
                  child: Text(
                    "当前".tl,
                    style: const TextStyle(fontSize: 14),
                  ),
                )
            ],
          ),
        ),
      ));
    }

    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final screenBasedHeight = MediaQuery.of(context).size.height * 0.46;
    final maxContentHeight = 340.0 + bottomPadding;
    final sheetHeight = screenBasedHeight < maxContentHeight
        ? screenBasedHeight
        : maxContentHeight;

    return SizedBox(
      height: sheetHeight,
      width: double.infinity,
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(
                  Icons.format_list_numbered,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Text("章节".tl, style: const TextStyle(fontSize: 18)),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.my_location_outlined,
                    color: Theme.of(context).colorScheme.secondary,
                    size: 23,
                  ),
                  onPressed: () {
                    final length = data.eps!.length;
                    if (!value) {
                      controller.jumpTo(index: logic.order - 1);
                    } else {
                      controller.jumpTo(index: length - logic.order);
                    }
                  },
                ),
                Text(" 倒序".tl),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: value,
                    onChanged: (b) => setState(() {
                      value = !value;
                    }),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ScrollablePositionedList.builder(
              initialScrollIndex: logic.order - 1,
              itemCount: data.eps!.length,
              itemBuilder: (context, index) {
                if (value) {
                  return epsWidgets[epsWidgets.length - index - 1];
                } else {
                  return epsWidgets[index];
                }
              },
              scrollController: ScrollController(),
              itemScrollController: controller,
            ),
          ),
          SizedBox(height: bottomPadding),
        ],
      ),
    );
  }
}
