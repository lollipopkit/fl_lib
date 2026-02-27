// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class LibLocalizationsId extends LibLocalizations {
  LibLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get about => 'Tentang';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1 lalu $action2?';
  }

  @override
  String get add => 'Tambah';

  @override
  String get all => 'Semua';

  @override
  String get anonLoseDataTip =>
      'Saat ini masuk secara anonim, melanjutkan operasi akan mengakibatkan hilangnya data.';

  @override
  String get app => 'Aplikasi';

  @override
  String askContinue(Object msg) {
    return '$msg, lanjutkan?';
  }

  @override
  String get attention => 'Perhatian';

  @override
  String get authRequired => 'Autentikasi diperlukan';

  @override
  String get auto => 'Otomatis';

  @override
  String get background => 'Latar Belakang';

  @override
  String get backup => 'Cadangkan';

  @override
  String get bioAuth => 'Autentikasi biometrik';

  @override
  String get blurRadius => 'Radius Blur';

  @override
  String get bright => 'Terang';

  @override
  String get cancel => 'Batal';

  @override
  String get checkUpdate => 'Periksa pembaruan';

  @override
  String get clear => 'Bersihkan';

  @override
  String get click => 'Klik';

  @override
  String get clipboard => 'Papan klip';

  @override
  String get close => 'Menutup';

  @override
  String get content => 'Konten';

  @override
  String get copy => 'Salin';

  @override
  String get custom => 'Kustom';

  @override
  String get cut => 'Potong';

  @override
  String get dark => 'Gelap';

  @override
  String get day => 'Hari';

  @override
  String delFmt(Object id, Object type) {
    return 'Hapus $type ($id)?';
  }

  @override
  String get delay => 'Penundaan';

  @override
  String get delete => 'Hapus';

  @override
  String get device => 'Perangkat';

  @override
  String get disabled => 'Nonaktif';

  @override
  String get doc => 'Dokumentasi';

  @override
  String get dontShowAgain => 'Jangan tampilkan lagi';

  @override
  String get download => 'Unduh';

  @override
  String get duration => 'Durasi';

  @override
  String get edit => 'Edit';

  @override
  String get editor => 'Editor';

  @override
  String get empty => 'Kosong';

  @override
  String get error => 'Kesalahan';

  @override
  String get example => 'Contoh';

  @override
  String get execute => 'Jalankan';

  @override
  String get exit => 'Keluar';

  @override
  String get exitConfirmTip => 'Tekan Kembali sekali lagi untuk keluar';

  @override
  String get exitDirectly => 'Keluar langsung';

  @override
  String get export => 'Ekspor';

  @override
  String get fail => 'Gagal';

  @override
  String get feedback => 'Masukan';

  @override
  String get file => 'Berkas';

  @override
  String get fold => 'Lipat';

  @override
  String get folder => 'Map';

  @override
  String get font => 'Font';

  @override
  String get found => 'Ditemukan';

  @override
  String get hideTitleBar => 'Sembunyikan bilah judul';

  @override
  String get hour => 'Jam';

  @override
  String get image => 'Gambar';

  @override
  String get import => 'Impor';

  @override
  String get init => 'Inisialisasi';

  @override
  String get key => 'Kunci';

  @override
  String get language => 'Bahasa';

  @override
  String get license => 'Lisensi';

  @override
  String get log => 'Catatan';

  @override
  String get login => 'Masuk';

  @override
  String get loginTip => 'Tanpa perlu pendaftaran, gratis digunakan.';

  @override
  String get logout => 'Keluar';

  @override
  String get manual => 'Manual';

  @override
  String get migrateCfg => 'Migrasi konfigurasi';

  @override
  String get migrateCfgTip =>
      'Untuk menyesuaikan dengan konfigurasi baru yang diperlukan';

  @override
  String get minute => 'Menit';

  @override
  String get moveDown => 'Turun';

  @override
  String get moveUp => 'Naik';

  @override
  String get name => 'Nama';

  @override
  String get network => 'Jaringan';

  @override
  String get next => 'Berikutnya';

  @override
  String notExistFmt(Object file) {
    return '$file tidak ada';
  }

  @override
  String get note => 'Catatan';

  @override
  String get ok => 'OK';

  @override
  String get opacity => 'Opasitas';

  @override
  String get open => 'Buka';

  @override
  String get paste => 'Tempel';

  @override
  String get path => 'Jalur';

  @override
  String get preview => 'Pratinjau';

  @override
  String get previous => 'Sebelumnya';

  @override
  String get primaryColorSeed => 'Dasar warna utama';

  @override
  String get pwd => 'Kata sandi';

  @override
  String get pwdTip =>
      'Panjang 6-32, dapat berupa huruf bahasa Inggris, angka, dan tanda baca';

  @override
  String get redo => 'Ulangi';

  @override
  String get refresh => 'Segarkan';

  @override
  String get register => 'Daftar';

  @override
  String get rename => 'Ubah nama';

  @override
  String get replace => 'Ganti';

  @override
  String get replaceAll => 'Ganti semua';

  @override
  String get reset => 'Atur Ulang';

  @override
  String get restore => 'Pulihkan';

  @override
  String get result => 'Hasil';

  @override
  String get retry => 'Coba Lagi';

  @override
  String get save => 'Simpan';

  @override
  String get search => 'Cari';

  @override
  String get second => 'Detik';

  @override
  String get select => 'Pilih';

  @override
  String get setting => 'Pengaturan';

  @override
  String get share => 'Bagikan';

  @override
  String get size => 'Ukuran';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return 'Konten terlalu besar, hanya menampilkan $bytes pertama';
  }

  @override
  String get start => 'Mulai';

  @override
  String get stop => 'Berhenti';

  @override
  String get success => 'Sukses';

  @override
  String get switch_ => 'Saklar';

  @override
  String get switcher => 'Pengalih';

  @override
  String get sync => 'Sinkronisasi';

  @override
  String get system => 'Sistem';

  @override
  String get tag => 'Label';

  @override
  String get tapToAuth => 'Klik untuk memverifikasi';

  @override
  String get themeMode => 'Mode tema';

  @override
  String get thinking => 'Sedang berpikir';

  @override
  String get timeout => 'Waktu habis';

  @override
  String get undo => 'Batalkan';

  @override
  String get unknown => 'Tidak diketahui';

  @override
  String get unsupported => 'Tidak didukung';

  @override
  String get update => 'Perbarui';

  @override
  String get upload => 'Unggah';

  @override
  String get user => 'Username';

  @override
  String get value => 'Nilai';

  @override
  String versionHasUpdate(Object build) {
    return 'Ditemukan: v1.0.$build, klik untuk memperbarui';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return 'Versi saat ini: v1.0.$build, klik untuk memeriksa pembaruan';
  }

  @override
  String versionUpdated(Object build) {
    return 'Versi saat ini: v1.0.$build, sudah terbaru';
  }

  @override
  String get yesterday => 'Kemarin';

  @override
  String get addr => 'Alamat';

  @override
  String get available => 'Tersedia';

  @override
  String get convert => 'Konversi';

  @override
  String get experimentalFeature => 'Fitur Eksperimental';

  @override
  String get foregroundService => 'Layanan Latar Depan';

  @override
  String get goto => 'Pergi ke';

  @override
  String get invalid => 'Tidak valid';

  @override
  String get valid => 'Valid';

  @override
  String get max => 'Maksimum';

  @override
  String get min => 'Minimum';

  @override
  String get more => 'Lebih banyak';

  @override
  String get milliseconds => 'Milidetik';

  @override
  String get permission => 'Izin';

  @override
  String get read => 'Baca';

  @override
  String get write => 'Tulis';

  @override
  String get done => 'Selesai';

  @override
  String get speed => 'Kecepatan';

  @override
  String get stat => 'Statistik';

  @override
  String get time => 'Waktu';

  @override
  String get times => 'Kali';

  @override
  String get used => 'Digunakan';

  @override
  String get view => 'Lihat';

  @override
  String get askAiModel => 'Model';

  @override
  String get battery => 'Baterai';

  @override
  String get cmd => 'Memerintah';

  @override
  String get confirm => 'Confirm';

  @override
  String get conn => 'Koneksi';

  @override
  String get container => 'Wadah';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get decode => 'Membaca sandi';

  @override
  String get decompress => 'Dekompresi';

  @override
  String get disconnected => 'Terputus';

  @override
  String get disk => 'Disk';

  @override
  String get emulator => 'Emulator';

  @override
  String get encode => 'Menyandi';

  @override
  String get force => 'sukarela';

  @override
  String get host => 'Host';

  @override
  String get inner => 'Batin';

  @override
  String get install => 'Install';

  @override
  String get location => 'Lokasi';

  @override
  String get logs => 'Log';

  @override
  String get loss => 'kehilangan';

  @override
  String get menuHelp => 'Help';

  @override
  String get menuInfo => 'Info';

  @override
  String get menuNavigate => 'Navigate';

  @override
  String get menuQuit => 'Quit';

  @override
  String get menuSettings => 'Setting';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get mission => 'Misi';

  @override
  String get ms => 'MS';

  @override
  String get net => 'Jaringan';

  @override
  String get node => 'Node';

  @override
  String get notAvailable => 'Tidak tersedia';

  @override
  String get pingAvg => 'Rata -rata:';

  @override
  String get pkg => 'Pkg';

  @override
  String get port => 'Port';

  @override
  String get process => 'Proses';

  @override
  String get prune => 'Pangkas';

  @override
  String get reboot => 'Reboot';

  @override
  String get restart => 'Mengulang kembali';

  @override
  String get route => 'Routing';

  @override
  String get run => 'Berlari';

  @override
  String get running => 'berlari';

  @override
  String get saved => 'Diselamatkan';

  @override
  String get sensors => 'Sensor';

  @override
  String get sequence => 'Urutan';

  @override
  String get server => 'Server';

  @override
  String get servers => 'server';

  @override
  String get shutdown => 'Matikan';

  @override
  String get snippet => 'Snippet';

  @override
  String get stats => 'Statistik';

  @override
  String get stopped => 'dihentikan';

  @override
  String get storage => 'Penyimpanan';

  @override
  String get suspend => 'Suspend';

  @override
  String get temperature => 'Suhu';

  @override
  String get terminal => 'Terminal';

  @override
  String get test => 'pengujian';

  @override
  String get theme => 'Tema';

  @override
  String get total => 'Total';

  @override
  String get totalAttempts => 'Total';

  @override
  String get traffic => 'Lalu lintas';

  @override
  String get ttl => 'TTL';

  @override
  String get uptime => 'Uptime';
}
