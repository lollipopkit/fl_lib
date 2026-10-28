// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Ukrainian (`uk`).
class LibLocalizationsUk extends LibLocalizations {
  LibLocalizationsUk([String locale = 'uk']) : super(locale);

  @override
  String get about => 'Про застосунок';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1, а потім $action2?';
  }

  @override
  String get active => 'Активний';

  @override
  String get add => 'Додати';

  @override
  String get addr => 'Адреса';

  @override
  String agoFmt(String time) {
    return '$time тому';
  }

  @override
  String get ai => 'ШІ';

  @override
  String get all => 'Все';

  @override
  String get anonLoseDataTip =>
      'Наразі ви увійшли в систему анонімно, продовження роботи призведе до втрати даних.';

  @override
  String get apiEndpoint => 'Базова URL';

  @override
  String get apiKey => 'Ключ API';

  @override
  String get apiProtocol => 'Протокол API';

  @override
  String get app => 'Застосунок';

  @override
  String get ascending => 'За зростанням';

  @override
  String get askAiModel => 'Модель';

  @override
  String askContinue(Object msg) {
    return '$msg. Продовжити?';
  }

  @override
  String get attention => 'Увага!';

  @override
  String get authRequired => 'Потрібна автентифікація';

  @override
  String get auto => 'Авто';

  @override
  String get available => 'Доступно';

  @override
  String get background => 'Тло';

  @override
  String get backup => 'Резервне копіювання';

  @override
  String get battery => 'Акумулятор';

  @override
  String get bioAuth => 'Біометрична автентифікація';

  @override
  String get blurRadius => 'Радіус розмиття';

  @override
  String get bright => 'Світлий';

  @override
  String get browsing => 'Перегляд';

  @override
  String get cancel => 'Скасувати';

  @override
  String get cancelled => 'Скасовано';

  @override
  String get capacity => 'Ємність';

  @override
  String get checkUpdate => 'Перевірити оновлення';

  @override
  String get clear => 'Очистити';

  @override
  String get clearHistory => 'Очистити історію';

  @override
  String get click => 'Натиснути';

  @override
  String get clipboard => 'Буфер обміну';

  @override
  String get clone => 'Клонувати';

  @override
  String get close => 'Закрити';

  @override
  String get cmd => 'Команда';

  @override
  String get configured => 'Налаштовано';

  @override
  String get confirm => 'Підтвердити';

  @override
  String get conn => 'З\'єднання';

  @override
  String get container => 'Контейнер';

  @override
  String get content => 'Контент';

  @override
  String get convert => 'Конвертувати';

  @override
  String get copy => 'Скопіювати';

  @override
  String get create => 'Створити';

  @override
  String get current => 'Поточний';

  @override
  String get custom => 'Користувацьке';

  @override
  String get defaultLabel => 'За замовчуванням';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get cut => 'Вирізати';

  @override
  String get dark => 'Темний';

  @override
  String get day => 'Дні';

  @override
  String get decode => 'Декодувати';

  @override
  String get decompress => 'Розпакувати';

  @override
  String delFmt(Object id, Object type) {
    return 'Видалити $type($id)?';
  }

  @override
  String get delay => 'Затримка';

  @override
  String get delete => 'Видалити';

  @override
  String get descending => 'За спаданням';

  @override
  String get description => 'Опис';

  @override
  String get device => 'Пристрій';

  @override
  String get disabled => 'Вимкнений';

  @override
  String get enabled => 'Увімкнено';

  @override
  String get disconnected => 'Відключено';

  @override
  String get disk => 'Диск';

  @override
  String get doc => 'Документація';

  @override
  String get done => 'Готово';

  @override
  String get dontShowAgain => 'Більше не показувати';

  @override
  String get download => 'Завантажити';

  @override
  String get duration => 'Тривалість';

  @override
  String get edit => 'Редагувати';

  @override
  String get editor => 'Редактор';

  @override
  String get empty => 'Пустий';

  @override
  String get emulator => 'Емулятор';

  @override
  String get encode => 'Кодувати';

  @override
  String get error => 'Помилка';

  @override
  String get example => 'Приклад';

  @override
  String get execute => 'Виконати';

  @override
  String get exit => 'Вихід';

  @override
  String get exitConfirmTip => 'Натисніть ще раз, щоб вийти';

  @override
  String get exitDirectly => 'Вийти негайно';

  @override
  String get experimentalFeature => 'Експериментальна функція';

  @override
  String get export => 'Експорт';

  @override
  String get fail => 'Невдача';

  @override
  String get feedback => 'Зворотній зв\'язок';

  @override
  String get file => 'Файл';

  @override
  String get fold => 'Складений';

  @override
  String get folder => 'Директорія';

  @override
  String get followSystem => 'Слідувати системі';

  @override
  String get font => 'Шрифт';

  @override
  String get fontSize => 'Розмір шрифту';

  @override
  String get force => 'Примусово';

  @override
  String get foregroundService => 'Фонова служба';

  @override
  String get format => 'Формат';

  @override
  String get found => 'Знайдено';

  @override
  String get gateway => 'Шлюз';

  @override
  String get general => 'Загальні';

  @override
  String get goBackQ => 'Повернутися назад?';

  @override
  String get goto => 'Перейти до';

  @override
  String get hideTitleBar => 'Приховати рядок заголовка';

  @override
  String get highlight => 'Підсвітка коду';

  @override
  String get host => 'Хост';

  @override
  String get hour => 'Години';

  @override
  String get image => 'Зображення';

  @override
  String get import => 'Імпорт';

  @override
  String get inactive => 'Неактивний';

  @override
  String get init => 'Ініціалізувати';

  @override
  String get inner => 'Внутрішній';

  @override
  String get install => 'Встановити';

  @override
  String get invalid => 'Недійсно';

  @override
  String get invalidUrl => 'Некоректна URL-адреса';

  @override
  String get justNow => 'Щойно';

  @override
  String get key => 'Ключ';

  @override
  String get language => 'Мова';

  @override
  String get license => 'Ліцензія';

  @override
  String get lkcAccount => 'Обліковий запис';

  @override
  String get lkcBenefitBackups => 'Резервні копії';

  @override
  String lkcBenefitBackupsAppBytes(String size) {
    return 'до $size на застосунок';
  }

  @override
  String lkcBenefitBackupsDetail(String kept, String limit) {
    return '$kept, $limit';
  }

  @override
  String get lkcBenefitBackupsLatest => 'Остання для кожного застосунку';

  @override
  String get lkcBenefitBackupsNoLimit => 'без обмеження розміру';

  @override
  String lkcBenefitBackupsRolling(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ротаційної копії',
      many: '$count ротаційних копій',
      few: '$count ротаційні копії',
      one: '$count ротаційна копія',
    );
    return '$_temp0 на застосунок';
  }

  @override
  String get lkcBenefitBackupsRollingUnlimited =>
      'Необмежена кількість ротаційних копій на застосунок';

  @override
  String lkcBenefitBackupsTotalBytes(String size) {
    return '$size на всі застосунки';
  }

  @override
  String get lkcBenefitRelay => 'Relay, tailnet і push';

  @override
  String lkcBenefitRelayDetail(String rate) {
    return 'Необмежений трафік, $rate, без гарантії доступності';
  }

  @override
  String get lkcBenefitRelayUnlimited =>
      'Необмежений трафік і швидкість, без гарантії доступності';

  @override
  String get lkcBenefitShareLinks => 'Посилання для доступу';

  @override
  String get lkcBenefitShareLinksDetail => 'З терміном дії';

  @override
  String lkcBenefitStorageDetail(String file) {
    return 'Файли до $file кожен';
  }

  @override
  String get lkcBenefitSync => 'Синхронізація';

  @override
  String get lkcBenefitSyncDetail => 'У реальному часі, наскрізне шифрування';

  @override
  String get lkcBenefitUptime => 'Перевірки недоступності';

  @override
  String lkcBenefitUptimeDetail(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Кожні $minutes хвилини',
      many: 'Кожні $minutes хвилин',
      few: 'Кожні $minutes хвилини',
      one: 'Кожні $minutes хвилину',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count цілі',
      many: '$count цілей',
      few: '$count цілей',
      one: '$count цілі',
    );
    return '$_temp0, до $_temp1';
  }

  @override
  String lkcBenefitUptimeTargets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count цілі',
      many: '$count цілей',
      few: '$count цілей',
      one: '$count цілі',
    );
    return 'До $_temp0';
  }

  @override
  String get lkcBenefitUptimeTargetsUnlimited =>
      'Без обмеження кількості цілей';

  @override
  String lkcBenefitUptimeUnlimited(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Кожні $minutes хвилини',
      many: 'Кожні $minutes хвилин',
      few: 'Кожні $minutes хвилини',
      one: 'Кожні $minutes хвилину',
    );
    return '$_temp0, без обмеження кількості цілей';
  }

  @override
  String lkcCancelsOn(String date) {
    return 'Скасовується $date';
  }

  @override
  String get lkcConduitConcurrency => 'Паралельні запити';

  @override
  String lkcConduitConcurrencyDetail(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count одночасного запиту',
      many: '$count одночасних запитів',
      few: '$count одночасні запити',
      one: '$count одночасний запит',
    );
    return '$_temp0';
  }

  @override
  String get lkcConduitCredit => 'Ліміт';

  @override
  String lkcConduitCreditMonthly(String credit) {
    return '$credit на місяць';
  }

  @override
  String lkcConduitCreditWeekly(String credit) {
    return '$credit на тиждень';
  }

  @override
  String get lkcDeleteAccount => 'Видалити обліковий запис';

  @override
  String lkcDeleteAccountConfirm(String name) {
    return '$name і його підписки буде видалено. Цю дію не можна скасувати.';
  }

  @override
  String lkcEndsOn(String date) {
    return 'Закінчується $date';
  }

  @override
  String lkcFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файлу',
      many: '$count файлів',
      few: '$count файли',
      one: '$count файл',
    );
    return '$_temp0';
  }

  @override
  String get lkcFiles => 'Файли';

  @override
  String get lkcFreeTier => 'Безкоштовний';

  @override
  String get lkcManageSubscriptions => 'Керування підписками';

  @override
  String get lkcNoEndDate => 'Без дати завершення';

  @override
  String get lkcNotSignedIn => 'Вхід не виконано';

  @override
  String get lkcPastDue => 'Платіж прострочено';

  @override
  String get lkcPaused => 'Призупинено';

  @override
  String lkcPerMonth(String price) {
    return '$price / місяць';
  }

  @override
  String lkcPerYear(String price) {
    return '$price / рік';
  }

  @override
  String get lkcReasonAlreadySubscribed => 'Підписку вже оформлено';

  @override
  String get lkcReasonBadPurchaseToken => 'Недійсний токен покупки';

  @override
  String get lkcReasonBadPushToken => 'Недійсний push-токен';

  @override
  String get lkcReasonBadQuery => 'Неприпустимий запит';

  @override
  String get lkcReasonBadSignature => 'Недійсний підпис';

  @override
  String get lkcReasonBadTransaction => 'Недійсна транзакція';

  @override
  String get lkcReasonBenefitInvalid =>
      'Перевагу вказано двічі, для тарифу, у якому її немає, або без власника';

  @override
  String get lkcReasonCodeCheckout => 'Код не можна використати з цією оплатою';

  @override
  String get lkcReasonCodeCurrency =>
      'Валюта коду не збігається з валютою ціни';

  @override
  String get lkcReasonCodeCurrencyNeeded =>
      'Для фіксованої суми потрібна валюта';

  @override
  String get lkcReasonCodeDiscountPeriods => 'Знижка не надає періодів';

  @override
  String get lkcReasonCodeDuration =>
      'Виберіть, на які платежі поширюється знижка';

  @override
  String get lkcReasonCodeExpired => 'Термін дії коду минув';

  @override
  String get lkcReasonCodeFormat =>
      'Код складається з 4–32 літер, цифр або дефісів';

  @override
  String get lkcReasonCodeGrantOff => 'Надання не передбачає знижки';

  @override
  String get lkcReasonCodeGrantPeriods => 'Надання діє від 1 до 120 періодів';

  @override
  String get lkcReasonCodeGrantPlan => 'Надання стосується одного тарифу';

  @override
  String get lkcReasonCodeInactive => 'Код більше не дійсний';

  @override
  String get lkcReasonCodeIsDiscount =>
      'Це код знижки, введіть його під час оформлення підписки';

  @override
  String get lkcReasonCodeIsGrant => 'Цей код надає тариф, активуйте його';

  @override
  String get lkcReasonCodeKind => 'Тип коду не можна змінити';

  @override
  String get lkcReasonCodeLimit => 'Ліміт активацій має бути додатним';

  @override
  String get lkcReasonCodeLineHeld => 'Ви вже маєте підписку в цій лінійці';

  @override
  String get lkcReasonCodeMonths =>
      'Повторювана знижка діє від 1 до 36 місяців';

  @override
  String get lkcReasonCodeNewOnly => 'Код лише для нових передплатників';

  @override
  String get lkcReasonCodeNotStarted => 'Код ще не діє';

  @override
  String get lkcReasonCodeOff =>
      'Знижка — це відсоток (від 1 до 100) або фіксована сума';

  @override
  String get lkcReasonCodePlan => 'Код не застосовується до цього тарифу';

  @override
  String get lkcReasonCodePlans =>
      'Виберіть тарифи, до яких застосовується код';

  @override
  String get lkcReasonCodeRedeemed => 'Код уже активовано, деактивуйте його';

  @override
  String get lkcReasonCodeTaken => 'Такий код уже існує';

  @override
  String get lkcReasonCodeTries => 'Забагато спроб, спробуйте пізніше';

  @override
  String get lkcReasonCodeUnknown => 'Код не знайдено';

  @override
  String get lkcReasonCodeUsed => 'Ви вже використали цей код';

  @override
  String get lkcReasonCodeUsedUp => 'Ліміт використань коду вичерпано';

  @override
  String get lkcReasonCodeWindow =>
      'Код має почати діяти до закінчення терміну';

  @override
  String get lkcReasonDeleteAdmin =>
      'Зніміть роль адміністратора в IdP перед видаленням адміністратора';

  @override
  String get lkcReasonDeleteSelf =>
      'Видаліть свій обліковий запис на сторінці облікового запису';

  @override
  String get lkcReasonFileExists => 'Файл із такою назвою вже існує';

  @override
  String get lkcReasonFileName => 'Неприпустима назва файлу або каталогу';

  @override
  String get lkcReasonFileQuota => 'Файли перевищать квоту сховища';

  @override
  String get lkcReasonFileTooLarge => 'Файл завеликий';

  @override
  String get lkcReasonForeignTransaction =>
      'Транзакція іншого застосунку або середовища';

  @override
  String get lkcReasonGrantGone => 'Активну ручну підписку не знайдено';

  @override
  String get lkcReasonGrantHeld =>
      'Користувач уже має ручну підписку в цій лінійці, змініть її';

  @override
  String get lkcReasonGrantInPast =>
      'Термін надання має закінчуватися в майбутньому';

  @override
  String get lkcReasonManualProvider => 'Manual не є провайдером';

  @override
  String get lkcReasonNoCustomer => 'Немає підписки для керування';

  @override
  String get lkcReasonNoSwitch => 'У цій лінійці немає вебпідписки для зміни';

  @override
  String get lkcReasonNoUser => 'Користувача не знайдено';

  @override
  String get lkcReasonPriceArchived => 'Ціну продажу архівовано у провайдера';

  @override
  String get lkcReasonPriceMissing => 'Ціна продажу відсутня у провайдера';

  @override
  String get lkcReasonPriceNotFixed => 'Ціна продажу не має фіксованої суми';

  @override
  String get lkcReasonPricePeriod =>
      'Ціна продажу не відповідає періоду тарифу';

  @override
  String get lkcReasonProductId => 'ID продукту порожній або містить пробіли';

  @override
  String get lkcReasonProductInUse =>
      'Продукт з активними підписками зберігає свій тариф';

  @override
  String get lkcReasonProductPlans =>
      'Продукт прив’язується лише до одного тарифу';

  @override
  String get lkcReasonPurchaseAccount =>
      'Покупка належить іншому обліковому запису';

  @override
  String get lkcReasonPushAccount => 'Неочікуваний push-обліковий запис';

  @override
  String get lkcReasonSamePlan => 'Цей тариф уже активний';

  @override
  String get lkcReasonSoldTwice => 'Одна ціна продажу на тариф і провайдера';

  @override
  String get lkcReasonSwitchSync =>
      'Збережено, але зміну тарифу в Stripe оновити не вдалося; збережіть ще раз';

  @override
  String get lkcReasonTestPurchase => 'Тестові покупки не приймаються';

  @override
  String get lkcReasonTransactionAccount =>
      'Транзакція належить іншому обліковому запису';

  @override
  String get lkcReasonUnavailable => 'Недоступно';

  @override
  String get lkcReasonUnknownPackage => 'Невідомий пакет';

  @override
  String get lkcReasonUploadSize =>
      'Завантажений файл відсутній або не відповідає заявленому розміру';

  @override
  String get lkcReasonUploadUnknown =>
      'Завантаження не знайдено або воно застаріло';

  @override
  String get lkcReasonUserGone => 'Користувач більше не існує';

  @override
  String lkcRenewsOn(String date) {
    return 'Поновлення $date';
  }

  @override
  String get lkcStoreSubscriptionTip =>
      'У вас є підписка, що оплачується через App Store або Google Play. Спершу скасуйте її в магазині: видалення облікового запису її не зупиняє.';

  @override
  String get lkcSubscribe => 'Оформити підписку';

  @override
  String get lkcUnlimited => 'Без обмежень';

  @override
  String lkcUsageOf(String used, String quota) {
    return '$used з $quota';
  }

  @override
  String get loadingEllipsis => '...';

  @override
  String get local => 'Локальний';

  @override
  String get location => 'Місцезнаходження';

  @override
  String get log => 'Лог';

  @override
  String get login => 'Вхід';

  @override
  String get loginTip => 'Реєстрація не потрібна, користування безкоштовне';

  @override
  String get logout => 'Вихід';

  @override
  String get logs => 'Журнали';

  @override
  String get loss => 'втрата пакетів';

  @override
  String get manual => 'Посібник';

  @override
  String get max => 'Максимум';

  @override
  String get memory => 'Пам\'ять';

  @override
  String get menuHelp => 'Довідка';

  @override
  String get menuInfo => 'Інформація';

  @override
  String get menuNavigate => 'Навігація';

  @override
  String get menuQuit => 'Вихід';

  @override
  String get menuSettings => 'Налаштування';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get migrateCfg => 'Міграція конфігурації';

  @override
  String get migrateCfgTip => 'для адаптації до нової необхідної конфігурації';

  @override
  String get milliseconds => 'Мілісекунди';

  @override
  String get min => 'Мінімум';

  @override
  String get minute => 'Хвилини';

  @override
  String get mission => 'Місія';

  @override
  String get mode => 'Режим';

  @override
  String get more => 'Більше';

  @override
  String get moveDown => 'Вниз';

  @override
  String get moveUp => 'Вгору';

  @override
  String get ms => 'мс.';

  @override
  String get name => 'Назва';

  @override
  String get net => 'Мережа';

  @override
  String get network => 'Мережа';

  @override
  String get next => 'Далі';

  @override
  String get node => 'Вузол';

  @override
  String get none => 'Немає';

  @override
  String get notAvailable => 'Недоступний';

  @override
  String notExistFmt(Object file) {
    return '$file не існує';
  }

  @override
  String get note => 'Нотатка';

  @override
  String get ok => 'Гаразд';

  @override
  String get opacity => 'Прозорість';

  @override
  String get open => 'Відкрити';

  @override
  String get optional => 'Необовʼязково';

  @override
  String get paste => 'Вставити';

  @override
  String get path => 'Шлях';

  @override
  String get permission => 'Дозвіл';

  @override
  String get permissionDenied => 'Доступ заборонено.';

  @override
  String get pingAvg => 'Середнє:';

  @override
  String get pkg => 'Пакет';

  @override
  String get port => 'Порт';

  @override
  String get portForward => 'Переадресація портів';

  @override
  String get preview => 'Попередній перегляд';

  @override
  String get previous => 'Попередній';

  @override
  String get primaryColorSeed => 'Основний колір';

  @override
  String get process => 'Процес';

  @override
  String get prune => 'Обрізати';

  @override
  String get pwd => 'Пароль';

  @override
  String get pwdTip =>
      'Довжина 6-32, може містити англійські літери, цифри та розділові знаки';

  @override
  String get read => 'Читати';

  @override
  String get ready => 'Готово';

  @override
  String get reboot => 'Перезавантажити';

  @override
  String get reconnecting => 'Перепідключення...';

  @override
  String get redo => 'Повторити';

  @override
  String get refresh => 'Оновити';

  @override
  String get register => 'Зареєструватися';

  @override
  String get remote => 'Віддалений';

  @override
  String get rename => 'Перейменувати';

  @override
  String get replace => 'Замінити';

  @override
  String get replaceAll => 'Замінити все';

  @override
  String get reset => 'Скинути';

  @override
  String get restart => 'Перезапустити';

  @override
  String get restore => 'Відновити';

  @override
  String get result => 'Результат';

  @override
  String get retry => 'Повторити';

  @override
  String get route => 'Маршрут';

  @override
  String get run => 'Запустити';

  @override
  String get running => 'Виконання';

  @override
  String get save => 'Зберегти';

  @override
  String get saveFailed => 'Не вдалося зберегти';

  @override
  String get saved => 'Збережено';

  @override
  String get search => 'Пошук';

  @override
  String get second => 'Секунди';

  @override
  String get select => 'Вибрати';

  @override
  String get sensors => 'Датчики';

  @override
  String get sequence => 'Послідовність';

  @override
  String get server => 'Сервер';

  @override
  String get servers => 'серверів';

  @override
  String get setting => 'Налаштування';

  @override
  String get share => 'Поділіться';

  @override
  String get shutdown => 'Вимкнення';

  @override
  String get size => 'Розмір';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return 'Вміст занадто великий, відображаються лише перші $bytes';
  }

  @override
  String get snippet => 'Фрагмент';

  @override
  String get softWrap => 'М\'ягкий перенос';

  @override
  String get sort => 'Сортування';

  @override
  String get sortByName => 'За назвою';

  @override
  String get source => 'Джерело';

  @override
  String get speed => 'Швидкість';

  @override
  String get start => 'Почати';

  @override
  String get stat => 'Статистика';

  @override
  String get stats => 'Статистики';

  @override
  String get stop => 'Зупинити';

  @override
  String get stopped => 'Зупинено';

  @override
  String get storage => 'Сховище';

  @override
  String get success => 'Успішно';

  @override
  String get sudoPassword => 'пароль sudo';

  @override
  String sudoPwdTitle(Object pwd) {
    return 'sudo $pwd';
  }

  @override
  String get suspend => 'Призупинити';

  @override
  String get switch_ => 'Перемикач';

  @override
  String get switcher => 'Перемикач';

  @override
  String get sync => 'Синхронізувати';

  @override
  String get system => 'Система';

  @override
  String get tag => 'Теґ';

  @override
  String get tapToAuth => 'Натисніть, щоб підтвердити';

  @override
  String get temperature => 'Температура';

  @override
  String get terminal => 'Термінал';

  @override
  String get test => 'Тест';

  @override
  String get textScaler => 'Масштабування тексту';

  @override
  String get theme => 'Тема';

  @override
  String get themeMode => 'Тема';

  @override
  String get thinking => 'Обмірковую';

  @override
  String get time => 'Час';

  @override
  String get timedOut => 'Час вичерпано';

  @override
  String get timeout => 'Тайм-аут';

  @override
  String get times => 'Раз';

  @override
  String get total => 'Всього';

  @override
  String get totalAttempts => 'Загальна кількість';

  @override
  String get traffic => 'Трафік';

  @override
  String get ttl => 'TTL';

  @override
  String get type => 'Тип';

  @override
  String get undo => 'Скасувати';

  @override
  String get unknown => 'Невідомо';

  @override
  String get unsupported => 'Не підтримується';

  @override
  String get update => 'Оновити';

  @override
  String get upload => 'Завантажити';

  @override
  String get uptime => 'Час роботи';

  @override
  String get used => 'Використано';

  @override
  String get user => 'Користувач';

  @override
  String get valid => 'Дійсно';

  @override
  String get value => 'Значення';

  @override
  String versionHasUpdate(Object build) {
    return 'Є оновлення: v1.0.$build, натисніть, щоб оновити';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return 'Поточна: v1.0.$build, натисніть, щоб перевірити оновлення';
  }

  @override
  String versionUpdated(Object build) {
    return 'Поточна: v1.0.$build, є актуальною';
  }

  @override
  String get view => 'Перегляд';

  @override
  String get viewErr => 'Переглянути помилку';

  @override
  String get write => 'Записувати';

  @override
  String get yesterday => 'Вчора';

  @override
  String durationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count дня',
      many: '$count днів',
      few: '$count дні',
      one: '$count день',
    );
    return '$_temp0';
  }

  @override
  String durationHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count години',
      many: '$count годин',
      few: '$count години',
      one: '$count година',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count хвилини',
      many: '$count хвилин',
      few: '$count хвилини',
      one: '$count хвилина',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count секунди',
      many: '$count секунд',
      few: '$count секунди',
      one: '$count секунда',
    );
    return '$_temp0';
  }

  @override
  String get appearanceSettings => 'Вигляд';

  @override
  String get appearancePreset => 'Готова тема';

  @override
  String get appearanceThemeSchemaRange => 'Підтримувана схема теми';

  @override
  String get appearanceThemeInstall => 'Установити тему';

  @override
  String get appearanceThemeStore => 'Магазин тем';

  @override
  String get appearanceInvalidTheme => 'Недійсний пакет теми або каталог';

  @override
  String get themeStoreRefreshFailed => 'Не вдалося прочитати каталог тем.';

  @override
  String themeStoreDeleteTheme(String name) {
    return 'Видалити «$name»? Його файли буде видалено з цього пристрою. Якщо це тема, що використовується, застосунок повернеться до типової теми.';
  }

  @override
  String themeStoreUpdatedFmt(String ago) {
    return 'оновлено $ago';
  }

  @override
  String get themeStoreUpdatedJustNow => 'щойно оновлено';

  @override
  String get themeStoreSortInUse => 'Спочатку використовувана';

  @override
  String themeStoreMakeOwnFmt(String doc) {
    return 'Хочете створити власну тему? Дивіться [як її створити]($doc) — дякуємо за ваш внесок!';
  }

  @override
  String appearanceThemeNeedsNewerApp(String version) {
    return 'Потрібна новіша версія застосунку: $version';
  }

  @override
  String get appearanceFontFamilies => 'Сімейства шрифтів інтерфейсу';

  @override
  String get appearanceFontFamiliesTip =>
      'Одна назва в рядку; шрифти застосовуються за порядком.';

  @override
  String get appearanceFontImport => 'Імпортувати файл шрифту інтерфейсу';

  @override
  String get appearanceIcons => 'Піктограми в застосунку';

  @override
  String get appearanceCorners => 'Кути';

  @override
  String get appearanceCardCorners => 'Кути карток';

  @override
  String get appearanceTileCorners => 'Кути плиток';

  @override
  String get appearanceButtonCorners => 'Кути кнопок';

  @override
  String appearanceThemeModeLocked(String mode) {
    return 'Ця тема підтримує лише режим «$mode». Щоб змінити режим, виберіть іншу тему.';
  }

  @override
  String get caseSensitive => 'Враховувати регістр';

  @override
  String get flashlight => 'Ліхтарик';

  @override
  String get regex => 'Регулярний вираз';

  @override
  String get showPwd => 'Показати пароль';

  @override
  String existsFmt(String name) {
    return '$name вже існує';
  }

  @override
  String tooLargeFmt(String size) {
    return 'Більше ніж $size';
  }

  @override
  String get appearanceIconPack => 'Набір значків';

  @override
  String get appearanceIconPackTheme => 'Значки теми';

  @override
  String get themeStoreThemes => 'Теми';

  @override
  String get themeStoreIconPacks => 'Набори значків';

  @override
  String themeStoreDeleteIconPack(String name) {
    return 'Видалити «$name»? Його файли буде видалено з цього пристрою. Якщо це набір значків, що використовується, застосунок повернеться до значків теми.';
  }
}
