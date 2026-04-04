enum AppLocale { tr, en }

class AppStrings {
  const AppStrings(this.locale);

  final AppLocale locale;

  bool get isTr => locale == AppLocale.tr;

  String get appTitle => 'LifeOS Gate';
  String get profileName => isTr ? 'Profil adı' : 'Profile name';
  String get browser => isTr ? 'Dosya Yöneticisi' : 'File Manager';
  String get profiles => isTr ? 'Profiller' : 'Profiles';
  String get settings => isTr ? 'Ayarlar' : 'Settings';
  String get logs => isTr ? 'Kayıtlar' : 'Logs';
  String get newConnection => isTr ? 'Yeni Sunucu' : 'New Host';
  String get mountAll => isTr ? 'Tümünü Bağla' : 'Mount All';
  String get unmountAll => isTr ? 'Tümünü Ayır' : 'Unmount All';
  String get search => isTr ? 'Ara' : 'Search';
  String get filter => isTr ? 'Filtre' : 'Filter';
  String get all => isTr ? 'Tümü' : 'All';
  String get mounted => isTr ? 'Bağlı' : 'Mounted';
  String get inactive => isTr ? 'Pasif' : 'Inactive';
  String get noMatchingConnection => isTr
      ? 'Arama ölçütüne uyan profil yok'
      : 'No profiles match the current filter';
  String get selectConnection => isTr ? 'Bir profil seçin' : 'Select a profile';
  String get host => 'Host';
  String get port => 'Port';
  String get username => isTr ? 'Kullanıcı adı' : 'Username';
  String get password => isTr ? 'Parola' : 'Password';
  String get remotePath => isTr ? 'Uzak yol' : 'Remote path';
  String get driveLetter => isTr ? 'Sürücü harfi' : 'Drive letter';
  String get save => isTr ? 'Kaydet' : 'Save';
  String get update => isTr ? 'Güncelle' : 'Update';
  String get cancel => isTr ? 'İptal' : 'Cancel';
  String get connect => isTr ? 'Bağlan' : 'Connect';
  String get refresh => isTr ? 'Yenile' : 'Refresh';
  String get goUp => isTr ? 'Yukarı' : 'Up';
  String get copyToOtherSide =>
      isTr ? 'Diğer tarafa kopyala' : 'Copy to other side';
  String get copyLeftToRight =>
      isTr ? 'Soldan sağa kopyala' : 'Copy left to right';
  String get copyRightToLeft =>
      isTr ? 'Sağdan sola kopyala' : 'Copy right to left';
  String get notConnected => isTr ? 'Bağlı değil' : 'Not connected';
  String get connecting => isTr ? 'Bağlanıyor' : 'Connecting';
  String get connectionError => isTr ? 'Bağlantı hatası' : 'Connection error';
  String get transferError => isTr ? 'Aktarım hatası' : 'Transfer error';
  String get mountAsDrive => isTr ? 'Sürücü olarak bağla' : 'Mount as drive';
  String get unmountDrive => isTr ? 'Sürücüyü ayır' : 'Unmount drive';
  String get language => isTr ? 'Dil' : 'Language';
  String get turkish => isTr ? 'Türkçe' : 'Turkish';
  String get english => isTr ? 'İngilizce' : 'English';
  String get desktopBehavior =>
      isTr ? 'Masaüstü davranışı' : 'Desktop behavior';
  String get hideToTrayOnClose =>
      isTr ? 'Kapatınca tepsiye gizle' : 'Hide to tray on close';
  String get launchAtStartup =>
      isTr ? 'Başlangıçta çalıştır' : 'Launch at startup';
  String get clear => isTr ? 'Temizle' : 'Clear';
  String get noLogEntries => isTr ? 'Henüz kayıt yok' : 'No log entries yet';
  String get leftServer => isTr ? 'Sol sunucu' : 'Left server';
  String get rightServer => isTr ? 'Sağ sunucu' : 'Right server';
  String get currentPath => isTr ? 'Mevcut yol' : 'Current path';
  String get transfer => isTr ? 'Aktar' : 'Transfer';
  String get transferBetweenServers =>
      isTr ? 'Sunucular arası kopyala' : 'Copy between servers';
  String get browserHint => isTr
      ? 'İki farklı sunucu arasında dosya aktarımı'
      : 'Transfer files between two servers';
  String get startupPlaceholder => isTr
      ? 'Başlangıç kaydı henüz yerel olarak tamamlanmadı.'
      : 'Startup registration is not implemented natively yet.';
  String get localAndMountedHint => isTr
      ? 'Bağlanan sürücüler Windows Gezgini içinde görünür.'
      : 'Mounted drives appear in Windows Explorer.';
  String get privateKey => isTr ? 'Özel anahtar' : 'Private key';
  String get optionalField => isTr ? 'İsteğe bağlı' : 'Optional';
  String get requiredField =>
      isTr ? 'Bu alan zorunlu' : 'This field is required';
  String get invalidPort =>
      isTr ? '1 ile 65535 arasında olmalı' : 'Must be between 1 and 65535';
  String get createFirstProfile => isTr
      ? 'Başlamak için bir profil oluşturun.'
      : 'Create a profile to get started.';
  String get chooseProfileToBrowse => isTr
      ? 'Sunucuya bağlanmak için profil seçin.'
      : 'Choose a profile to connect.';
  String get emptyFolder => isTr ? 'Bu klasör boş' : 'This folder is empty';
  String get authenticationHint => isTr
      ? 'Parola veya özel anahtar bilgisi ekleyin.'
      : 'Add a password or private key.';
  String get statusSaved => isTr ? 'Kayıtlı' : 'Saved';
  String get statusWindowsDrives =>
      isTr ? 'Windows sürücüleri' : 'Windows drives';
  String get statusReady => isTr ? 'Hazır' : 'Ready';
  String get mountStatusTitle => isTr ? 'Sürücü durumu' : 'Drive status';
  String get mountDependenciesMissingError => isTr
      ? 'SSHFS-Win veya WinFsp bulunamadı. Windows sürücüsü bağlamak için her ikisi de kurulu olmalı.'
      : 'SSHFS-Win or WinFsp is missing. Both are required to mount a Windows drive.';
  String get missingCredentialsError => isTr
      ? 'Bu profil için parola ya da özel anahtar tanımlı değil.'
      : 'No password or private key is configured for this profile.';
  String privateKeyNotFoundError(String path) => isTr
      ? 'Özel anahtar dosyası bulunamadı: $path'
      : 'Private key file was not found: $path';
  String get invalidPrivateKeyError => isTr
      ? 'Özel anahtar okunamadı. Anahtar biçimini kontrol edin.'
      : 'The private key could not be read. Check the key format.';
  String authenticationFailedError(String name) => isTr
      ? '$name için kimlik doğrulama başarısız. Kullanıcı adı, parola veya anahtar bilgisini kontrol edin.'
      : 'Authentication failed for $name. Check the username, password, or key.';
  String hostUnreachableError(String host, int port) => isTr
      ? '$host:$port adresine ulaşılamadı. Sunucu, port ve ağ erişimini kontrol edin.'
      : 'Could not reach $host:$port. Check the server, port, and network access.';
  String unexpectedSftpError(String details) => isTr
      ? 'SFTP işlemi tamamlanamadı. $details'
      : 'The SFTP operation could not be completed. $details';
  String unexpectedMountError(String details) => isTr
      ? 'Sürücü bağlama işlemi tamamlanamadı. $details'
      : 'The drive mount operation could not be completed. $details';
  String mountCredentialsInvalidError(String name) => isTr
      ? '$name için kimlik bilgileri geçersiz. Parolayı veya anahtar yapılandırmasını kontrol edin.'
      : 'Credentials for $name are invalid. Check the password or key configuration.';
  String mountCancelledError(String name) => isTr
      ? '$name sürücüsü bağlanırken işlem iptal edildi.'
      : 'Mounting $name was cancelled.';
  String mountConflictError(String name) => isTr
      ? '$name için mevcut oturum başka kimlik bilgileri kullanıyor. Önce aynı sunucuya ait eski bağlantıları kapatın.'
      : 'An existing session for $name is using different credentials. Disconnect the old connection first.';
  String mountPathUnavailableError(String name) => isTr
      ? '$name için uzak yol erişilebilir değil. Host, port ve uzak yolu kontrol edin.'
      : 'The remote path for $name is unavailable. Check the host, port, and remote path.';
  String driveLetterUnknownError(String name) => isTr
      ? '$name sürücüsünü ayırmak için sürücü harfi bilinmiyor.'
      : 'The drive letter for $name is unknown, so it cannot be unmounted.';
  String mountedSuccess(String name, String driveLetter) => isTr
      ? '$name, $driveLetter: sürücüsü olarak bağlandı.'
      : '$name was mounted as drive $driveLetter:.';
  String unmountedSuccess(String name) =>
      isTr ? '$name sürücüsü ayrıldı.' : '$name was unmounted.';
  String copiedToRight(String name) => isTr
      ? '$name sağ sunucuya kopyalandı.'
      : '$name was copied to the right server.';
  String copiedToLeft(String name) => isTr
      ? '$name sol sunucuya kopyalandı.'
      : '$name was copied to the left server.';
  String get vaults => isTr ? 'Sunucular' : 'Vaults';
  String get terminal => 'Terminal';
  String get hosts => isTr ? 'Sunucular' : 'Hosts';
  String get keychain => isTr ? 'Anahtar Deposu' : 'Keychain';
  String get portForwarding => isTr ? 'Port Yönlendirme' : 'Port Forwarding';
  String get snippets => isTr ? 'Kod Parçaları' : 'Snippets';
  String get knownHosts => isTr ? 'Bilinen Hostlar' : 'Known Hosts';
  String get hostDetails => isTr ? 'Sunucu Detayları' : 'Host Details';
  String get terminalSearchHint => isTr ? 'Terminalde ara' : 'Search terminal';
  String get hostSearchPlaceholder => isTr
      ? 'Host veya kullanıcı ara...'
      : 'Find a host or ssh user@hostname...';
  String get openTerminal => isTr ? 'Terminal' : 'Terminal';
  String get openSftp => isTr ? 'SFTP' : 'SFTP';
  String get saveProfile => isTr ? 'Profili Kaydet' : 'Save Profile';
  String get noHostsYet => isTr
      ? 'Henüz host eklenmedi. Başlamak için yeni profil oluşturun.'
      : 'No hosts yet. Create a profile to get started.';
  String get terminalStarting =>
      isTr ? 'Terminal bağlanıyor...' : 'Starting terminal...';
  String terminalConnected(String name) =>
      isTr ? '$name terminali hazır.' : '$name terminal is ready.';
  String terminalDisconnected(String name) => isTr
      ? '$name terminal oturumu kapandı.'
      : '$name terminal session closed.';
  String terminalConnectionFailed(String name) => isTr
      ? '$name terminaline bağlanılamadı.'
      : 'Could not connect to $name terminal.';
  String get createTerminalTabHint => isTr
      ? 'Bir host seçip terminal veya SFTP oturumu açın.'
      : 'Select a host to open a terminal or SFTP session.';
  String get notImplementedYet =>
      isTr ? 'Bu bölüm yakında eklenecek.' : 'This section is coming soon.';
  String get localFiles => isTr ? 'Yerel Dosyalar' : 'Local Files';
  String get sessionActions => isTr ? 'Oturum İşlemleri' : 'Session Actions';
  String get connectAction => isTr ? 'Bağlan' : 'Connect';
  String get browseAction => isTr ? 'Göz at' : 'Browse';
  String get mountAction => isTr ? 'Sürücü Bağla' : 'Mount Drive';
  String get utilityPanel => isTr ? 'Yardımcı Panel' : 'Utility Panel';

