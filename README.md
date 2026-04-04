# LifeOS Gate

**Entegre AI Agent çalışma ortamına sahip platformlar arası SSH/SFTP istemcisi.**
**Cross-platform SSH/SFTP client with integrated AI Agent workbench.**

Flutter ile geliştirildi. Windows, Android, Linux ve macOS üzerinde çalışır.
Built with Flutter. Runs on Windows, Android, Linux, and macOS.

-----

## Özellikler / Features

### SSH Terminali / SSH Terminal

  - **Çoklu sekme SSH terminali:** PTY desteği (Windows için ConPTY, Linux/macOS için forkpty).
  - **tmux entegrasyonu:** Kalıcı oturumlar, otomatik yeniden bağlantı ve isimlendirilmiş oturumlar.
  - **Kabuk algılama:** bash, zsh, PowerShell, Git Bash ve WSL desteği.
  - **Oturum kaydı:** Terminal oturumlarını kaydetme ve zaman çizelgesi üzerinden geri oynatma.

### SFTP Sürücü ve Dosya Gezgini / SFTP Drive & Browser

  - **Uzak dizinleri yerel sürücü olarak bağlama:** (Windows: WinFsp + sshfs-win).
  - **Çift panelli dosya gezgini:** Sürükle-bırak desteği ile kolay dosya yönetimi.
  - **Dosya düzenleyici:** Satır numaralı gelişmiş dahili editör.
  - **Toplu işlem:** İlerleme takibi ile toplu yükleme ve indirme.

### AI Agent Çalışma Ortamı / AI Agent Workbench

  - **3 CLI Sağlayıcı:** Claude, Codex ve Gemini — uzak projelerde otonom AI agent'lar çalıştırın.
  - **Zengin IDE benzeri arayüz:** Genişletilebilir araç kartları, satır içi diff (fark) görünümü ve sözdizimi vurgulamalı kod blokları.
  - **Sağlayıcı izolasyonu:** Her sağlayıcı için bağımsız durum, SSH profili ve oturum geçmişi.
  - **Canlı akış (Streaming):** Araç durum göstergesiyle birlikte gerçek zamanlı token akışı.
  - **Onay modları:** Tam Erişim (Auto), Adım Adım (Confirm) ve Salt Okunur (Readonly).
  - **tmux kalıcılığı:** SSH bağlantısı kopsa bile agent komutları çalışmaya devam eder.
  - **Oturum yönetimi:** Proje başına birden fazla oturum ve kaldığı yerden devam etme desteği.
  - **Zaman aşımı kontrolü:** 3/5/10/15/30 dakikalık akış zaman aşımı ve otomatik durdurma.

### AI Sohbet Paneli / AI Chat Panel

  - **6 Farklı API sağlayıcısı:** Gemini, Claude, OpenAI, OpenRouter, Groq ve Grok (CLI değildir).
  - **Bağlam odaklı sohbet:** Geçmişi hatırlayan çok turlu konuşmalar.
  - **Komut algılama:** Metin üzerinden komut algılama ve çalıştırma.

### Sunucu İzleme / Server Monitor

  - **Gerçek zamanlı izleme:** CPU, bellek, disk ve aktif işlem (process) takibi.
  - **Arka plan sorgulama:** Ayarlanabilir aralıklarla sürekli güncel veri.

### Ek Özellikler / Additional Features

  - **SSH yapılandırma aktarımı:** `~/.ssh/config` dosyasını otomatik içeri aktarma.
  - **Görsel profiller:** Gruplandırılabilir ve renk kodlu bağlantı profilleri.
  - **Pencere efektleri:** Windows üzerinde Mica ve Acrylic şeffaflık efektleri.
  - **Dil desteği:** Tam Türkçe ve İngilizce dil desteği.
  - **Karanlık tema:** Terminal kullanımı için optimize edilmiş modern karanlık mod.

-----

## Başlangıç / Getting Started

### Ön Koşullar / Prerequisites

  - Flutter SDK (3.x+)
  - Windows için: Visual Studio (C++ desktop workload yüklü olmalı)
  - Android için: Android SDK

### Derleme ve Çalıştırma / Build & Run

```bash
# Bağımlılıkları kur
flutter pub get

# Windows üzerinde çalıştır
flutter run -d windows

# Yayına hazır sürüm derle (Release build)
flutter build windows --release
flutter build apk --release
```

### SSH Sunucu Kurulumu (AI Agent için) / SSH Server Setup

SSH sunucunuza gerekli CLI araçlarını kurun:

```bash
# Claude
npm i -g @anthropic-ai/claude-code

# Codex
npm i -g @openai/codex

# Gemini
npm i -g @google/gemini-cli
```

Her bir CLI için giriş yapın:

```bash
claude login
codex login
gemini auth login
```

-----

## Mimari / Architecture

```
lib/
  main.dart                      # Uygulama giriş noktası
  src/
    app.dart                     # Kök (Root) widget
    state/
      app_controller.dart        # Merkezi durum yönetimi (ChangeNotifier)
    models/
      connection_profile.dart    # SSH bağlantı modeli
    services/
      agent_cli_service.dart     # Agent CLI çalışma zamanı ve oturum deposu
      ai_service.dart            # AI sohbet API servisi
      server_monitor_service.dart # Sunucu metrik sorgulama servisi
    terminal/
      ssh_terminal_controller.dart # tmux destekli SSH terminali
      local_terminal_controller.dart # Yerel PTY terminali
    ui/
      home_page.dart             # Ana sekmeli düzen
      views/
        agent_workbench_view.dart # AI Agent sayfası
        dashboard_view.dart      # Sunucu paneli
        browser_view.dart        # SFTP dosya gezgini
        drives_view.dart         # Bağlantı (Mount) yöneticisi
      widgets/
        agent_diff_viewer.dart   # Düzenleme aracı için satır içi fark görüntüleyici
        connection_dialog.dart   # SSH profil editörü
        file_editor.dart         # Metin dosyası düzenleyici
    utils/
      tmux_utils.dart            # Ortak tmux yardımcı araçları
      platform_utils.dart        # Platform algılama araçları
```

-----

## Teknoloji Yığını / Tech Stack

  - **Çerçeve (Framework):** Flutter (Dart)
  - **Arayüz (UI):** Fluent UI (`fluent_ui` paketi)
  - **SSH:** `dartssh2`
  - **Terminal:** `flutter_pty` (yerel), `xterm` (görselleştirme)
  - **Durum Yönetimi:** ChangeNotifier deseni
  - **Kalıcılık (Persistence):** `path_provider` ile JSON dosyaları

-----

## Lisans / License

MIT Lisansı. Detaylar için [LICENSE](https://www.google.com/search?q=LICENSE) dosyasına bakın.
MIT License. See [LICENSE](https://www.google.com/search?q=LICENSE) for details.

-----

## Geliştirici / Author

**Erkan Öz** — [@Erkan ÖZ](https://erkanoz.com)  
**LifeOS** — [LifeOS](https://lifeos.com.tr)
