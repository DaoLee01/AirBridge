
# ✈️ AirBridge / 空桥

**Zero-config cross-platform LAN file transfer tool.**
**零配置、跨平台的局域网文件传输工具。**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Flutter](https://img.shields.io/badge/Mobile-Flutter-02569B?logo=flutter)
![Rust](https://img.shields.io/badge/Desktop-Rust%20%2B%20Tauri-000000?logo=rust)

AirBridge allows you to transfer files between devices (Phone to PC, PC to Phone) seamlessly over Local Area Network (LAN) without internet access. No complex setup, no server required.

AirBridge 让你可以通过局域网在设备间（手机传电脑、电脑传手机）无缝传输文件。无需联网，无需服务器，开箱即用。

---

## ✨ Features / 核心功能

### 📱 Mobile (Android)
*   **Host Mode**: Turn your phone into a file server.
*   **Folder Support**: Recursive folder selection with hierarchical view.
*   **Smart Preview**: Preview images/text directly in browser without downloading.
*   **Zip Download**: Automatically zip selected folders for the receiver.
*   **Dual Stack**: Support both IPv4 and IPv6 (experimental).

*   **主机模式**: 手机秒变文件服务器。
*   **文件夹支持**: 支持递归选择文件夹，保持层级结构。
*   **智能预览**: 浏览器端可直接预览图片、文本，无需下载。
*   **打包下载**: 对方下载文件夹时，服务器自动打包成 Zip。
*   **双栈支持**: 同时支持 IPv4 和 IPv6 传输。

### 💻 Desktop (Windows)
*   **Built with Rust**: Ultra-lightweight (~5MB), high performance.
*   **No Install**: Portable executable, uses system WebView2.
*   **Port Hunting**: Automatically finds available ports (9000-9010).
*   **Firewall Fix**: One-click fix for Windows Firewall issues.
*   **Full Parity**: Matches all mobile features (Folder tree, Zip stream, Preview).

*   **Rust 构建**: 极致轻量（约 5MB），高性能。
*   **免安装**: 绿色单文件，利用系统 WebView2，无运行时依赖。
*   **端口避让**: 启动时自动寻找空闲端口 (9000-9010)。
*   **一键修复**: 内置防火墙规则一键添加功能，解决连接问题。
*   **功能对齐**: 完美复刻移动端功能（树形目录、流式压缩、在线预览）。

---

## 🚀 Getting Started / 快速开始

### 1. Android
1.  Open app, click **"Pick Files"** or **"Pick Folder"**.
2.  Click **"Start Sharing"**.
3.  Scan the QR code with another device to download.

1.  打开 App，点击 **“传文件”** 或 **“传文件夹”**。
2.  点击 **“启动分享”**。
3.  用另一台设备扫描二维码即可下载。

### 2. Windows
1.  Run `air_bridge_desktop.exe`.
2.  Select files/folders and click **"Start Server"**.
3.  **Note**: If connection fails, click **"Fix Firewall Rules"** at the bottom.

1.  运行 `air_bridge_desktop.exe`。
2.  选择文件/文件夹，点击 **“启动服务”**。
3.  **注意**：如果手机连不上，请点击软件底部的 **“一键修复防火墙规则”**。

---

## 🛠️ Build from Source / 源码编译

This project uses a **Monorepo** structure.
本项目采用单体仓库结构。

### Android (Flutter)
Path: `lib/`
```bash
flutter pub get
flutter run
# Build Release
flutter build apk --split-per-abi --target-platform android-arm64
```

### Windows (Rust + Tauri)
Path: `air_bridge_desktop/`
**Requirements**: Rust (MinGW toolchain recommended), Tauri CLI.
**依赖**: Rust (推荐 MinGW 工具链), Tauri CLI。

```bash
cd air_bridge_desktop

# 1. Run in dev mode
cargo run

# 2. Build Release EXE
# Note: Ensure icons/icon.ico exists
cargo build --release
```

---

## 📝 Technical Details / 技术细节

*   **Backend**: 
    *   **Dart (Shelf)** for Android.
    *   **Rust (Axum)** for Windows.
*   **Frontend (Web Client)**: 
    *   Pure HTML/JS/CSS embedded in the binary.
    *   SPA (Single Page Application) style folder navigation.
*   **Protocol**: Standard HTTP. No proprietary protocols.

*   **后端**: Android 端使用 Dart (Shelf)，Windows 端使用 Rust (Axum)。
*   **前端 (Web)**: 纯 HTML/JS/CSS 嵌入在二进制文件中，无外部依赖。支持 SPA 风格的文件夹导航。
*   **协议**: 标准 HTTP 协议，通用性强。

---

## ☕ Support Me (请我喝咖啡)

If this app helps you become a better version of yourself, you can buy me a coffee to keep my keyboard firing!  
如果这个 App 帮到了你，或者你喜欢我的开发理念，欢迎打赏支持，让我的AI运行速度更快一点！

<p align="center">
  <img src="static/reward.jpg" width="200" alt="Alipay Reward Code" />
</p>


> **Note**: This is purely voluntary. The App will always be free and open source.  
> **注**：打赏纯属自愿。App 永远免费开源，绝无付费墙。


---

## ⚖️ License (开源协议)

**GNU General Public License v3.0 (GPL-3.0)**

You are free to use, modify, and distribute this software, BUT you must comply with the following conditions:
您可以自由使用、修改和分发本软件，但必须遵守以下条件：

1.  **Open Source (必须开源)**: If you modify this code and release it, your version **MUST also be open source** under GPL-3.0. (如果您修改代码并发布，您的版本也必须开源)
2.  **Attribution (署名)**: You must clearly state the original author is **"b站up主 道系青年Lee"**. (必须保留原作者署名)
3.  **No Commercial Use (严禁商用)**: This project is for educational and personal use only. Selling this App or embedding ads is strictly prohibited. (严禁将本项目打包收费或植入广告牟利)

---

## 🤝 Contributing / 贡献

Created by **道系青年Lee** .
Feel free to submit Issues or Pull Requests.

作者：**b站up主 道系青年Lee**。
欢迎提交 Issue 或 PR。


<p align="center">
  Made with AI by <a href="https://space.bilibili.com/437113079">道系青年Lee</a>

</p>

---

**Enjoy your wireless life! ✈️**