  // ─── Dashboard / Monitor ──────────────────────────────────────
  String get overview => isTr ? 'Genel Bakış' : 'Overview';
  String get services => isTr ? 'Servisler' : 'Services';
  String get firewall => isTr ? 'Güvenlik Duvarı' : 'Firewall';
  String get dashLogs => isTr ? 'Günlükler' : 'Logs';
  String get cron => 'Cron';
  String get users => isTr ? 'Kullanıcılar' : 'Users';
  String get network => isTr ? 'Ağ' : 'Network';
  String get packages => isTr ? 'Paketler' : 'Packages';
  String get docker => 'Docker';
  String get database => isTr ? 'Veritabanı' : 'Database';
  String get backup => isTr ? 'Yedekleme' : 'Backup';
  String get cpu => 'CPU';
  String get memory => isTr ? 'Bellek' : 'Memory';
  String get disk => isTr ? 'Disk' : 'Disk';
  String get disks => isTr ? 'Diskler' : 'Disks';
  String get processes => isTr ? 'İşlemler' : 'Processes';
  String get containers => isTr ? 'Konteynerler' : 'Containers';
  String get loading => isTr ? 'Yükleniyor...' : 'Loading...';
  String get selectServer => isTr ? 'Sunucu Seçin' : 'Select Server';
  String get start => isTr ? 'Başlat' : 'Start';
  String get stop => isTr ? 'Durdur' : 'Stop';
  String get restart => isTr ? 'Yeniden Başlat' : 'Restart';
  String get enable => isTr ? 'Etkinleştir' : 'Enable';
  String get disable => isTr ? 'Devre Dışı' : 'Disable';
  String get running => isTr ? 'Çalışıyor' : 'Running';
  String get stopped => isTr ? 'Durdu' : 'Stopped';
  String get firewallStatus => isTr ? 'Firewall Durumu' : 'Firewall Status';
  String get disconnectServer => isTr ? 'Bağlantıyı Kes' : 'Disconnect';
  String get connectedTo => isTr ? 'Bağlı:' : 'Connected:';
  String get allServers => isTr ? 'Tüm Sunucular' : 'All Servers';
  String get alarmThreshold => isTr ? 'Alarm Eşiği' : 'Alarm Threshold';
  String get images => isTr ? 'İmajlar' : 'Images';
  String get volumes => isTr ? 'Bölümler' : 'Volumes';
  String get databases => isTr ? 'Veritabanları' : 'Databases';
  String get tables => isTr ? 'Tablolar' : 'Tables';
  String get backupNow => isTr ? 'Şimdi Yedekle' : 'Backup Now';
  String get restoreBackup => isTr ? 'Geri Yükle' : 'Restore';
  String get scheduled => isTr ? 'Zamanlı' : 'Scheduled';
  String get noData => isTr ? 'Veri yok' : 'No data';
  String get confirm => isTr ? 'Onayla' : 'Confirm';
  String get areYouSure => isTr ? 'Emin misiniz?' : 'Are you sure?';
  String get operationSuccess => isTr ? 'İşlem başarılı' : 'Operation successful';
  String get operationFailed => isTr ? 'İşlem başarısız' : 'Operation failed';
}
