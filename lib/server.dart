import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive_io.dart';

// 共享基础类
abstract class SharedItem {
  final String id;
  final String name;
  SharedItem(this.name) 
      : id = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
  
  Map<String, dynamic> toJson();
}

class SharedFileItem extends SharedItem {
  final PlatformFile file;
  SharedFileItem(this.file) : super(file.name);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'file',
    'name': name,
    'size': file.size,
  };
}

class SharedFolderItem extends SharedItem {
  final String path;
  final List<SharedItem> children;
  
  SharedFolderItem({required String name, required this.path, required this.children}) : super(name);

  int get totalSize {
    int sum = 0;
    for (var item in children) {
      if (item is SharedFileItem) sum += item.file.size;
      if (item is SharedFolderItem) sum += item.totalSize;
    }
    return sum;
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'folder',
    'name': name,
    'size': totalSize,
    'children': children.map((e) => e.toJson()).toList(),
  };
}

class FileTransferServer {
  HttpServer? _server;
  List<SharedItem> _items = [];
  String _token = '';

  bool get isRunning => _server != null;

  String _generateRandomString(int length) {
    const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
    Random rnd = Random();
    return String.fromCharCodes(Iterable.generate(
        length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }

  String _getMimeType(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'bmp': return 'image/bmp';
      case 'pdf': return 'application/pdf';
      case 'mp4': return 'video/mp4';
      case 'txt': return 'text/plain';
      case 'html': return 'text/html';
      case 'json': return 'application/json';
      case 'md': return 'text/markdown';
      default: return 'application/octet-stream';
    }
  }

  SharedItem? _findItemById(List<SharedItem> list, String id) {
    for (var item in list) {
      if (item.id == id) return item;
      if (item is SharedFolderItem) {
        var found = _findItemById(item.children, id);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<String> start(List<SharedItem> selectedItems, String ip, {bool useShortToken = false, bool useIPv6 = false}) async {
    _items = selectedItems;
    
    if (useShortToken) {
      _token = (1000 + Random().nextInt(9000)).toString();
    } else {
      _token = _generateRandomString(6);
    }

    final router = Router();

    router.get('/<tokenStr>', (Request request, String tokenStr) {
      if (tokenStr != _token) return Response.forbidden('Wrong Code');
      return _handleIndex(request, tokenStr);
    });

    router.get('/<tokenStr>/api/files', (Request request, String tokenStr) {
      if (tokenStr != _token) return Response.forbidden('Wrong Code');
      return _handleFileList(request);
    });

    router.get('/<tokenStr>/download/<itemId>', (Request request, String tokenStr, String itemId) {
      if (tokenStr != _token) return Response.forbidden('Wrong Code');
      return _handleDownload(request, itemId);
    });
    
    router.get('/<tokenStr>/zip/<itemId>', (Request request, String tokenStr, String itemId) {
      if (tokenStr != _token) return Response.forbidden('Wrong Code');
      return _handleZipDownload(request, itemId);
    });

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);

    final address = useIPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4;
    _server = await shelf_io.serve(handler, address, 9000);
    
    final hostStr = useIPv6 ? '[$ip]' : ip;
    return 'http://$hostStr:9000/$_token';
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _items = [];
  }

  Response _handleIndex(Request request, String currentToken) {
    // 前端逻辑升级：支持 SPA 式文件夹导航
    final html = """
    <!DOCTYPE html>
    <html lang="zh">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>AirBridge 接收站</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; padding: 20px; background: #f2f2f7; color: #333; }
        h2 { text-align: center; color: #007bff; margin-bottom: 20px; }
        .container { max-width: 800px; margin: 0 auto; }
        
        /* 面包屑导航 */
        .breadcrumbs { padding: 10px 5px; margin-bottom: 10px; font-size: 16px; color: #666; }
        .crumb { cursor: pointer; color: #007bff; text-decoration: underline; }
        .crumb:last-child { color: #333; text-decoration: none; cursor: default; }
        .sep { margin: 0 8px; color: #ccc; }

        .file-card { background: white; padding: 16px; margin-bottom: 12px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.05); display: flex; justify-content: space-between; align-items: center; transition: background 0.2s; }
        .file-card.folder:hover { background: #f8f9fa; cursor: pointer; }
        
        .file-info { display: flex; align-items: center; overflow: hidden; flex: 1; margin-right: 10px; }
        .icon { font-size: 28px; margin-right: 15px; }
        .file-name { font-weight: 600; font-size: 16px; color: #333; }
        .file-meta { font-size: 13px; color: #888; margin-top: 4px; }
        
        .btn-group { display: flex; gap: 8px; }
        .btn { text-decoration: none; color: white; background: #007bff; padding: 8px 14px; border-radius: 20px; font-size: 13px; font-weight: 500; white-space: nowrap; border: none; cursor: pointer; }
        .btn:hover { opacity: 0.9; }
        .btn-preview { background: #28a745; } 
        .btn-zip { background: #ff9800; }
        .folder-link { color: inherit; text-decoration: none; display: flex; align-items: center; flex: 1; }
      </style>
    </head>
    <body>
      <div class="container">
        <h2>✈️ AirBridge</h2>
        <div id="breadcrumbs" class="breadcrumbs"></div>
        <div id="list">加载中...</div>
      </div>

      <script>
        const basePath = window.location.pathname;
        let rootData = [];
        let navStack = []; // 导航栈，存 folder 对象

        function formatSize(bytes) {
           if (bytes < 1024) return bytes + ' B';
           if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
           return (bytes / 1024 / 1024).toFixed(2) + ' MB';
        }

        // 初始化
        fetch(basePath + '/api/files')
          .then(res => res.json())
          .then(data => {
             rootData = data;
             renderList(rootData);
             renderBreadcrumbs();
          })
          .catch(e => {
            document.getElementById('list').innerHTML = '<p style="text-align:center;color:red">连接失败</p>';
          });

        // 渲染列表
        function renderList(items) {
           const list = document.getElementById('list');
           list.innerHTML = '';
           
           if (!items || items.length === 0) {
             list.innerHTML = '<p style="text-align:center;color:#999;padding:20px;">空文件夹</p>';
             return;
           }
           
           // 排序：文件夹在前
           const sortedItems = [...items].sort((a, b) => {
             if (a.type === 'folder' && b.type !== 'folder') return -1;
             if (a.type !== 'folder' && b.type === 'folder') return 1;
             return 0;
           });

           sortedItems.forEach(item => {
             const div = document.createElement('div');
             div.className = 'file-card' + (item.type === 'folder' ? ' folder' : '');
             
             let icon = item.type === 'folder' ? '📂' : '📄';
             let btns = '';
             let meta = formatSize(item.size);
             
             // 点击名字的动作
             let nameAction = '';

             if (item.type === 'folder') {
               // 文件夹逻辑
               const zipUrl = `\${basePath}/zip/\${item.id}`;
               btns = `<a class="btn btn-zip" href="\${zipUrl}" download="\${item.name}.zip" onclick="event.stopPropagation()">打包下载</a>`;
               meta += ` · \${item.children.length} 项`;
               
               // 点击卡片进入文件夹
               div.onclick = () => enterFolder(item);
               
             } else {
               // 文件逻辑
               const downloadUrl = `\${basePath}/download/\${item.id}`;
               const isPreviewable = /\\.(jpg|jpeg|png|gif|webp|bmp|pdf|mp4|txt|md|json)\$/i.test(item.name);
               
               btns = `<a class="btn" href="\${downloadUrl}" download="\${item.name}">下载</a>`;
               if (isPreviewable) {
                 btns = `<a class="btn btn-preview" href="\${downloadUrl}?inline=true" target="_blank">预览</a>` + btns;
               }
             }

             div.innerHTML = `
               <div class="file-info">
                 <span class="icon">\${icon}</span>
                 <div>
                   <div class="file-name">\${item.name}</div>
                   <div class="file-meta">\${meta}</div>
                 </div>
               </div> 
               <div class="btn-group">\${btns}</div>
             `;
             list.appendChild(div);
           });
        }

        // 渲染面包屑
        function renderBreadcrumbs() {
          const el = document.getElementById('breadcrumbs');
          let html = `<span class="crumb" onclick="goRoot()">首页</span>`;
          
          navStack.forEach((folder, index) => {
            html += `<span class="sep">></span>`;
            // 如果是最后一项（当前页），不可点
            if (index === navStack.length - 1) {
               html += `<span>\${folder.name}</span>`;
            } else {
               html += `<span class="crumb" onclick="goLevel(\${index})">\${folder.name}</span>`;
            }
          });
          
          el.innerHTML = html;
        }

        // 导航动作
        function enterFolder(folder) {
          navStack.push(folder);
          renderList(folder.children);
          renderBreadcrumbs();
        }

        function goRoot() {
          navStack = [];
          renderList(rootData);
          renderBreadcrumbs();
        }

        function goLevel(index) {
          // 切断 index 之后的所有层级
          navStack = navStack.slice(0, index + 1);
          const current = navStack[navStack.length - 1];
          renderList(current.children);
          renderBreadcrumbs();
        }
      </script>
    </body>
    </html>
    """;
    return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
  }

  Response _handleFileList(Request request) {
    final list = _items.map((e) => e.toJson()).toList();
    return Response.ok(jsonEncode(list), headers: {'content-type': 'application/json'});
  }

  Response _handleDownload(Request request, String itemId) {
    final item = _findItemById(_items, itemId);
    
    if (item == null || item is! SharedFileItem) {
      return Response.notFound('File not found');
    }

    final file = File(item.file.path!);
    final isInline = request.url.queryParameters['inline'] == 'true';
    
    return Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': _getMimeType(item.name),
        'Content-Disposition': isInline 
            ? 'inline; filename="${Uri.encodeComponent(item.name)}"'
            : 'attachment; filename="${Uri.encodeComponent(item.name)}"'
      }
    );
  }

  Response _handleZipDownload(Request request, String itemId) {
    final item = _findItemById(_items, itemId);
    if (item == null || item is! SharedFolderItem) {
      return Response.notFound('Folder not found');
    }

    try {
      final tempDir = Directory.systemTemp;
      final zipPath = '${tempDir.path}/${item.name}_${item.id}.zip';
      final encoder = ZipFileEncoder();
      
      encoder.create(zipPath);
      encoder.addDirectory(Directory(item.path));
      encoder.close();

      final zipFile = File(zipPath);
      
      return Response.ok(
        zipFile.openRead(),
        headers: {
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="${Uri.encodeComponent(item.name)}.zip"'
        }
      );
    } catch (e) {
      return Response.internalServerError(body: 'Zip creation failed: $e');
    }
  }
}