import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'server.dart'; // 引入 SharedItem 定义

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirBridge',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const FileSharePage(),
    );
  }
}

class FileSharePage extends StatefulWidget {
  const FileSharePage({super.key});

  @override
  State<FileSharePage> createState() => _FileSharePageState();
}

class _FileSharePageState extends State<FileSharePage> {
  final _server = FileTransferServer();
  
  // 使用新的 SharedItem 基类
  List<SharedItem> _selectedItems = [];
  
  String _serverUrl = "服务未启动";
  bool _isServing = false;
  bool _useShortToken = true; 
  bool _useIPv6 = false;

  Future<void> _pickFiles() async {
    await [Permission.storage, Permission.manageExternalStorage].request();
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      setState(() {
        final newFiles = result.files.map((f) => SharedFileItem(f)).toList();
        _selectedItems.addAll(newFiles);
      });
    }
  }

  // 递归构建 SharedFolderItem 树
  Future<SharedFolderItem> _scanDirectoryRecursive(Directory dir) async {
    List<SharedItem> children = [];
    String dirName = dir.path.split(Platform.pathSeparator).last;

    await for (var entity in dir.list(recursive: false, followLinks: false)) {
      String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;

      try {
        if (entity is File) {
          final platformFile = PlatformFile(
            name: name,
            size: await entity.length(),
            path: entity.path,
          );
          children.add(SharedFileItem(platformFile));
        } else if (entity is Directory) {
          SharedFolderItem subFolder = await _scanDirectoryRecursive(entity);
          children.add(subFolder);
        }
      } catch (e) {
        print("Error reading: ${entity.path}");
      }
    }
    
    children.sort((a, b) {
      if (a is SharedFolderItem && b is SharedFileItem) return -1;
      if (a is SharedFileItem && b is SharedFolderItem) return 1;
      return 0;
    });

    return SharedFolderItem(name: dirName, path: dir.path, children: children);
  }

  Future<void> _pickFolder() async {
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请在设置中开启“所有文件访问权限”以读取文件夹')));
        await openAppSettings();
        return;
      }
    }
    
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在扫描文件夹结构...')));
      
      try {
        final dir = Directory(selectedDirectory);
        final folder = await _scanDirectoryRecursive(dir);

        if (folder.children.isNotEmpty) {
          setState(() {
            _selectedItems.add(folder);
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加文件夹: ${folder.name}')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件夹是空的')));
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读取失败: $e')));
      }
    }
  }

  void _removeItem(int index) {
    setState(() {
      _selectedItems.removeAt(index);
      if (_selectedItems.isEmpty && _isServing) {
        _toggleServer(); 
      }
    });
  }

  Future<String> _getIpAddress(bool ipv6) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: ipv6 ? InternetAddressType.IPv6 : InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (var interface in interfaces) {
        if (interface.name.toLowerCase().contains('wlan') || 
            interface.name.toLowerCase().contains('eth') ||
            interface.name.toLowerCase().contains('wi-fi')) {
           for (var addr in interface.addresses) {
             return addr.address;
           }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (e) {
      print("获取 IP 失败: $e");
    }
    return ipv6 ? '::1' : '0.0.0.0';
  }

  Future<void> _toggleServer() async {
    if (_isServing) {
      await _server.stop();
      setState(() {
        _isServing = false;
        _serverUrl = "服务已停止";
      });
    } else {
      if (_selectedItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择文件')));
        return;
      }
      
      String ip = await _getIpAddress(_useIPv6);

      // 修改：直接传结构化的 items，不再扁平化
      final url = await _server.start(
        _selectedItems, 
        ip, 
        useShortToken: _useShortToken,
        useIPv6: _useIPv6
      );
      
      setState(() {
        _isServing = true;
        _serverUrl = url;
      });
    }
  }

  void _copyToClipboard() {
    if (_serverUrl.startsWith("http")) {
      Clipboard.setData(ClipboardData(text: _serverUrl));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('链接已复制')));
    }
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(children: const [Icon(Icons.rocket_launch, color: Colors.blue), SizedBox(width: 10), Text("关于 AirBridge")]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text("版本号：0.1.0", style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 10),
            Text("一个极简的端到端文件传输工具。"),
            SizedBox(height: 20),
            Text("作者：b站up主 道系青年Lee", style: TextStyle(fontSize: 13, color: Colors.purple, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("支持作者"),
          ),
        ],
      ),
    );
  }

  void _openFolderDetail(SharedFolderItem folder) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => FolderDetailPage(folder: folder)),
    ).then((_) {
      setState(() {}); 
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AirBridge', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: _showAboutDialog,
            child: const Text("关于", style: TextStyle(fontSize: 16, color: Colors.black87)),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _isServing ? Colors.blue[50] : Colors.grey[100],
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _isServing ? Colors.blue.withOpacity(0.5) : Colors.transparent),
                ),
                child: Column(
                  children: [
                    Text(_isServing ? '正在分享' : '等待启动', 
                         style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _isServing ? Colors.blue : Colors.grey)),
                    const SizedBox(height: 15),
                    SelectableText(_serverUrl, 
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, color: Colors.black87, fontWeight: FontWeight.w900, letterSpacing: 1.0)),
                    
                    if (_isServing) ...[
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                        child: QrImageView(
                          data: _serverUrl,
                          version: QrVersions.auto,
                          size: 200.0,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _copyToClipboard,
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text("复制链接"),
                      ),
                    ],
                  ],
                ),
              ),
              
              const SizedBox(height: 25),

              SwitchListTile(
                title: const Text("使用 4 位短口令"),
                subtitle: const Text("便于手动输入 (如: /8848)"),
                value: _useShortToken,
                contentPadding: EdgeInsets.zero,
                onChanged: _isServing ? null : (val) {
                  setState(() { _useShortToken = val; });
                },
              ),

              SwitchListTile(
                title: const Text("尝试使用 IPv6 (互联网传输)"),
                subtitle: const Text("需网络支持。可绕过路由器限制进行公网传输。默认关闭，只在局域网传输。"),
                value: _useIPv6,
                contentPadding: EdgeInsets.zero,
                onChanged: _isServing ? null : (val) {
                  setState(() { _useIPv6 = val; });
                },
              ),

              const Divider(),
              const SizedBox(height: 10),
              
              Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: ElevatedButton.icon(
                      onPressed: _isServing ? null : _pickFiles,
                      icon: const Icon(Icons.insert_drive_file, size: 20),
                      label: const Text('传文件', style: TextStyle(fontSize: 13)),
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: Colors.white, foregroundColor: Colors.blue, elevation: 0, side: const BorderSide(color: Colors.blue)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: ElevatedButton.icon(
                      onPressed: _isServing ? null : _pickFolder,
                      icon: const Icon(Icons.folder_open, size: 20),
                      label: const Text('传文件夹', style: TextStyle(fontSize: 13)),
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: Colors.white, foregroundColor: Colors.blue, elevation: 0, side: const BorderSide(color: Colors.blue)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1, 
                    child: ElevatedButton.icon(
                      onPressed: _toggleServer,
                      icon: Icon(_isServing ? Icons.stop : Icons.rocket_launch, size: 20),
                      label: Text(_isServing ? '停止' : '启动', style: const TextStyle(fontSize: 13)),
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: _isServing ? Colors.red[50] : Colors.blue, foregroundColor: _isServing ? Colors.red : Colors.white, elevation: _isServing ? 0 : 2),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              const Text("已选列表:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 10),
              
              Container(
                constraints: const BoxConstraints(maxHeight: 250),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[200]!),
                  borderRadius: BorderRadius.circular(8)
                ),
                child: _selectedItems.isEmpty 
                  ? const Center(child: Text("暂无内容", style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      itemCount: _selectedItems.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _selectedItems[index];
                        
                        if (item is SharedFolderItem) {
                          return ListTile(
                            leading: const Icon(Icons.folder, color: Colors.orange),
                            title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('${item.children.length} 项 · ${(item.totalSize / 1024 / 1024).toStringAsFixed(1)} MB'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                                  onPressed: () => _openFolderDetail(item),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, color: Colors.redAccent),
                                  onPressed: () => _removeItem(index),
                                ),
                              ],
                            ),
                            onTap: () => _openFolderDetail(item),
                          );
                        } 
                        
                        else if (item is SharedFileItem) {
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.file_present, color: Colors.blueGrey),
                            title: Text(item.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${(item.file.size / 1024).toStringAsFixed(1)} KB'),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, color: Colors.redAccent),
                              onPressed: () => _removeItem(index),
                            ),
                          );
                        }
                        return const SizedBox();
                      },
                    ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// 文件夹详情页
