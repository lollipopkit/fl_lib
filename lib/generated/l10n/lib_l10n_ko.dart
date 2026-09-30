// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class LibLocalizationsKo extends LibLocalizations {
  LibLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get about => '정보';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1 그리고 $action2?';
  }

  @override
  String get active => '활성';

  @override
  String get add => '추가';

  @override
  String get addr => '주소';

  @override
  String agoFmt(String time) {
    return '$time 전';
  }

  @override
  String get ai => 'AI';

  @override
  String get all => '모두';

  @override
  String get anonLoseDataTip => '현재 익명으로 로그인되어 있습니다. 계속 작업하면 데이터가 손실됩니다.';

  @override
  String get apiEndpoint => '기본 URL';

  @override
  String get apiKey => 'API 키';

  @override
  String get apiProtocol => 'API 프로토콜';

  @override
  String get app => '애플리케이션';

  @override
  String get ascending => '오름차순';

  @override
  String get askAiModel => '모델';

  @override
  String askContinue(Object msg) {
    return '$msg. 계속할까요?';
  }

  @override
  String get attention => '주의';

  @override
  String get authRequired => '인증 필요';

  @override
  String get auto => '자동';

  @override
  String get available => '사용 가능';

  @override
  String get background => '배경';

  @override
  String get backup => '백업';

  @override
  String get battery => '배터리';

  @override
  String get bioAuth => '생체 인증';

  @override
  String get blurRadius => '블러 반경';

  @override
  String get bright => '밝게';

  @override
  String get browsing => '탐색 중';

  @override
  String get cancel => '취소';

  @override
  String get cancelled => '취소됨';

  @override
  String get capacity => '용량';

  @override
  String get checkUpdate => '업데이트 확인';

  @override
  String get clear => '지우기';

  @override
  String get clearHistory => '기록 지우기';

  @override
  String get click => '클릭';

  @override
  String get clipboard => '클립보드';

  @override
  String get clone => '복제';

  @override
  String get close => '닫기';

  @override
  String get cmd => '명령어';

  @override
  String get configured => '설정됨';

  @override
  String get confirm => '확인';

  @override
  String get conn => '연결';

  @override
  String get container => '컨테이너';

  @override
  String get content => '내용';

  @override
  String get convert => '변환';

  @override
  String get copy => '복사';

  @override
  String get create => '만들기';

  @override
  String get current => '현재';

  @override
  String get custom => '사용자 정의';

  @override
  String get defaultLabel => '기본';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get cut => '잘라내기';

  @override
  String get dark => '어둡게';

  @override
  String get day => '일';

  @override
  String get decode => '디코딩';

  @override
  String get decompress => '압축 해제';

  @override
  String delFmt(Object id, Object type) {
    return '$type($id)을(를) 삭제하시겠습니까?';
  }

  @override
  String get delay => '지연';

  @override
  String get delete => '삭제';

  @override
  String get descending => '내림차순';

  @override
  String get description => '설명';

  @override
  String get device => '장치';

  @override
  String get disabled => '비활성화';

  @override
  String get enabled => '사용';

  @override
  String get disconnected => '연결이 끊어졌습니다';

  @override
  String get disk => '디스크';

  @override
  String get doc => '문서';

  @override
  String get done => '완료';

  @override
  String get dontShowAgain => '다시 표시하지 않음';

  @override
  String get download => '다운로드';

  @override
  String get duration => '지속 시간';

  @override
  String get edit => '편집';

  @override
  String get editor => '편집기';

  @override
  String get empty => '비어 있음';

  @override
  String get emulator => '에뮬레이터';

  @override
  String get encode => '인코딩';

  @override
  String get error => '오류';

  @override
  String get example => '예시';

  @override
  String get execute => '실행';

  @override
  String get exit => '종료';

  @override
  String get exitConfirmTip => '뒤로가기 버튼을 다시 눌러 종료';

  @override
  String get exitDirectly => '바로 종료';

  @override
  String get experimentalFeature => '실험적 기능';

  @override
  String get export => '내보내기';

  @override
  String get fail => '실패';

  @override
  String get feedback => '피드백';

  @override
  String get file => '파일';

  @override
  String get fold => '접기';

  @override
  String get folder => '폴더';

  @override
  String get followSystem => '시스템 설정 따르기';

  @override
  String get font => '글꼴';

  @override
  String get fontSize => '글꼴 크기';

  @override
  String get force => '강제';

  @override
  String get foregroundService => '포그라운드 서비스';

  @override
  String get format => '형식';

  @override
  String get found => '찾음';

  @override
  String get gateway => '게이트웨이';

  @override
  String get general => '일반';

  @override
  String get goBackQ => '돌아가시겠습니까?';

  @override
  String get goto => '이동';

  @override
  String get hideTitleBar => '제목 표시줄 숨기기';

  @override
  String get highlight => '코드 하이라이팅';

  @override
  String get host => '호스트';

  @override
  String get hour => '시간';

  @override
  String get image => '이미지';

  @override
  String get import => '가져오기';

  @override
  String get inactive => '비활성';

  @override
  String get init => '초기화';

  @override
  String get inner => '내장';

  @override
  String get install => '설치';

  @override
  String get invalid => '잘못됨';

  @override
  String get invalidUrl => '잘못된 URL입니다';

  @override
  String get justNow => '방금';

  @override
  String get key => '키';

  @override
  String get language => '언어';

  @override
  String get license => '라이선스';

  @override
  String get loadingEllipsis => '...';

  @override
  String get local => '로컬';

  @override
  String get location => '위치';

  @override
  String get log => '로그';

  @override
  String get login => '로그인';

  @override
  String get loginTip => '가입이 필요 없으며, 무료로 이용할 수 있습니다.';

  @override
  String get logout => '로그아웃';

  @override
  String get logs => '로그';

  @override
  String get loss => '손실';

  @override
  String get manual => '설명서';

  @override
  String get max => '최대';

  @override
  String get memory => '메모리';

  @override
  String get menuHelp => '도움말';

  @override
  String get menuInfo => '정보';

  @override
  String get menuNavigate => '탐색';

  @override
  String get menuQuit => '종료';

  @override
  String get menuSettings => '설정';

  @override
  String get menuWiki => '위키';

  @override
  String get migrateCfg => '구성 마이그레이션';

  @override
  String get migrateCfgTip => '필요한 새 구성에 맞추기 위해';

  @override
  String get milliseconds => '밀리초';

  @override
  String get min => '최소';

  @override
  String get minute => '분';

  @override
  String get mission => '작업';

  @override
  String get mode => '모드';

  @override
  String get more => '더보기';

  @override
  String get moveDown => '아래로 이동';

  @override
  String get moveUp => '위로 이동';

  @override
  String get ms => 'ms';

  @override
  String get name => '이름';

  @override
  String get net => '네트워크';

  @override
  String get network => '네트워크';

  @override
  String get next => '다음';

  @override
  String get node => '노드';

  @override
  String get none => '없음';

  @override
  String get notAvailable => '사용 불가';

  @override
  String notExistFmt(Object file) {
    return '$file이(가) 존재하지 않습니다';
  }

  @override
  String get note => '참고';

  @override
  String get ok => '확인';

  @override
  String get opacity => '불투명도';

  @override
  String get open => '열기';

  @override
  String get optional => '선택 사항';

  @override
  String get paste => '붙여넣기';

  @override
  String get path => '경로';

  @override
  String get permission => '권한';

  @override
  String get permissionDenied => '권한이 없습니다.';

  @override
  String get pingAvg => '평균:';

  @override
  String get pkg => '패키지';

  @override
  String get port => '포트';

  @override
  String get portForward => '포트 포워딩';

  @override
  String get preview => '미리보기';

  @override
  String get previous => '이전';

  @override
  String get primaryColorSeed => '기본 색상 시드';

  @override
  String get process => '프로세스';

  @override
  String get prune => '정리';

  @override
  String get pwd => '비밀번호';

  @override
  String get pwdTip => '길이 6-32자, 영문자, 숫자, 구두점은 사용 가능합니다';

  @override
  String get read => '읽기';

  @override
  String get ready => '준비됨';

  @override
  String get reboot => '재부팅';

  @override
  String get reconnecting => '재연결 중...';

  @override
  String get redo => '다시 실행';

  @override
  String get refresh => '새로 고침';

  @override
  String get register => '가입';

  @override
  String get remote => '원격';

  @override
  String get rename => '이름 변경';

  @override
  String get replace => '바꾸기';

  @override
  String get replaceAll => '모두 바꾸기';

  @override
  String get reset => '초기화';

  @override
  String get restart => '다시 시작';

  @override
  String get restore => '복원';

  @override
  String get result => '결과';

  @override
  String get retry => '다시 시도';

  @override
  String get route => '라우팅';

  @override
  String get run => '실행';

  @override
  String get running => '실행 중';

  @override
  String get save => '저장';

  @override
  String get saveFailed => '저장 실패';

  @override
  String get saved => '저장됨';

  @override
  String get search => '검색';

  @override
  String get second => '초';

  @override
  String get select => '선택';

  @override
  String get sensors => '센서';

  @override
  String get sequence => '순서';

  @override
  String get server => '서버';

  @override
  String get servers => '서버';

  @override
  String get setting => '설정';

  @override
  String get share => '공유';

  @override
  String get shutdown => '종료';

  @override
  String get size => '크기';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return '내용이 너무 큽니다. 처음 $bytes만 표시합니다';
  }

  @override
  String get snippet => '스니펫';

  @override
  String get softWrap => '자동 줄바꿈';

  @override
  String get sort => '정렬';

  @override
  String get sortByName => '이름순';

  @override
  String get source => '소스';

  @override
  String get speed => '속도';

  @override
  String get start => '시작';

  @override
  String get stat => '통계';

  @override
  String get stats => '통계';

  @override
  String get stop => '중지';

  @override
  String get stopped => '중지됨';

  @override
  String get storage => '저장소';

  @override
  String get success => '성공';

  @override
  String get sudoPassword => 'sudo 비밀번호';

  @override
  String sudoPwdTitle(Object pwd) {
    return 'sudo $pwd';
  }

  @override
  String get suspend => '일시 중지';

  @override
  String get switch_ => '전환';

  @override
  String get switcher => '스위치';

  @override
  String get sync => '동기화';

  @override
  String get system => '시스템';

  @override
  String get tag => '태그';

  @override
  String get tapToAuth => '클릭해서 인증';

  @override
  String get temperature => '온도';

  @override
  String get terminal => '터미널';

  @override
  String get test => '테스트';

  @override
  String get textScaler => '텍스트 배율';

  @override
  String get theme => '테마';

  @override
  String get themeMode => '테마 모드';

  @override
  String get thinking => '생각 중';

  @override
  String get time => '시간';

  @override
  String get timedOut => '시간 초과';

  @override
  String get timeout => '시간 초과';

  @override
  String get times => '회';

  @override
  String get total => '전체';

  @override
  String get totalAttempts => '총계';

  @override
  String get traffic => '트래픽';

  @override
  String get ttl => 'TTL';

  @override
  String get type => '유형';

  @override
  String get undo => '실행 취소';

  @override
  String get unknown => '알 수 없음';

  @override
  String get unsupported => '지원되지 않음';

  @override
  String get update => '업데이트';

  @override
  String get upload => '업로드';

  @override
  String get uptime => '가동 시간';

  @override
  String get used => '사용됨';

  @override
  String get user => '사용자';

  @override
  String get valid => '유효함';

  @override
  String get value => '값';

  @override
  String versionHasUpdate(Object build) {
    return '발견: v1.0.$build, 클릭하여 업데이트';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return '현재: v1.0.$build, 업데이트를 확인하려면 클릭';
  }

  @override
  String versionUpdated(Object build) {
    return '현재: v1.0.$build, 최신입니다';
  }

  @override
  String get view => '보기';

  @override
  String get viewErr => '오류 보기';

  @override
  String get write => '쓰기';

  @override
  String get yesterday => '어제';

  @override
  String durationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count일',
    );
    return '$_temp0';
  }

  @override
  String durationHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count시간',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count분',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count초',
    );
    return '$_temp0';
  }

  @override
  String get appearanceSettings => '모양';

  @override
  String get appearancePreset => '테마 프리셋';

  @override
  String get appearanceThemeSchemaRange => '지원하는 테마 schema';

  @override
  String get appearanceThemeInstall => '테마 설치';

  @override
  String get appearanceThemeStore => '테마 스토어';

  @override
  String get appearanceInvalidTheme => '유효하지 않은 테마 패키지 또는 카탈로그';

  @override
  String get themeStoreRefreshFailed => '테마 카탈로그를 읽을 수 없습니다.';

  @override
  String themeStoreDeleteTheme(String name) {
    return '“$name”을(를) 삭제할까요? 파일이 이 기기에서 제거됩니다. 사용 중인 테마라면 앱이 기본 테마로 돌아갑니다.';
  }

  @override
  String themeStoreUpdatedFmt(String ago) {
    return '$ago 업데이트';
  }

  @override
  String get themeStoreUpdatedJustNow => '방금 업데이트';

  @override
  String get themeStoreSortInUse => '사용 중 우선';

  @override
  String themeStoreMakeOwnFmt(String doc) {
    return '직접 테마를 만들고 싶다면 [테마 제작 안내]($doc)를 확인해 보세요. 기여해 주셔서 감사합니다!';
  }

  @override
  String appearanceThemeNeedsNewerApp(String version) {
    return '최신 버전의 앱이 필요합니다: $version';
  }

  @override
  String get appearanceFontFamilies => 'UI 글꼴 목록';

  @override
  String get appearanceFontFamiliesTip =>
      '한 줄에 글꼴 이름 하나씩 입력하세요. 위에서부터 순서대로 적용합니다.';

  @override
  String get appearanceFontImport => 'UI 글꼴 파일 가져오기';

  @override
  String get appearanceIcons => '앱 내 아이콘';

  @override
  String get appearanceCorners => '모서리';

  @override
  String get appearanceCardCorners => '카드 모서리';

  @override
  String get appearanceTileCorners => '타일 모서리';

  @override
  String get appearanceButtonCorners => '버튼 모서리';

  @override
  String appearanceThemeModeLocked(String mode) {
    return '이 테마는 $mode만 지원합니다. 모드를 변경하려면 다른 테마를 선택하세요.';
  }
}
