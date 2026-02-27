// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class LibLocalizationsJa extends LibLocalizations {
  LibLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get about => 'について';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1した後、$action2しますか？';
  }

  @override
  String get add => '追加';

  @override
  String get all => '全て';

  @override
  String get anonLoseDataTip => '現在匿名でログイン中です。操作を続けるとデータが失われます。';

  @override
  String get app => 'アプリケーション';

  @override
  String askContinue(Object msg) {
    return '$msg。続行しますか？';
  }

  @override
  String get attention => '注意';

  @override
  String get authRequired => '認証が必要';

  @override
  String get auto => '自動';

  @override
  String get background => '背景';

  @override
  String get backup => 'バックアップ';

  @override
  String get bioAuth => '生体認証';

  @override
  String get blurRadius => 'ぼかし半径';

  @override
  String get bright => '明るい';

  @override
  String get cancel => 'キャンセル';

  @override
  String get checkUpdate => 'アップデートを確認する';

  @override
  String get clear => 'クリア';

  @override
  String get click => 'クリック';

  @override
  String get clipboard => 'クリップボード';

  @override
  String get close => '閉じる';

  @override
  String get content => 'コンテンツ';

  @override
  String get copy => 'コピーする';

  @override
  String get custom => 'カスタム';

  @override
  String get cut => '切り取り';

  @override
  String get dark => '暗い';

  @override
  String get day => '日';

  @override
  String delFmt(Object id, Object type) {
    return '$type（$id）を削除しますか？';
  }

  @override
  String get delay => '遅延';

  @override
  String get delete => '削除';

  @override
  String get device => 'デバイス';

  @override
  String get disabled => '無効化';

  @override
  String get doc => 'ドキュメント';

  @override
  String get dontShowAgain => '再度表示しない';

  @override
  String get download => 'ダウンロード';

  @override
  String get duration => '期間';

  @override
  String get edit => '編集';

  @override
  String get editor => 'エディター';

  @override
  String get empty => '空';

  @override
  String get error => 'エラー';

  @override
  String get example => '例';

  @override
  String get execute => '実行';

  @override
  String get exit => '終了';

  @override
  String get exitConfirmTip => 'もう一度戻ると終了します';

  @override
  String get exitDirectly => '直接終了する';

  @override
  String get export => 'エクスポート';

  @override
  String get fail => '失敗';

  @override
  String get feedback => 'フィードバック';

  @override
  String get file => 'ファイル';

  @override
  String get fold => '折りたたむ';

  @override
  String get folder => 'フォルダ';

  @override
  String get font => 'フォント';

  @override
  String get found => '見つかりました';

  @override
  String get hideTitleBar => 'タイトルバーを非表示にする';

  @override
  String get hour => '時間';

  @override
  String get image => '画像';

  @override
  String get import => 'インポート';

  @override
  String get init => '初期化';

  @override
  String get key => 'キー';

  @override
  String get language => '言語';

  @override
  String get license => 'ライセンス';

  @override
  String get log => 'ログ';

  @override
  String get login => 'ログイン';

  @override
  String get loginTip => '登録不要、無料で利用可能。';

  @override
  String get logout => 'ログアウト';

  @override
  String get manual => 'マニュアル';

  @override
  String get migrateCfg => '設定の移行';

  @override
  String get migrateCfgTip => '必要な新しい設定に適応するため';

  @override
  String get minute => '分';

  @override
  String get moveDown => '下へ移動';

  @override
  String get moveUp => '上へ移動';

  @override
  String get name => '名前';

  @override
  String get network => 'ネットワーク';

  @override
  String get next => '次へ';

  @override
  String notExistFmt(Object file) {
    return '$fileは存在しません';
  }

  @override
  String get note => 'メモ';

  @override
  String get ok => 'OK';

  @override
  String get opacity => '透明度';

  @override
  String get open => '開く';

  @override
  String get paste => '貼り付け';

  @override
  String get path => 'パス';

  @override
  String get preview => 'プレビュー';

  @override
  String get previous => '前へ';

  @override
  String get primaryColorSeed => '基本カラーの種';

  @override
  String get pwd => 'パスワード';

  @override
  String get pwdTip => '6〜32文字で、英字、数字、句読点を使用できます';

  @override
  String get redo => 'やり直す';

  @override
  String get refresh => '更新';

  @override
  String get register => '登録';

  @override
  String get rename => '名前変更';

  @override
  String get replace => '置換';

  @override
  String get replaceAll => 'すべて置換';

  @override
  String get reset => 'リセット';

  @override
  String get restore => 'リストア';

  @override
  String get result => '結果';

  @override
  String get retry => '再試行';

  @override
  String get save => '保存';

  @override
  String get search => '検索';

  @override
  String get second => '秒';

  @override
  String get select => '選択';

  @override
  String get setting => '設定';

  @override
  String get share => '共有';

  @override
  String get size => 'サイズ';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return 'コンテンツが大きすぎるため、最初の $bytes のみを表示しています';
  }

  @override
  String get start => '開始';

  @override
  String get stop => '停止';

  @override
  String get success => '成功';

  @override
  String get switch_ => 'スイッチ';

  @override
  String get switcher => 'スイッチャー';

  @override
  String get sync => '同期';

  @override
  String get system => 'システム';

  @override
  String get tag => 'タグ';

  @override
  String get tapToAuth => '認証するにはクリックしてください';

  @override
  String get themeMode => 'テーマモード';

  @override
  String get thinking => '考え中です';

  @override
  String get timeout => 'タイムアウト';

  @override
  String get undo => '元に戻す';

  @override
  String get unknown => '不明';

  @override
  String get unsupported => 'サポートされていません';

  @override
  String get update => '更新';

  @override
  String get upload => 'アップロード';

  @override
  String get user => 'ユーザー';

  @override
  String get value => '値';

  @override
  String versionHasUpdate(Object build) {
    return '新しいバージョンが見つかりました：v1.0.$build、クリックして更新する';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return '現在のバージョン：v1.0.$build、クリックして更新を確認';
  }

  @override
  String versionUpdated(Object build) {
    return '現在のバージョン：v1.0.$build、最新です';
  }

  @override
  String get yesterday => '昨日';

  @override
  String get addr => 'アドレス';

  @override
  String get available => '利用可能';

  @override
  String get convert => '変換';

  @override
  String get experimentalFeature => '実験的機能';

  @override
  String get foregroundService => 'フォアグラウンドサービス';

  @override
  String get goto => '移動';

  @override
  String get invalid => '無効';

  @override
  String get valid => '有効';

  @override
  String get max => '最大';

  @override
  String get min => '最小';

  @override
  String get more => 'もっと';

  @override
  String get milliseconds => 'ミリ秒';

  @override
  String get permission => '権限';

  @override
  String get read => '読み取り';

  @override
  String get write => '書き込み';

  @override
  String get done => '完了';

  @override
  String get speed => '速度';

  @override
  String get stat => '統計';

  @override
  String get time => '時間';

  @override
  String get times => '回';

  @override
  String get used => '使用済み';

  @override
  String get view => '表示';

  @override
  String get askAiModel => 'モデル';

  @override
  String get battery => 'バッテリー';

  @override
  String get cmd => 'コマンド';

  @override
  String get confirm => 'Confirm';

  @override
  String get conn => '接続';

  @override
  String get container => 'コンテナ';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get decode => 'デコード';

  @override
  String get decompress => '解凍';

  @override
  String get disconnected => '接続が切断されました';

  @override
  String get disk => 'ディスク';

  @override
  String get emulator => 'エミュレーター';

  @override
  String get encode => 'エンコード';

  @override
  String get force => '強制';

  @override
  String get host => 'ホスト';

  @override
  String get inner => '内蔵';

  @override
  String get install => 'インストール';

  @override
  String get location => '場所';

  @override
  String get logs => 'ログ';

  @override
  String get loss => 'パケットロス';

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
  String get mission => 'ミッション';

  @override
  String get ms => 'ミリ秒';

  @override
  String get net => 'ネットワーク';

  @override
  String get node => 'ノード';

  @override
  String get notAvailable => '利用不可';

  @override
  String get pingAvg => '平均:';

  @override
  String get pkg => 'パッケージ管理';

  @override
  String get port => 'ポート';

  @override
  String get process => 'プロセス';

  @override
  String get prune => '剪定する';

  @override
  String get reboot => '再起動';

  @override
  String get restart => '再開';

  @override
  String get route => 'ルーティング';

  @override
  String get run => '実行';

  @override
  String get running => '実行中';

  @override
  String get saved => '保存されました';

  @override
  String get sensors => 'センサー';

  @override
  String get sequence => '順序';

  @override
  String get server => 'サーバー';

  @override
  String get servers => 'サーバー';

  @override
  String get shutdown => 'シャットダウン';

  @override
  String get snippet => 'スニペット';

  @override
  String get stats => '統計';

  @override
  String get stopped => '停止しました';

  @override
  String get storage => 'ストレージ';

  @override
  String get suspend => '中断';

  @override
  String get temperature => '温度';

  @override
  String get terminal => 'ターミナル';

  @override
  String get test => 'テスト';

  @override
  String get theme => 'テーマ';

  @override
  String get total => '合計';

  @override
  String get totalAttempts => '総計';

  @override
  String get traffic => 'トラフィック';

  @override
  String get ttl => 'TTL';

  @override
  String get uptime => '稼働時間';
}