class FolderDetailPage extends StatefulWidget {
  final SharedFolderItem folder;
  const FolderDetailPage({super.key, required this.folder});

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  void _openSubFolder(SharedFolderItem subFolder) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => FolderDetailPage(folder: subFolder)),
    ).then((_) {
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folder.name)),
      body: widget.folder.children.isEmpty 
        ? const Center(child: Text("文件夹已空"))
        : ListView.separated(
            itemCount: widget.folder.children.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = widget.folder.children[index];
              
              if (item is SharedFolderItem) {
                return ListTile(
                  leading: const Icon(Icons.folder, color: Colors.orange),
                  title: Text(item.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                        onPressed: () => _openSubFolder(item),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () {
                          setState(() {
                            widget.folder.children.removeAt(index);
                          });
                        },
                      ),
                    ],
                  ),
                  onTap: () => _openSubFolder(item),
                );
              } else if (item is SharedFileItem) {
                return ListTile(
                  leading: const Icon(Icons.file_present, color: Colors.grey),
                  title: Text(item.file.name),
                  subtitle: Text('${(item.file.size / 1024).toStringAsFixed(1)} KB'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () {
                      setState(() {
                        widget.folder.children.removeAt(index);
                      });
                    },
                  ),
                );
              }
              return const SizedBox();
            },
          ),
    );
  }
}