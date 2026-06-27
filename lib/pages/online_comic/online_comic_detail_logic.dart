import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';

class OnlineComicDetailLogic {
  OnlineComicDetailLogic(this.initialComic);

  final BaseComic initialComic;

  Future<Res<PicacgComicItem>> loadPicacgDetail() {
    if (initialComic is PicacgComicItem) {
      return Future.value(Res(initialComic as PicacgComicItem));
    }
    return PicacgNetwork().getComicInfo(initialComic.id);
  }

  Future<Res<bool>> toggleFavorite() {
    return PicacgNetwork().favouriteOrUnfavouriteComic(initialComic.id);
  }
}
