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
  String get custom => 'Настроить';

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
  String get device => 'Устройство';

  @override
  String get disabled => 'отключено';

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
  String get found => 'Найдено';

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
}
