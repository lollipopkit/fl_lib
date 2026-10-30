// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class LibLocalizationsRu extends LibLocalizations {
  LibLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get about => 'О';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1, а потом $action2?';
  }

  @override
  String get active => 'Активен';

  @override
  String get add => 'Добавить';

  @override
  String get addr => 'Адрес';

  @override
  String agoFmt(String time) {
    return '$time назад';
  }

  @override
  String get ai => 'ИИ';

  @override
  String get all => 'Все';

  @override
  String get anonLoseDataTip =>
      'В настоящее время выполнен анонимный вход, продолжение операций приведет к потере данных.';

  @override
  String get apiEndpoint => 'Базовый URL';

  @override
  String get apiKey => 'Ключ API';

  @override
  String get apiProtocol => 'Протокол API';

  @override
  String get app => 'Приложение';

  @override
  String get ascending => 'По возрастанию';

  @override
  String get askAiModel => 'Модель';

  @override
  String askContinue(Object msg) {
    return '$msg, продолжить?';
  }

  @override
  String get attention => 'Внимание';

  @override
  String get authRequired => 'Требуется аутентификация';

  @override
  String get auto => 'авто';

  @override
  String get available => 'Доступно';

  @override
  String get background => 'Фон';

  @override
  String get backup => 'Резервное копирование';

  @override
  String get battery => 'Батарея';

  @override
  String get bioAuth => 'Биометрическая аутентификация';

  @override
  String get blurRadius => 'Радиус размытия';

  @override
  String get bright => 'Светлый';

  @override
  String get browsing => 'Просмотр';

  @override
  String get cancel => 'Отмена';

  @override
  String get cancelled => 'Отменено';

  @override
  String get capacity => 'Ёмкость';

  @override
  String get checkUpdate => 'Проверить обновления';

  @override
  String get clear => 'Очистить';

  @override
  String get clearHistory => 'Очистить историю';

  @override
  String get click => 'Нажать';

  @override
  String get clipboard => 'Буфер обмена';

  @override
  String get clone => 'Клонировать';

  @override
  String get close => 'Закрыть';

  @override
  String get cmd => 'Команда';

  @override
  String get configured => 'Настроено';

  @override
  String get confirm => 'Подтвердить';

  @override
  String get conn => 'Подключение';

  @override
  String get container => 'Контейнер';

  @override
  String get content => 'Содержимое';

  @override
  String get convert => 'Конвертировать';

  @override
  String get copy => 'Копировать';

  @override
  String get create => 'Создать';

  @override
  String get current => 'Текущий';

  @override
  String get custom => 'Настроить';

  @override
  String get defaultLabel => 'По умолчанию';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get cut => 'Вырезать';

  @override
  String get dark => 'Темный';

  @override
  String get day => 'Дни';

  @override
  String get decode => 'Декодировать';

  @override
  String get decompress => 'Разархивировать';

  @override
  String delFmt(Object id, Object type) {
    return 'Удалить $type ($id)?';
  }

  @override
  String get delay => 'Задержка';

  @override
  String get delete => 'Удалить';

  @override
  String get descending => 'По убыванию';

  @override
  String get description => 'Описание';

  @override
  String get device => 'Устройство';

  @override
  String get disabled => 'отключено';

  @override
  String get enabled => 'Включено';

  @override
  String get disconnected => 'Отключено';

  @override
  String get disk => 'Диск';

  @override
  String get doc => 'Документация';

  @override
  String get done => 'Готово';

  @override
  String get dontShowAgain => 'Больше не показывать';

  @override
  String get download => 'скачать';

  @override
  String get duration => 'Длительность';

  @override
  String get edit => 'Редактировать';

  @override
  String get editor => 'Редактор';

  @override
  String get empty => 'Пусто';

  @override
  String get emulator => 'Эмулятор';

  @override
  String get encode => 'Кодировать';

  @override
  String get error => 'Ошибка';

  @override
  String get example => 'Пример';

  @override
  String get execute => 'Выполнить';

  @override
  String get exit => 'Выйти';

  @override
  String get exitConfirmTip => 'Нажмите назад еще раз, чтобы выйти';

  @override
  String get exitDirectly => 'Выйти сразу';

  @override
  String get experimentalFeature => 'Экспериментальная функция';

  @override
  String get export => 'Экспорт';

  @override
  String get fail => 'Неудача';

  @override
  String get feedback => 'Обратная связь';

  @override
  String get file => 'Файл';

  @override
  String get fold => 'Складывать';

  @override
  String get folder => 'Папка';

  @override
  String get followSystem => 'Следовать за системой';

  @override
  String get font => 'Шрифт';

  @override
  String get fontSize => 'Размер шрифта';

  @override
  String get force => 'Принудительно';

  @override
  String get foregroundService => 'Фоновая служба';

  @override
  String get format => 'Формат';

  @override
  String get found => 'Найдено';

  @override
  String get gateway => 'Шлюз';

  @override
  String get general => 'Общие';

  @override
  String get goBackQ => 'Вернуться?';

  @override
  String get goto => 'Перейти к';

  @override
  String get hideTitleBar => 'Скрыть строку заголовка';

  @override
  String get highlight => 'Подсветка кода';

  @override
  String get host => 'Хост';

  @override
  String get hour => 'Часы';

  @override
  String get image => 'Изображение';

  @override
  String get import => 'Импортировать';

  @override
  String get inactive => 'Неактивен';

  @override
  String get init => 'Инициализировать';

  @override
  String get inner => 'Встроенный';

  @override
  String get install => 'установить';

  @override
  String get invalid => 'Недействительно';

  @override
  String get invalidUrl => 'Некорректный URL';

  @override
  String get justNow => 'Только что';

  @override
  String get key => 'Ключ';

  @override
  String get language => 'язык';

  @override
  String get license => 'Лицензия';

  @override
  String get lkcAccount => 'Аккаунт';

  @override
  String get lkcBenefitBackups => 'Резервные копии';

  @override
  String lkcBenefitBackupsAppBytes(String size) {
    return 'до $size на приложение';
  }

  @override
  String lkcBenefitBackupsDetail(String kept, String limit) {
    return '$kept, $limit';
  }

  @override
  String get lkcBenefitBackupsLatest => 'Последняя для каждого приложения';

  @override
  String get lkcBenefitBackupsNoLimit => 'без ограничения размера';

  @override
  String lkcBenefitBackupsRolling(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ротируемой копии',
      many: '$count ротируемых копий',
      few: '$count ротируемые копии',
      one: '$count ротируемая копия',
    );
    return '$_temp0 на приложение';
  }

  @override
  String get lkcBenefitBackupsRollingUnlimited =>
      'Неограниченное число ротируемых копий на приложение';

  @override
  String lkcBenefitBackupsTotalBytes(String size) {
    return '$size на все приложения';
  }

  @override
  String get lkcBenefitRelay => 'Relay, tailnet и push';

  @override
  String lkcBenefitRelayDetail(String rate) {
    return 'Безлимитный трафик, $rate, без гарантии доступности';
  }

  @override
  String get lkcBenefitRelayUnlimited =>
      'Безлимитный трафик и скорость, без гарантии доступности';

  @override
  String get lkcBenefitShareLinks => 'Ссылки для доступа';

  @override
  String get lkcBenefitShareLinksDetail => 'Со сроком действия';

  @override
  String lkcBenefitStorageDetail(String file) {
    return 'Файлы до $file каждый';
  }

  @override
  String get lkcBenefitSync => 'Синхронизация';

  @override
  String get lkcBenefitSyncDetail => 'В реальном времени, сквозное шифрование';

  @override
  String get lkcBenefitUptime => 'Проверки недоступности';

  @override
  String lkcBenefitUptimeDetail(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Каждые $minutes минуты',
      many: 'Каждые $minutes минут',
      few: 'Каждые $minutes минуты',
      one: 'Каждые $minutes минуту',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count цели',
      many: '$count целей',
      few: '$count целей',
      one: '$count цели',
    );
    return '$_temp0, до $_temp1';
  }

  @override
  String lkcBenefitUptimeTargets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count цели',
      many: '$count целей',
      few: '$count целей',
      one: '$count цели',
    );
    return 'До $_temp0';
  }

  @override
  String get lkcBenefitUptimeTargetsUnlimited => 'Без ограничения числа целей';

  @override
  String lkcBenefitUptimeUnlimited(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Каждые $minutes минуты',
      many: 'Каждые $minutes минут',
      few: 'Каждые $minutes минуты',
      one: 'Каждые $minutes минуту',
    );
    return '$_temp0, без ограничения числа целей';
  }

  @override
  String lkcCancelsOn(String date) {
    return 'Отменяется $date';
  }

  @override
  String get lkcConduitConcurrency => 'Параллельные запросы';

  @override
  String lkcConduitConcurrencyDetail(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count одновременного запроса',
      many: '$count одновременных запросов',
      few: '$count одновременных запроса',
      one: '$count одновременный запрос',
    );
    return '$_temp0';
  }

  @override
  String get lkcConduitCredit => 'Лимит';

  @override
  String lkcConduitCreditMonthly(String credit) {
    return '$credit в месяц';
  }

  @override
  String lkcConduitCreditWeekly(String credit) {
    return '$credit в неделю';
  }

  @override
  String get lkcDeleteAccount => 'Удалить аккаунт';

  @override
  String lkcDeleteAccountConfirm(String name) {
    return '$name и его подписки будут удалены. Это действие нельзя отменить.';
  }

  @override
  String lkcEndsOn(String date) {
    return 'Заканчивается $date';
  }

  @override
  String lkcFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файла',
      many: '$count файлов',
      few: '$count файла',
      one: '$count файл',
    );
    return '$_temp0';
  }

  @override
  String get lkcFiles => 'Файлы';

  @override
  String get lkcFreeTier => 'Бесплатный';

  @override
  String get lkcManageSubscriptions => 'Управление подписками';

  @override
  String get lkcNoEndDate => 'Без даты окончания';

  @override
  String get lkcNotSignedIn => 'Вход не выполнен';

  @override
  String get lkcPastDue => 'Платёж просрочен';

  @override
  String get lkcPaused => 'Приостановлена';

  @override
  String lkcPerMonth(String price) {
    return '$price / месяц';
  }

  @override
  String lkcPerYear(String price) {
    return '$price / год';
  }

  @override
  String get lkcReasonAlreadySubscribed => 'Подписка уже оформлена';

  @override
  String get lkcReasonBadPurchaseToken => 'Недействительный токен покупки';

  @override
  String get lkcReasonBadPushToken => 'Недействительный push-токен';

  @override
  String get lkcReasonBadQuery => 'Недопустимый запрос';

  @override
  String get lkcReasonBadSignature => 'Недействительная подпись';

  @override
  String get lkcReasonBadTransaction => 'Недействительная транзакция';

  @override
  String get lkcReasonBenefitInvalid =>
      'Преимущество указано дважды, у тарифа, в котором его нет, или без владельца';

  @override
  String get lkcReasonCodeCheckout => 'Код нельзя использовать с этой оплатой';

  @override
  String get lkcReasonCodeCurrency => 'Валюта кода не совпадает с валютой цены';

  @override
  String get lkcReasonCodeCurrencyNeeded =>
      'Для фиксированной суммы нужна валюта';

  @override
  String get lkcReasonCodeDiscountPeriods => 'Скидка не предоставляет периоды';

  @override
  String get lkcReasonCodeDuration =>
      'Выберите, на какие платежи распространяется скидка';

  @override
  String get lkcReasonCodeExpired => 'Срок действия кода истёк';

  @override
  String get lkcReasonCodeFormat =>
      'Код состоит из 4–32 букв, цифр или дефисов';

  @override
  String get lkcReasonCodeGrantOff => 'Выдача не предполагает скидку';

  @override
  String get lkcReasonCodeGrantPeriods =>
      'Выдача действует от 1 до 120 периодов';

  @override
  String get lkcReasonCodeGrantPlan => 'Выдача относится к одному тарифу';

  @override
  String get lkcReasonCodeInactive => 'Код больше не действителен';

  @override
  String get lkcReasonCodeIsDiscount =>
      'Это код скидки, введите его при оформлении подписки';

  @override
  String get lkcReasonCodeIsGrant => 'Этот код выдаёт тариф, активируйте его';

  @override
  String get lkcReasonCodeKind => 'Тип кода нельзя изменить';

  @override
  String get lkcReasonCodeLimit => 'Лимит активаций должен быть положительным';

  @override
  String get lkcReasonCodeLineHeld => 'У вас уже есть подписка в этой линейке';

  @override
  String get lkcReasonCodeMonths =>
      'Повторяющаяся скидка действует от 1 до 36 месяцев';

  @override
  String get lkcReasonCodeNewOnly => 'Код только для новых подписчиков';

  @override
  String get lkcReasonCodeNotStarted => 'Код ещё не действует';

  @override
  String get lkcReasonCodeOff =>
      'Скидка — это процент (от 1 до 100) или фиксированная сумма';

  @override
  String get lkcReasonCodePlan => 'Код не применяется к этому тарифу';

  @override
  String get lkcReasonCodePlans => 'Выберите тарифы, к которым применяется код';

  @override
  String get lkcReasonCodeRedeemed => 'Код уже активирован, деактивируйте его';

  @override
  String get lkcReasonCodeTaken => 'Такой код уже существует';

  @override
  String get lkcReasonCodeTries => 'Слишком много попыток, повторите позже';

  @override
  String get lkcReasonCodeUnknown => 'Код не найден';

  @override
  String get lkcReasonCodeUsed => 'Вы уже использовали этот код';

  @override
  String get lkcReasonCodeUsedUp => 'Лимит использований кода исчерпан';

  @override
  String get lkcReasonCodeWindow =>
      'Код должен начинать действовать до истечения срока';

  @override
  String get lkcReasonDeleteAdmin =>
      'Снимите роль администратора в IdP перед удалением администратора';

  @override
  String get lkcReasonDeleteSelf => 'Удалите свой аккаунт на странице аккаунта';

  @override
  String get lkcReasonFileExists => 'Файл с таким именем уже существует';

  @override
  String get lkcReasonFileName => 'Недопустимое имя файла или каталога';

  @override
  String get lkcReasonFileQuota => 'Файлы превысят квоту хранилища';

  @override
  String get lkcReasonFileTooLarge => 'Файл слишком большой';

  @override
  String get lkcReasonForeignTransaction =>
      'Транзакция другого приложения или окружения';

  @override
  String get lkcReasonGrantGone => 'Активная ручная подписка не найдена';

  @override
  String get lkcReasonGrantHeld =>
      'У пользователя уже есть ручная подписка в этой линейке, измените её';

  @override
  String get lkcReasonGrantInPast =>
      'Срок выдачи должен заканчиваться в будущем';

  @override
  String get lkcReasonManualProvider => 'Manual не является провайдером';

  @override
  String get lkcReasonNoCustomer => 'Нет подписки для управления';

  @override
  String get lkcReasonNoSwitch => 'В этой линейке нет веб-подписки для смены';

  @override
  String get lkcReasonNoUser => 'Пользователь не найден';

  @override
  String get lkcReasonPriceArchived =>
      'Продаваемая цена архивирована у провайдера';

  @override
  String get lkcReasonPriceMissing =>
      'Продаваемая цена отсутствует у провайдера';

  @override
  String get lkcReasonPriceNotFixed =>
      'У продаваемой цены нет фиксированной суммы';

  @override
  String get lkcReasonPricePeriod =>
      'Продаваемая цена не соответствует периоду тарифа';

  @override
  String get lkcReasonProductId => 'ID продукта пуст или содержит пробелы';

  @override
  String get lkcReasonProductInUse =>
      'Продукт с активными подписками сохраняет свой тариф';

  @override
  String get lkcReasonProductPlans =>
      'Продукт привязывается только к одному тарифу';

  @override
  String get lkcReasonPurchaseAccount => 'Покупка принадлежит другому аккаунту';

  @override
  String get lkcReasonPushAccount => 'Неожиданный push-аккаунт';

  @override
  String get lkcReasonSamePlan => 'Этот тариф уже активен';

  @override
  String get lkcReasonSoldTwice =>
      'Одна продаваемая цена на тариф и провайдера';

  @override
  String get lkcReasonSwitchSync =>
      'Сохранено, но смену тарифа в Stripe обновить не удалось; сохраните ещё раз';

  @override
  String get lkcReasonTestPurchase => 'Тестовые покупки не принимаются';

  @override
  String get lkcReasonTransactionAccount =>
      'Транзакция принадлежит другому аккаунту';

  @override
  String get lkcReasonUnavailable => 'Недоступно';

  @override
  String get lkcReasonUnknownPackage => 'Неизвестный пакет';

  @override
  String get lkcReasonUploadSize =>
      'Загруженный файл отсутствует или не соответствует заявленному размеру';

  @override
  String get lkcReasonUploadUnknown => 'Загрузка не найдена или истекла';

  @override
  String get lkcReasonUserGone => 'Пользователь больше не существует';

  @override
  String lkcRenewsOn(String date) {
    return 'Продление $date';
  }

  @override
  String get lkcStoreSubscriptionTip =>
      'У вас есть подписка, оплачиваемая через App Store или Google Play. Сначала отмените её в магазине: удаление аккаунта её не останавливает.';

  @override
  String get lkcSubscribe => 'Оформить подписку';

  @override
  String get lkcUnlimited => 'Без ограничений';

  @override
  String lkcUsageOf(String used, String quota) {
    return '$used из $quota';
  }

  @override
  String get loadingEllipsis => '...';

  @override
  String get local => 'Локальный';

  @override
  String get location => 'Местоположение';

  @override
  String get log => 'лог';

  @override
  String get login => 'Войти';

  @override
  String get loginTip => 'Регистрация не требуется, бесплатное использование.';

  @override
  String get logout => 'Выйти';

  @override
  String get logs => 'Журналы';

  @override
  String get loss => 'Потери пакетов';

  @override
  String get manual => 'Руководство';

  @override
  String get max => 'Максимум';

  @override
  String get memory => 'Память';

  @override
  String get menuHelp => 'Справка';

  @override
  String get menuInfo => 'Информация';

  @override
  String get menuNavigate => 'Навигация';

  @override
  String get menuQuit => 'Выход';

  @override
  String get menuSettings => 'Настройки';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get migrateCfg => 'Миграция конфигурации';

  @override
  String get migrateCfgTip => 'Для адаптации к требуемой новой конфигурации';

  @override
  String get milliseconds => 'Миллисекунды';

  @override
  String get min => 'Минимум';

  @override
  String get minute => 'Минуты';

  @override
  String get mission => 'Задача';

  @override
  String get mode => 'Режим';

  @override
  String get more => 'Больше';

  @override
  String get moveDown => 'Вниз';

  @override
  String get moveUp => 'Вверх';

  @override
  String get ms => 'мс';

  @override
  String get name => 'Имя';

  @override
  String get net => 'Сеть';

  @override
  String get network => 'Сеть';

  @override
  String get next => 'Далее';

  @override
  String get node => 'Узел';

  @override
  String get none => 'Нет';

  @override
  String get notAvailable => 'Недоступно';

  @override
  String notExistFmt(Object file) {
    return '$file не существует';
  }

  @override
  String get note => 'Заметка';

  @override
  String get ok => 'Хорошо';

  @override
  String get opacity => 'Прозрачность';

  @override
  String get open => 'Открыть';

  @override
  String get optional => 'Необязательно';

  @override
  String get paste => 'Вставить';

  @override
  String get path => 'Путь';

  @override
  String get permission => 'Разрешение';

  @override
  String get permissionDenied => 'Доступ запрещён.';

  @override
  String get pingAvg => 'В среднем:';

  @override
  String get pkg => 'Менеджер пакетов';

  @override
  String get port => 'Порт';

  @override
  String get portForward => 'Проброс портов';

  @override
  String get preview => 'Предпросмотр';

  @override
  String get previous => 'Назад';

  @override
  String get primaryColorSeed => 'Основной цвет';

  @override
  String get process => 'Процесс';

  @override
  String get prune => 'Обрезать';

  @override
  String get pwd => 'Пароль';

  @override
  String get pwdTip =>
      'Длина от 6 до 32 символов, может содержать английские буквы, цифры и знаки препинания';

  @override
  String get read => 'Читать';

  @override
  String get ready => 'Готов';

  @override
  String get reboot => 'Перезагрузка';

  @override
  String get reconnecting => 'Переподключение...';

  @override
  String get redo => 'Повторить';

  @override
  String get refresh => 'Обновить';

  @override
  String get register => 'Зарегистрироваться';

  @override
  String get remote => 'Удалённый';

  @override
  String get rename => 'Переименовать';

  @override
  String get replace => 'Заменить';

  @override
  String get replaceAll => 'Заменить всё';

  @override
  String get reset => 'Сброс';

  @override
  String get restart => 'Перезапустить';

  @override
  String get restore => 'Восстановление';

  @override
  String get result => 'Результат';

  @override
  String get retry => 'Повторить';

  @override
  String get route => 'Маршрутизация';

  @override
  String get run => 'Запустить';

  @override
  String get running => 'Запущено';

  @override
  String get save => 'Сохранить';

  @override
  String get saveFailed => 'Не удалось сохранить';

  @override
  String get saved => 'Сохранено';

  @override
  String get search => 'Поиск';

  @override
  String get second => 'Секунды';

  @override
  String get select => 'Выбрать';

  @override
  String get sensors => 'Датчики';

  @override
  String get sequence => 'Последовательность';

  @override
  String get server => 'Сервер';

  @override
  String get servers => 'серверов';

  @override
  String get setting => 'Настройки';

  @override
  String get share => 'Поделиться';

  @override
  String get shutdown => 'Выключение';

  @override
  String get size => 'Размер';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return 'Содержимое слишком большое, отображаются только первые $bytes';
  }

  @override
  String get snippet => 'Фрагмент';

  @override
  String get softWrap => 'Мягкий перенос';

  @override
  String get sort => 'Сортировка';

  @override
  String get sortByName => 'По имени';

  @override
  String get source => 'Источник';

  @override
  String get speed => 'Скорость';

  @override
  String get start => 'Начать';

  @override
  String get stat => 'Статистика';

  @override
  String get stats => 'Статистика';

  @override
  String get stop => 'Стоп';

  @override
  String get stopped => 'Остановлено';

  @override
  String get storage => 'Хранение';

  @override
  String get success => 'Успех';

  @override
  String get sudoPassword => 'пароль sudo';

  @override
  String sudoPwdTitle(Object pwd) {
    return 'sudo $pwd';
  }

  @override
  String get suspend => 'Приостановить';

  @override
  String get switch_ => 'Переключатель';

  @override
  String get switcher => 'Переключатель';

  @override
  String get sync => 'Синхронизировать';

  @override
  String get system => 'Система';

  @override
  String get tag => 'Тег';

  @override
  String get tapToAuth => 'Нажмите для подтверждения';

  @override
  String get temperature => 'Температура';

  @override
  String get terminal => 'Терминал';

  @override
  String get test => 'Тест';

  @override
  String get textScaler => 'Масштабирование текста';

  @override
  String get theme => 'Тема';

  @override
  String get themeMode => 'режим темы';

  @override
  String get thinking => 'Думаю';

  @override
  String get time => 'Время';

  @override
  String get timedOut => 'Время истекло';

  @override
  String get timeout => 'Тайм-аут';

  @override
  String get times => 'Раз';

  @override
  String get total => 'Всего';

  @override
  String get totalAttempts => 'Общее';

  @override
  String get traffic => 'Трафик';

  @override
  String get ttl => 'TTL';

  @override
  String get type => 'Тип';

  @override
  String get undo => 'Отменить';

  @override
  String get unknown => 'Неизвестно';

  @override
  String get unsupported => 'Не поддерживается';

  @override
  String get update => 'Обновить';

  @override
  String get upload => 'Загрузить';

  @override
  String get uptime => 'Время работы';

  @override
  String get used => 'Использовано';

  @override
  String get user => 'Пользователь';

  @override
  String get valid => 'Действительно';

  @override
  String get value => 'Значение';

  @override
  String versionHasUpdate(Object build) {
    return 'Найдена новая версия: v1.0.$build, нажмите для обновления';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return 'Текущая: v1.0.$build, нажмите для проверки обновлений';
  }

  @override
  String versionUpdated(Object build) {
    return 'Текущая: v1.0.$build, последняя версия';
  }

  @override
  String get view => 'Просмотр';

  @override
  String get viewErr => 'Просмотр ошибок';

  @override
  String get write => 'Записывать';

  @override
  String get yesterday => 'Вчера';

  @override
  String durationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count дня',
      many: '$count дней',
      few: '$count дня',
      one: '$count день',
    );
    return '$_temp0';
  }

  @override
  String durationHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count часа',
      many: '$count часов',
      few: '$count часа',
      one: '$count час',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count минуты',
      many: '$count минут',
      few: '$count минуты',
      one: '$count минута',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count секунды',
      many: '$count секунд',
      few: '$count секунды',
      one: '$count секунда',
    );
    return '$_temp0';
  }

  @override
  String get appearanceSettings => 'Внешний вид';

  @override
  String get appearancePreset => 'Готовая тема';

  @override
  String get appearanceThemeSchemaRange => 'Поддерживаемая схема темы';

  @override
  String get appearanceThemeInstall => 'Установить тему';

  @override
  String get appearanceThemeStore => 'Магазин тем';

  @override
  String get appearanceInvalidTheme => 'Недопустимый пакет темы или каталог';

  @override
  String get themeStoreRefreshFailed => 'Не удалось прочитать каталог тем.';

  @override
  String themeStoreDeleteTheme(String name) {
    return 'Удалить «$name»? Его файлы будут удалены с этого устройства. Если это используемая тема, приложение вернётся к теме по умолчанию.';
  }

  @override
  String themeStoreUpdatedFmt(String ago) {
    return 'обновлено $ago';
  }

  @override
  String get themeStoreUpdatedJustNow => 'обновлено только что';

  @override
  String get themeStoreSortInUse => 'Сначала используемая';

  @override
  String themeStoreMakeOwnFmt(String doc) {
    return 'Хотите сделать свою тему? Смотрите [как её создать]($doc) — спасибо за ваш вклад!';
  }

  @override
  String appearanceThemeNeedsNewerApp(String version) {
    return 'Требуется более новая версия приложения: $version';
  }

  @override
  String get appearanceFontFamilies => 'Семейства шрифтов интерфейса';

  @override
  String get appearanceFontFamiliesTip =>
      'Одно название в строке; шрифты применяются по порядку.';

  @override
  String get appearanceFontImport => 'Импортировать файл шрифта интерфейса';

  @override
  String get appearanceIcons => 'Значки в приложении';

  @override
  String get appearanceCorners => 'Углы';

  @override
  String get appearanceCardCorners => 'Углы карточек';

  @override
  String get appearanceTileCorners => 'Углы элементов';

  @override
  String get appearanceButtonCorners => 'Углы кнопок';

  @override
  String appearanceThemeModeLocked(String mode) {
    return 'Эта тема поддерживает только режим «$mode». Для смены режима выберите другую тему.';
  }

  @override
  String get caseSensitive => 'Учитывать регистр';

  @override
  String get flashlight => 'Фонарик';

  @override
  String get regex => 'Регулярное выражение';

  @override
  String get showPwd => 'Показать пароль';

  @override
  String existsFmt(String name) {
    return '$name уже существует';
  }

  @override
  String tooLargeFmt(String size) {
    return 'Больше $size';
  }

  @override
  String get appearanceIconPack => 'Набор значков';

  @override
  String get appearanceIconPackTheme => 'Значки темы';

  @override
  String get themeStoreThemes => 'Темы';

  @override
  String get themeStoreIconPacks => 'Наборы значков';

  @override
  String themeStoreDeleteIconPack(String name) {
    return 'Удалить «$name»? Его файлы будут удалены с этого устройства. Если это используемый набор значков, приложение вернётся к значкам темы.';
  }
}
