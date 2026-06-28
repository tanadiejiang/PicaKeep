import 'package:picakeep/base.dart';

/// jm 图片服务器域名，从 settings[86] 读
String get jmImgBase => appdata.settings[86];

String getJmCoverUrl(String id) => '$jmImgBase/media/albums/${id}_3x4.jpg';

String getJmImageUrl(String imageName, String chapterId) =>
    '$jmImgBase/media/photos/$chapterId/$imageName';
