import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root); final String root;
  @override Future<String?> getApplicationSupportPath() async=>root;
  @override Future<String?> getApplicationCachePath() async=>p.join(root,'cache');
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('queue freezes folder, filename and operation identity, and restores both same-work destinations',() async {
    if(Platform.isWindows){open.overrideFor(OperatingSystem.windows,()=>DynamicLibrary.open(p.join(Directory.current.path,'windows','sqlite3.dll')));}
    final workspace=await Directory.systemTemp.createTemp('pk46_queue_');
    final provider=PathProviderPlatform.instance;final saved=List<String>.from(appdata.settings);
    PathProviderPlatform.instance=_Paths(workspace.path);
    await App.init(dataPathOverride:p.join(workspace.path,'app'));
    final library=PixivLibrary(p.join(workspace.path,'pixiv'));await library.initialize();
    final a=await library.createFolder('A'),b=await library.createFolder('B');
    final manager=OnlineDownloadManager.instance;manager.pauseAll();
    const info=PixivComicInfo(id:'42',title:'Title',author:'Author',authorId:'1',coverUrl:'',tags:[],description:'',pageCount:2,illustType:0,likeCount:0,viewCount:0,width:12,height:18,isOriginal:true,createDate:'',uploadDate:'',userId:'1');
    try {
      appdata.settings[pixivDirNameTemplateSettingIndex]='{title}-{id}';
      await manager.enqueuePixiv(info,target:a);
      final first=manager.tasks.single;
      await manager.enqueuePixiv(info,target:a);
      expect(manager.tasks.length,1);
      appdata.settings[pixivDirNameTemplateSettingIndex]='{author}';
      await library.setDefault(b.id);
      await manager.enqueuePixiv(info,target:b);
      expect(manager.tasks.length,2);
      expect(manager.tasks.map((t)=>t.id).toSet().length,2);
      expect(first.pixivBaseName,'Title-42');
      expect(first.pixivTarget!['folderId'],a.id);
      final queue=File(p.join(workspace.path,'download','download_queue.json'));
      final payload=jsonDecode(await queue.readAsString()) as List;
      expect(payload.length,2);
      expect((payload.first as Map)['target'],first.pixivTarget);
      final originalIds=manager.tasks.map((t)=>t.id).toSet();
      await manager.loadQueue();
      expect(manager.tasks.map((t)=>t.id).toSet(),originalIds);
      expect(manager.tasks.every((t)=>t.paused),isTrue);
      expect(manager.tasks.first.pixivBaseName,'Title-42');
      expect(manager.tasks.last.pixivBaseName,'Author');
      expect(manager.isDownloading('pixiv42'),isTrue);
    } finally {
      appdata.settings..clear()..addAll(saved);PathProviderPlatform.instance=provider;
      PixivLibrary.hasPendingDownloads=null;
      await workspace.delete(recursive:true);
    }
  });
}
