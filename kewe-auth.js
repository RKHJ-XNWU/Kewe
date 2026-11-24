/* ============================================================
 * kewe-auth.js —— 登录 / 注册 / 退出登录 / 注销账号 / 404 门禁
 *
 * 安全模型：
 *   · 浏览器用 PBKDF2-SHA256 把密码派生为 verifier（30,000 次）；
 *   · 网络只发送 verifier，服务端再以随机 salt + HMAC-SHA256 保存；
 *   · 明文密码永远不离开本机，也不进入 localStorage；
 *   · 登录 Cookie 为 HttpOnly + SameSite=Strict，脚本读不到。
 * ============================================================ */
(function (global) {
  'use strict';

  var LANG_KEY = 'dsc_ui_lang2';
  var SUPPORTED = ['ja', 'zh', 'en', 'ko', 'ru', 'fr'];
  var LANG_META = {
    ja: { flag: '🇯🇵', label: '日本語', code: 'JA' },
    zh: { flag: '🇨🇳', label: '中文', code: 'ZH' },
    en: { flag: '🇬🇧', label: 'English', code: 'EN' },
    ko: { flag: '🇰🇷', label: '한국어', code: 'KO' },
    ru: { flag: '🇷🇺', label: 'Русский', code: 'RU' },
    fr: { flag: '🇫🇷', label: 'Français', code: 'FR' }
  };

  var I18N = {
    ja: {
      page404: '404 · ページが見つかりません',
      page404sub: 'このページは存在しないか、ログインが必要です。',
      titleLogin: '安全にログイン',
      titleRegister: 'アカウントを作成',
      subLogin: 'ログイン後に、このアカウントの会話・知識・ファイルが表示されます。会話本文はアカウント別に平文保存されます。',
      subRegister: 'アカウントごとに独立したデータ領域とログイン境界を持ちます。',
      login: 'ログイン',
      register: '新規登録',
      username: 'ユーザー名',
      usernamePh: '3〜32文字・重複不可',
      password: 'パスワード',
      passwordPh: '10文字以上・大文字小文字・数字・記号',
      confirm: 'パスワード確認',
      confirmPh: 'もう一度入力',
      ruleUser: 'ユーザー名は3〜32文字（空白・/・| 不可）',
      ruleLen: '10文字以上',
      ruleUpper: '大文字を1文字以上',
      ruleLower: '小文字を1文字以上',
      ruleDigit: '数字を1文字以上',
      ruleSymbol: '記号を1文字以上',
      secure: 'アカウント分離',
      submitLogin: 'ログイン',
      submitRegister: '登録して開始',
      switchToRegister: 'アカウントがない？ 新規登録',
      switchToLogin: 'すでにアカウントがある？ ログイン',
      foot: 'PBKDF2 · パスワードは平文保存なし · 会話は平文 · 添付ファイルは暗号化',
      boot: '安全な接続を確認中…',
      errRequired: 'ユーザー名とパスワードを入力してください。',
      errUser: 'ユーザー名は3〜32文字で、空白・/・| を含められません。',
      errPolicy: 'パスワードは10文字以上で、大文字・小文字・数字・記号をすべて含めてください。',
      errConfirm: '確認用パスワードが一致しません。',
      errTaken: 'このユーザー名はすでに使われています。',
      errBad: 'ユーザー名またはパスワードが違います。',
      errNet: 'サーバーに接続できません。ネットワークを確認してください。',
      errCrypto: 'この端末では安全な暗号化を初期化できません。',
      busy: '暗号鍵を派生中…',
      loginBusy: 'ログイン中…',
      regBusy: '登録中…',
      logoutTitle: 'アカウントを削除',
      logoutBody: '削除すると、このアカウントのチャット・ファイル・データはサーバーから完全に削除されます。匿名化や復元はできません。',
      logoutCancel: 'キャンセル',
      logoutConfirm: '削除してログアウト',
      logoutMenu: 'アカウント削除',
      logoutBusy: '削除中…',
      logoutFail: '削除に失敗しました。もう一度お試しください。',
      signOutMenu: 'ログアウト',
      signOutTitle: 'ログアウト',
      signOutBody: 'この端末のログイン状態だけを終了します。アカウント・チャット・ナレッジ・ファイルはすべて保持され、次回ログインで続きを利用できます。',
      signOutCancel: 'キャンセル',
      signOutConfirm: 'ログアウト',
      signOutBusy: 'ログアウト中…',
      signOutFail: 'ログアウトに失敗しました。もう一度お試しください。',
      show: 'パスワードを表示',
      hide: 'パスワードを隠す',
      language: '言語'
    },
    zh: {
      page404: '404 · 页面不存在',
      page404sub: '此页面不存在，或您尚未登录。',
      titleLogin: '安全登录',
      titleRegister: '创建账号',
      subLogin: '登录后才会显示本账号的聊天、知识与文件；聊天正文按账号明文存储。',
      subRegister: '每个账号拥有独立的数据空间与登录隔离。',
      login: '登录',
      register: '注册',
      username: '用户名',
      usernamePh: '3–32 个字符 · 不可重复',
      password: '密码',
      passwordPh: '至少 10 位 · 含大小写、数字、符号',
      confirm: '确认密码',
      confirmPh: '再输入一次',
      ruleUser: '用户名 3–32 个字符（不能含空格 / |）',
      ruleLen: '至少 10 位',
      ruleUpper: '至少 1 个大写字母',
      ruleLower: '至少 1 个小写字母',
      ruleDigit: '至少 1 个数字',
      ruleSymbol: '至少 1 个符号',
      secure: '账号隔离',
      submitLogin: '登录并进入',
      submitRegister: '注册并进入',
      switchToRegister: '还没有账号？去注册',
      switchToLogin: '已有账号？去登录',
      foot: 'PBKDF2 · 密码永不明文 · 聊天明文 · 文件附件加密',
      boot: '正在确认安全连接…',
      errRequired: '请输入用户名和密码。',
      errUser: '用户名需为 3–32 个字符，且不能含空格、/、|。',
      errPolicy: '密码至少 10 位，且必须同时含大写、小写、数字、符号。',
      errConfirm: '两次输入的密码不一致。',
      errTaken: '该用户名已被占用。',
      errBad: '用户名或密码不正确。',
      errNet: '无法连接服务器，请检查网络。',
      errCrypto: '当前设备无法初始化安全加密。',
      busy: '正在派生加密密钥…',
      loginBusy: '正在登录…',
      regBusy: '正在注册…',
      logoutTitle: '注销账号',
      logoutBody: '注销后，此账号的全部聊天、文件与账号数据将从服务器彻底删除，不做匿名化，也无法恢复。',
      logoutCancel: '取消',
      logoutConfirm: '销毁并退出',
      logoutMenu: '注销账号',
      logoutBusy: '正在销毁…',
      logoutFail: '注销失败，请稍后重试。',
      signOutMenu: '退出登录',
      signOutTitle: '退出登录',
      signOutBody: '只结束这台设备的登录状态；账号、聊天、知识库与文件全部保留，重新登录即可继续。',
      signOutCancel: '取消',
      signOutConfirm: '退出登录',
      signOutBusy: '正在退出…',
      signOutFail: '退出登录失败，请稍后重试。',
      show: '显示密码',
      hide: '隐藏密码',
      language: '语言'
    },
    en: {
      page404: '404 · Page Not Found',
      page404sub: 'This page does not exist, or you are not signed in.',
      titleLogin: 'Secure sign-in',
      titleRegister: 'Create account',
      subLogin: 'Your account chats, knowledge and files appear only after sign-in. Chat text is stored per account as plaintext.',
      subRegister: 'Each account gets an isolated data space and login boundary.',
      login: 'Sign in',
      register: 'Register',
      username: 'Username',
      usernamePh: '3–32 chars · must be unique',
      password: 'Password',
      passwordPh: '10+ chars · upper, lower, digit, symbol',
      confirm: 'Confirm password',
      confirmPh: 'Enter it again',
      ruleUser: '3–32 chars (no spaces, / or |)',
      ruleLen: 'At least 10 characters',
      ruleUpper: 'At least one uppercase letter',
      ruleLower: 'At least one lowercase letter',
      ruleDigit: 'At least one digit',
      ruleSymbol: 'At least one symbol',
      secure: 'Account isolation',
      submitLogin: 'Sign in',
      submitRegister: 'Create & enter',
      switchToRegister: 'No account? Create one',
      switchToLogin: 'Already registered? Sign in',
      foot: 'PBKDF2 · passwords never plaintext · chats plaintext · attachments encrypted',
      boot: 'Checking secure connection…',
      errRequired: 'Please enter username and password.',
      errUser: 'Username must be 3–32 chars without spaces, / or |.',
      errPolicy: 'Password needs 10+ chars with upper, lower, digit and symbol.',
      errConfirm: 'The two passwords do not match.',
      errTaken: 'That username is already taken.',
      errBad: 'Incorrect username or password.',
      errNet: 'Cannot reach the server. Check your network.',
      errCrypto: 'This device cannot initialize secure encryption.',
      busy: 'Deriving encryption key…',
      loginBusy: 'Signing in…',
      regBusy: 'Creating account…',
      logoutTitle: 'Delete account',
      logoutBody: 'Deleting permanently destroys all chats, files and data for this account. Nothing is anonymized or recoverable.',
      logoutCancel: 'Cancel',
      logoutConfirm: 'Destroy & sign out',
      logoutMenu: 'Delete account',
      logoutBusy: 'Destroying…',
      logoutFail: 'Deletion failed. Please try again.',
      signOutMenu: 'Sign out',
      signOutTitle: 'Sign out',
      signOutBody: 'This only ends the session on this device. The account, chats, knowledge and files are all kept; sign in again to continue.',
      signOutCancel: 'Cancel',
      signOutConfirm: 'Sign out',
      signOutBusy: 'Signing out…',
      signOutFail: 'Sign-out failed. Please try again.',
      show: 'Show password',
      hide: 'Hide password',
      language: 'Language'
    },
    ko: {
      page404: '404 · 페이지를 찾을 수 없음',
      page404sub: '이 페이지가 없거나 로그인하지 않았습니다.',
      titleLogin: '안전 로그인',
      titleRegister: '계정 만들기',
      subLogin: '로그인 후에 이 계정의 대화·지식·파일이 표시됩니다. 대화 본문은 계정별로 평문 저장됩니다.',
      subRegister: '계정마다 독립된 데이터 공간과 로그인 경계를 제공합니다.',
      login: '로그인',
      register: '가입',
      username: '사용자 이름',
      usernamePh: '3–32자 · 중복 불가',
      password: '비밀번호',
      passwordPh: '10자 이상 · 대소문자·숫자·기호',
      confirm: '비밀번호 확인',
      confirmPh: '다시 입력',
      ruleUser: '사용자 이름 3–32자 (공백 / | 불가)',
      ruleLen: '10자 이상',
      ruleUpper: '대문자 1자 이상',
      ruleLower: '소문자 1자 이상',
      ruleDigit: '숫자 1자 이상',
      ruleSymbol: '기호 1자 이상',
      secure: '계정 격리',
      submitLogin: '로그인',
      submitRegister: '가입 후 시작',
      switchToRegister: '계정이 없나요? 가입하기',
      switchToLogin: '이미 계정이 있나요? 로그인',
      foot: 'PBKDF2 · 비밀번호 평문 저장 없음 · 대화 평문 · 첨부 파일 암호화',
      boot: '보안 연결 확인 중…',
      errRequired: '사용자 이름과 비밀번호를 입력해 주세요.',
      errUser: '사용자 이름은 3–32자이며 공백, /, |를 포함할 수 없습니다.',
      errPolicy: '비밀번호는 10자 이상이며 대문자·소문자·숫자·기호를 모두 포함해야 합니다.',
      errConfirm: '비밀번호 확인이 일치하지 않습니다.',
      errTaken: '이미 사용 중인 사용자 이름입니다.',
      errBad: '사용자 이름 또는 비밀번호가 올바르지 않습니다.',
      errNet: '서버에 연결할 수 없습니다. 네트워크를 확인하세요.',
      errCrypto: '이 기기에서 보안 암호화를 초기화할 수 없습니다.',
      busy: '암호화 키 생성 중…',
      loginBusy: '로그인 중…',
      regBusy: '가입 중…',
      logoutTitle: '계정 삭제',
      logoutBody: '삭제하면 이 계정의 모든 대화·파일·데이터가 서버에서 완전히 삭제됩니다. 익명화나 복구는 없습니다.',
      logoutCancel: '취소',
      logoutConfirm: '삭제하고 로그아웃',
      logoutMenu: '계정 삭제',
      logoutBusy: '삭제 중…',
      logoutFail: '삭제에 실패했습니다. 다시 시도해 주세요.',
      signOutMenu: '로그아웃',
      signOutTitle: '로그아웃',
      signOutBody: '이 기기의 로그인 상태만 종료합니다. 계정, 대화, 지식, 파일은 모두 보존되며 다시 로그인하면 이어서 사용할 수 있습니다.',
      signOutCancel: '취소',
      signOutConfirm: '로그아웃',
      signOutBusy: '로그아웃 중…',
      signOutFail: '로그아웃에 실패했습니다. 다시 시도해 주세요.',
      show: '비밀번호 보기',
      hide: '비밀번호 숨기기',
      language: '언어'
    },
    ru: {
      page404: '404 · Страница не найдена',
      page404sub: 'Этой страницы нет, или вы не вошли в аккаунт.',
      titleLogin: 'Безопасный вход',
      titleRegister: 'Создать аккаунт',
      subLogin: 'Чаты, знания и файлы этого аккаунта видны только после входа. Текст чатов хранится в открытом виде по аккаунтам.',
      subRegister: 'У каждого аккаунта отдельное пространство данных и граница входа.',
      login: 'Войти',
      register: 'Регистрация',
      username: 'Имя пользователя',
      usernamePh: '3–32 символа · без повторов',
      password: 'Пароль',
      passwordPh: '10+ символов · регистр, цифра, символ',
      confirm: 'Подтвердите пароль',
      confirmPh: 'Введите ещё раз',
      ruleUser: '3–32 символа (без пробелов, / и |)',
      ruleLen: 'Не менее 10 символов',
      ruleUpper: 'Хотя бы одна заглавная буква',
      ruleLower: 'Хотя бы одна строчная буква',
      ruleDigit: 'Хотя бы одна цифра',
      ruleSymbol: 'Хотя бы один символ',
      secure: 'Изоляция аккаунта',
      submitLogin: 'Войти',
      submitRegister: 'Создать и войти',
      switchToRegister: 'Нет аккаунта? Создать',
      switchToLogin: 'Уже есть аккаунт? Войти',
      foot: 'PBKDF2 · пароль не в открытом виде · чаты в открытом виде · вложения зашифрованы',
      boot: 'Проверка защищённого соединения…',
      errRequired: 'Введите имя пользователя и пароль.',
      errUser: 'Имя: 3–32 символа без пробелов, / и |.',
      errPolicy: 'Пароль: 10+ символов, заглавная, строчная, цифра и символ.',
      errConfirm: 'Пароли не совпадают.',
      errTaken: 'Это имя уже занято.',
      errBad: 'Неверное имя пользователя или пароль.',
      errNet: 'Нет связи с сервером. Проверьте сеть.',
      errCrypto: 'Это устройство не может включить безопасное шифрование.',
      busy: 'Генерация ключа шифрования…',
      loginBusy: 'Вход…',
      regBusy: 'Регистрация…',
      logoutTitle: 'Удалить аккаунт',
      logoutBody: 'При удалении все чаты, файлы и данные этого аккаунта безвозвратно удаляются с сервера. Анонимизации и восстановления нет.',
      logoutCancel: 'Отмена',
      logoutConfirm: 'Удалить и выйти',
      logoutMenu: 'Удалить аккаунт',
      logoutBusy: 'Удаление…',
      logoutFail: 'Не удалось удалить. Попробуйте снова.',
      signOutMenu: 'Выйти',
      signOutTitle: 'Выйти из аккаунта',
      signOutBody: 'Завершается только сеанс на этом устройстве. Аккаунт, чаты, база знаний и файлы сохраняются — войдите снова, чтобы продолжить.',
      signOutCancel: 'Отмена',
      signOutConfirm: 'Выйти',
      signOutBusy: 'Выход…',
      signOutFail: 'Не удалось выйти. Попробуйте снова.',
      show: 'Показать пароль',
      hide: 'Скрыть пароль',
      language: 'Язык'
    },
    fr: {
      page404: '404 · Page introuvable',
      page404sub: 'Cette page n’existe pas, ou vous n’êtes pas connecté.',
      titleLogin: 'Connexion sécurisée',
      titleRegister: 'Créer un compte',
      subLogin: 'Les discussions, connaissances et fichiers de ce compte ne s’affichent qu’après connexion. Le texte des discussions est stocké en clair par compte.',
      subRegister: 'Chaque compte dispose d’un espace de données et d’une frontière de connexion isolés.',
      login: 'Connexion',
      register: 'Inscription',
      username: 'Nom d’utilisateur',
      usernamePh: '3–32 caractères · unique',
      password: 'Mot de passe',
      passwordPh: '10+ caractères · majuscule, minuscule, chiffre, symbole',
      confirm: 'Confirmer le mot de passe',
      confirmPh: 'Saisissez-le à nouveau',
      ruleUser: '3–32 caractères (sans espace, / ni |)',
      ruleLen: 'Au moins 10 caractères',
      ruleUpper: 'Au moins une majuscule',
      ruleLower: 'Au moins une minuscule',
      ruleDigit: 'Au moins un chiffre',
      ruleSymbol: 'Au moins un symbole',
      secure: 'Isolation du compte',
      submitLogin: 'Se connecter',
      submitRegister: 'Créer et entrer',
      switchToRegister: 'Pas de compte ? Créer',
      switchToLogin: 'Déjà inscrit ? Connexion',
      foot: 'PBKDF2 · mot de passe jamais en clair · discussions en clair · pièces jointes chiffrées',
      boot: 'Vérification de la connexion sécurisée…',
      errRequired: 'Saisissez le nom d’utilisateur et le mot de passe.',
      errUser: 'Le nom doit faire 3–32 caractères sans espace, / ou |.',
      errPolicy: 'Le mot de passe doit faire 10+ caractères avec majuscule, minuscule, chiffre et symbole.',
      errConfirm: 'Les deux mots de passe ne correspondent pas.',
      errTaken: 'Ce nom d’utilisateur est déjà pris.',
      errBad: 'Nom d’utilisateur ou mot de passe incorrect.',
      errNet: 'Serveur inaccessible. Vérifiez le réseau.',
      errCrypto: 'Cet appareil ne peut pas initialiser le chiffrement sécurisé.',
      busy: 'Dérivation de la clé…',
      loginBusy: 'Connexion…',
      regBusy: 'Inscription…',
      logoutTitle: 'Supprimer le compte',
      logoutBody: 'La suppression détruit définitivement toutes les discussions, fichiers et données de ce compte. Aucune anonymisation ni restauration.',
      logoutCancel: 'Annuler',
      logoutConfirm: 'Détruire et quitter',
      logoutMenu: 'Supprimer le compte',
      logoutBusy: 'Suppression…',
      logoutFail: 'Échec de la suppression. Réessayez.',
      signOutMenu: 'Déconnexion',
      signOutTitle: 'Se déconnecter',
      signOutBody: 'Seule la session sur cet appareil est fermée. Le compte, les discussions, la base de connaissances et les fichiers sont conservés ; reconnectez-vous pour continuer.',
      signOutCancel: 'Annuler',
      signOutConfirm: 'Se déconnecter',
      signOutBusy: 'Déconnexion…',
      signOutFail: 'Échec de la déconnexion. Réessayez.',
      show: 'Afficher le mot de passe',
      hide: 'Masquer le mot de passe',
      language: 'Langue'
    }
  };

  var state = {
    lang: 'zh',
    mode: 'login',
    authenticated: false,
    user: null,
    gate: null,
    built: false,
    checking: true,
    authReady: false,
    shown404: false
  };

  function lm(key) {
    var d = I18N[state.lang] || I18N.zh;
    return d[key] || I18N.en[key] || key;
  }

  function readLang() {
    try {
      var saved = localStorage.getItem(LANG_KEY);
      if (saved && SUPPORTED.indexOf(saved) >= 0) return saved;
    } catch (e) {}
    return 'zh';
  }

  function setLanguage(code) {
    if (SUPPORTED.indexOf(code) < 0) return;
    try { localStorage.setItem(LANG_KEY, code); } catch (e) {}
    state.lang = code;
    // 用户要求：选择后立即刷新页面。
    global.location.reload();
  }

  // ------------------------------------------------------------
  // 纯 JS SHA-256 + HMAC + PBKDF2（WebCrypto 不可用时的同算法后备）
  // ------------------------------------------------------------
  var SHA_K = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  ];

  function rotr(x, n) { return ((x >>> n) | (x << (32 - n))) >>> 0; }

  function sha256(bytes) {
    var msg = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    var len = msg.length;
    var bitLen = len * 8;
    var withOne = len + 1;
    var pad = (withOne % 64 <= 56) ? 56 - (withOne % 64) : 120 - (withOne % 64);
    var total = withOne + pad + 8;
    var buf = new Uint8Array(total);
    buf.set(msg);
    buf[len] = 0x80;
    var hi = Math.floor(bitLen / 0x100000000);
    var lo = bitLen >>> 0;
    buf[total - 8] = (hi >>> 24) & 255;
    buf[total - 7] = (hi >>> 16) & 255;
    buf[total - 6] = (hi >>> 8) & 255;
    buf[total - 5] = hi & 255;
    buf[total - 4] = (lo >>> 24) & 255;
    buf[total - 3] = (lo >>> 16) & 255;
    buf[total - 2] = (lo >>> 8) & 255;
    buf[total - 1] = lo & 255;

    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
    var w = new Uint32Array(64);

    for (var off = 0; off < total; off += 64) {
      for (var i = 0; i < 16; i++) {
        var j = off + i * 4;
        w[i] = ((buf[j] << 24) | (buf[j + 1] << 16) | (buf[j + 2] << 8) | buf[j + 3]) >>> 0;
      }
      for (var i2 = 16; i2 < 64; i2++) {
        var x = w[i2 - 15], y = w[i2 - 2];
        var s0 = (rotr(x, 7) ^ rotr(x, 18) ^ (x >>> 3)) >>> 0;
        var s1 = (rotr(y, 17) ^ rotr(y, 19) ^ (y >>> 10)) >>> 0;
        w[i2] = (w[i2 - 16] + s0 + w[i2 - 7] + s1) >>> 0;
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var i3 = 0; i3 < 64; i3++) {
        var S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
        var ch = ((e & f) ^ ((~e) & g)) >>> 0;
        var t1 = (h + S1 + ch + SHA_K[i3] + w[i3]) >>> 0;
        var S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
        var maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
        var t2 = (S0 + maj) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0;
        d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0;
      h4 = (h4 + e) >>> 0; h5 = (h5 + f) >>> 0; h6 = (h6 + g) >>> 0; h7 = (h7 + h) >>> 0;
    }
    var out = new Uint8Array(32);
    [h0, h1, h2, h3, h4, h5, h6, h7].forEach(function (v, i) {
      out[i * 4] = (v >>> 24) & 255;
      out[i * 4 + 1] = (v >>> 16) & 255;
      out[i * 4 + 2] = (v >>> 8) & 255;
      out[i * 4 + 3] = v & 255;
    });
    return out;
  }

  function concatBytes() {
    var total = 0, i;
    for (i = 0; i < arguments.length; i++) total += arguments[i].length;
    var out = new Uint8Array(total), off = 0;
    for (i = 0; i < arguments.length; i++) {
      out.set(arguments[i], off);
      off += arguments[i].length;
    }
    return out;
  }

  function hmacSha256(key, msg) {
    var k = key instanceof Uint8Array ? key : new Uint8Array(key);
    if (k.length > 64) k = sha256(k);
    var ipad = new Uint8Array(64);
    var opad = new Uint8Array(64);
    for (var i = 0; i < 64; i++) {
      var b = i < k.length ? k[i] : 0;
      ipad[i] = b ^ 0x36;
      opad[i] = b ^ 0x5c;
    }
    return sha256(concatBytes(opad, sha256(concatBytes(ipad, msg))));
  }

  function pbkdf2Sha256(passwordBytes, saltBytes, iterations) {
    var block = concatBytes(saltBytes, new Uint8Array([0, 0, 0, 1]));
    var u = hmacSha256(passwordBytes, block);
    var t = new Uint8Array(u);
    for (var i = 1; i < iterations; i++) {
      u = hmacSha256(passwordBytes, u);
      for (var j = 0; j < t.length; j++) t[j] ^= u[j];
    }
    return t;
  }

  function b64(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return global.btoa(s);
  }

  function deriveVerifier(username, password) {
    var saltText = 'KEWE-AUTH-V1|' + username.toLowerCase() + '|kewe-auth-salt-v1';
    var iterations = 30000;
    var enc = new TextEncoder();
    var passBytes = enc.encode(password);
    var saltBytes = enc.encode(saltText);
    if (global.crypto && global.crypto.subtle && global.isSecureContext !== false) {
      return global.crypto.subtle.importKey('raw', passBytes, 'PBKDF2', false, ['deriveBits'])
        .then(function (key) {
          return global.crypto.subtle.deriveBits({
            name: 'PBKDF2',
            salt: saltBytes,
            iterations: iterations,
            hash: 'SHA-256'
          }, key, 256);
        })
        .then(function (bits) { return b64(new Uint8Array(bits)); })
        .catch(function () {
          return b64(pbkdf2Sha256(passBytes, saltBytes, iterations));
        });
    }
    return new Promise(function (resolve) {
      setTimeout(function () { resolve(b64(pbkdf2Sha256(passBytes, saltBytes, iterations))); }, 20);
    });
  }

  // ------------------------------------------------------------
  // 密码规则
  // ------------------------------------------------------------
  function passwordRules(pw) {
    return {
      len: pw.length >= 10 && pw.length <= 128,
      upper: /[A-Z]/.test(pw),
      lower: /[a-z]/.test(pw),
      digit: /[0-9]/.test(pw),
      symbol: /[^A-Za-z0-9]/.test(pw)
    };
  }

  function passwordOk(pw) {
    var r = passwordRules(pw);
    return r.len && r.upper && r.lower && r.digit && r.symbol;
  }

  function usernameOk(name) {
    var n = String(name || '').trim();
    var len = Array.from(n).length;
    return len >= 3 && len <= 32 && !/[\s|\\/\u0000-\u001f\u007f]/.test(n);
  }

  // ------------------------------------------------------------
  // SVG
  // ------------------------------------------------------------
  var SVG = {
    mark: '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M4.2 15.7c-1.4-2.4-.6-6 2.6-8.4 3.2-2.4 7.2-2.2 10.1.1 2.9 2.3 3.5 6.1 1.3 8.6-2.1 2.4-6 3.2-9.4 2.2" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/><circle cx="9.2" cy="11.7" r="1" fill="#fff"/><circle cx="14.9" cy="11.7" r="1" fill="#fff"/><path d="M10.3 15c1 .8 2.5.8 3.5 0" stroke="#fff" stroke-width="1.55" stroke-linecap="round"/><path d="M18.8 2.7l.55 1.55 1.55.55-1.55.55-.55 1.55-.55-1.55-1.55-.55 1.55-.55z" fill="#fde68a"/></svg>',
    globe: '<svg class="globe" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="12" cy="12" r="8.2" stroke="currentColor" stroke-width="1.6"/><ellipse cx="12" cy="12" rx="4" ry="8.2" stroke="currentColor" stroke-width="1.2" opacity=".8"/><path d="M4.4 9h15.2M4.4 15h15.2" stroke="currentColor" stroke-width="1.2" opacity=".8"/></svg>',
    user: '<svg class="pre" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="8" r="3.5" stroke="currentColor" stroke-width="1.7"/><path d="M5.5 19c.5-3 3-5 6.5-5s6 2 6.5 5" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    lock: '<svg class="pre" viewBox="0 0 24 24" fill="none"><rect x="5" y="10" width="14" height="10" rx="3" stroke="currentColor" stroke-width="1.7"/><path d="M8.5 10V7.5a3.5 3.5 0 017 0V10" stroke="currentColor" stroke-width="1.7"/><circle cx="12" cy="15" r="1.2" fill="currentColor"/></svg>',
    shield: '<svg viewBox="0 0 24 24" fill="none"><path d="M12 3l7 2.8v5.4c0 4.7-3 7.8-7 9.8-4-2-7-5.1-7-9.8V5.8L12 3z" stroke="currentColor" stroke-width="1.5" fill="none"/><path d="M8.8 12l2.1 2.1 4.4-4.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
    eye: '<svg viewBox="0 0 24 24" fill="none"><path d="M3.2 12s3.4-5.3 8.8-5.3 8.8 5.3 8.8 5.3-3.4 5.3-8.8 5.3S3.2 12 3.2 12z" stroke="currentColor" stroke-width="1.5"/><circle cx="12" cy="12" r="2.5" stroke="currentColor" stroke-width="1.5"/></svg>',
    eyeOff: '<svg viewBox="0 0 24 24" fill="none"><path d="M3.5 4.5l17 15" stroke="currentColor" stroke-width="1.6"/><path d="M7 7.4C4.7 9.3 3.2 12 3.2 12s3.4 5.3 8.8 5.3c1.2 0 2.3-.2 3.3-.7M10.2 6.9c.6-.1 1.2-.2 1.8-.2 5.4 0 8.8 5.3 8.8 5.3s-1.2 1.9-3.2 3.6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'
  };

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  }

  // ------------------------------------------------------------
  // 门禁 UI
  // ------------------------------------------------------------
  function languageMenu() {
    var wrap = el('div', 'kewe-auth-lang');
    var btn = el('button', 'kewe-auth-lang-btn');
    btn.type = 'button';
    btn.setAttribute('aria-label', lm('language'));
    btn.setAttribute('aria-haspopup', 'true');
    btn.innerHTML = SVG.globe + '<span>' + (LANG_META[state.lang] || LANG_META.zh).code + '</span>';
    var menu = el('div', 'kewe-auth-lang-menu');
    menu.id = 'keweAuthLangMenu';
    btn.setAttribute('aria-controls', menu.id);
    SUPPORTED.forEach(function (code) {
      var item = el('button', 'kewe-auth-lang-item' + (code === state.lang ? ' active' : ''));
      item.type = 'button';
      item.innerHTML = '<span>' + LANG_META[code].flag + '</span><span>' + LANG_META[code].label + '</span><span class="code">' + LANG_META[code].code + '</span>';
      item.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        setLanguage(code);
      });
      menu.appendChild(item);
    });
    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      menu.classList.toggle('open');
      btn.setAttribute('aria-expanded', menu.classList.contains('open') ? 'true' : 'false');
    });
    document.addEventListener('click', function () { menu.classList.remove('open'); btn.setAttribute('aria-expanded', 'false'); }, true);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && menu.classList.contains('open')) {
        menu.classList.remove('open'); btn.setAttribute('aria-expanded', 'false');
      }
    });
    global.addEventListener('resize', function () {
      menu.classList.remove('open'); btn.setAttribute('aria-expanded', 'false');
    }, { passive: true });
    wrap.appendChild(btn);
    wrap.appendChild(menu);
    return wrap;
  }

  function buildGate() {
    if (state.built) return state.gate;
    state.built = true;

    var gate = el('div', 'kewe-auth-gate');
    gate.id = 'keweAuthGate';
    gate.setAttribute('role', 'dialog');
    gate.setAttribute('aria-modal', 'true');

    var aurora = el('div', 'kewe-auth-aurora');
    aurora.setAttribute('aria-hidden', 'true');
    gate.appendChild(aurora);

    var card = el('div', 'kewe-auth-card');
    card.id = 'keweAuthCard';

    var brand = el('div', 'kewe-auth-brand');
    var mark = el('div', 'kewe-auth-mark');
    mark.innerHTML = SVG.mark;
    brand.appendChild(mark);
    var copy = el('div', 'kewe-auth-brand-copy');
    copy.innerHTML = '<strong>KEWE / 聚维</strong><small>private workspace</small>';
    brand.appendChild(copy);
    brand.appendChild(languageMenu());
    card.appendChild(brand);

    var titleRow = el('div', 'kewe-auth-title-row');
    var tx = el('div', 'kewe-auth-title-block');
    var title = el('h1', 'kewe-auth-title', lm(state.mode === 'register' ? 'titleRegister' : 'titleLogin'));
    title.id = 'keweAuthTitle';
    var sub = el('p', 'kewe-auth-sub', lm(state.mode === 'register' ? 'subRegister' : 'subLogin'));
    sub.id = 'keweAuthSub';
    tx.appendChild(title);
    tx.appendChild(sub);
    var secure = el('div', 'kewe-auth-secure');
    secure.innerHTML = SVG.shield + '<span>' + lm('secure') + '</span>';
    tx.appendChild(secure);
    titleRow.appendChild(tx);
    card.appendChild(titleRow);

    var tabs = el('div', 'kewe-auth-tabs');
    var loginTab = el('button', 'kewe-auth-tab' + (state.mode === 'login' ? ' active' : ''), lm('login'));
    loginTab.type = 'button';
    loginTab.setAttribute('data-mode', 'login');
    var regTab = el('button', 'kewe-auth-tab' + (state.mode === 'register' ? ' active' : ''), lm('register'));
    regTab.type = 'button';
    regTab.setAttribute('data-mode', 'register');
    tabs.appendChild(loginTab);
    tabs.appendChild(regTab);
    card.appendChild(tabs);

    var form = el('form', 'kewe-auth-form');
    form.id = 'keweAuthForm';
    form.autocomplete = 'on';

    var userField = el('div', 'kewe-auth-field');
    var userLabel = el('label', 'kewe-auth-label', lm('username'));
    userLabel.htmlFor = 'keweAuthUsername';
    userField.appendChild(userLabel);
    var userWrap = el('div', 'kewe-auth-input-wrap');
    userWrap.innerHTML = SVG.user;
    var userInput = el('input');
    userInput.id = 'keweAuthUsername';
    userInput.name = 'username';
    userInput.type = 'text';
    userInput.autocomplete = 'username';
    userInput.maxLength = 32;
    userInput.placeholder = lm('usernamePh');
    userInput.spellcheck = false;
    userWrap.appendChild(userInput);
    userField.appendChild(userWrap);
    form.appendChild(userField);

    var passField = el('div', 'kewe-auth-field');
    var passLabel = el('label', 'kewe-auth-label', lm('password'));
    passLabel.htmlFor = 'keweAuthPassword';
    passField.appendChild(passLabel);
    var passWrap = el('div', 'kewe-auth-input-wrap');
    passWrap.innerHTML = SVG.lock;
    var passInput = el('input');
    passInput.id = 'keweAuthPassword';
    passInput.name = 'password';
    passInput.type = 'password';
    passInput.autocomplete = state.mode === 'register' ? 'new-password' : 'current-password';
    passInput.maxLength = 128;
    passInput.placeholder = lm('passwordPh');
    passWrap.appendChild(passInput);
    var eye = el('button', 'kewe-auth-eye');
    eye.type = 'button';
    eye.setAttribute('aria-label', lm('show'));
    eye.innerHTML = SVG.eye;
    eye.addEventListener('click', function (e) {
      e.preventDefault();
      var show = passInput.type === 'password';
      passInput.type = show ? 'text' : 'password';
      eye.innerHTML = show ? SVG.eyeOff : SVG.eye;
      eye.setAttribute('aria-label', show ? lm('hide') : lm('show'));
    });
    passWrap.appendChild(eye);
    passField.appendChild(passWrap);
    form.appendChild(passField);

    var confirmField = el('div', 'kewe-auth-field');
    confirmField.id = 'keweAuthConfirmField';
    confirmField.style.display = state.mode === 'register' ? 'grid' : 'none';
    var confirmLabel = el('label', 'kewe-auth-label', lm('confirm'));
    confirmLabel.htmlFor = 'keweAuthConfirm';
    confirmField.appendChild(confirmLabel);
    var confirmWrap = el('div', 'kewe-auth-input-wrap');
    confirmWrap.innerHTML = SVG.lock;
    var confirmInput = el('input');
    confirmInput.id = 'keweAuthConfirm';
    confirmInput.type = 'password';
    confirmInput.autocomplete = 'new-password';
    confirmInput.maxLength = 128;
    confirmInput.placeholder = lm('confirmPh');
    confirmWrap.appendChild(confirmInput);
    confirmField.appendChild(confirmWrap);
    form.appendChild(confirmField);

    var rules = el('div', 'kewe-auth-rules');
    rules.id = 'keweAuthRules';
    rules.style.display = state.mode === 'register' ? 'grid' : 'none';
    var ruleIds = [
      ['user', lm('ruleUser'), 'u'],
      ['len', lm('ruleLen'), 'l'],
      ['upper', lm('ruleUpper'), 'l'],
      ['lower', lm('ruleLower'), 'l'],
      ['digit', lm('ruleDigit'), 'l'],
      ['symbol', lm('ruleSymbol'), 'l']
    ];
    ruleIds.forEach(function (r) {
      var row = el('div', 'kewe-auth-rule');
      row.setAttribute('data-rule', r[0] + ':' + r[2]);
      row.innerHTML = '<span class="dot">✓</span><span>' + r[1] + '</span>';
      rules.appendChild(row);
    });
    form.appendChild(rules);

    var err = el('div', 'kewe-auth-error');
    err.id = 'keweAuthError';
    form.appendChild(err);

    var submit = el('button', 'kewe-auth-submit', lm(state.mode === 'register' ? 'submitRegister' : 'submitLogin'));
    submit.type = 'submit';
    submit.id = 'keweAuthSubmit';
    form.appendChild(submit);

    card.appendChild(form);

    var switchLine = el('div', 'kewe-auth-switch');
    var switchBtn = el('button', '', lm(state.mode === 'register' ? 'switchToLogin' : 'switchToRegister'));
    switchBtn.type = 'button';
    switchBtn.addEventListener('click', function (e) {
      e.preventDefault();
      setMode(state.mode === 'register' ? 'login' : 'register');
    });
    switchLine.appendChild(switchBtn);
    card.appendChild(switchLine);

    var boot = el('div', 'kewe-auth-boot');
    boot.id = 'keweAuthBoot';
    boot.innerHTML = '<span class="ring"></span><span>' + lm('boot') + '</span>';
    boot.style.display = 'none';
    card.appendChild(boot);

    var foot = el('div', 'kewe-auth-foot');
    foot.innerHTML = SVG.shield + '<span>' + lm('foot') + '</span>';
    card.appendChild(foot);

    gate.appendChild(card);
    document.body.appendChild(gate);

    tabs.addEventListener('click', function (e) {
      var t = e.target.closest ? e.target.closest('.kewe-auth-tab') : null;
      if (!t) return;
      e.preventDefault();
      setMode(t.getAttribute('data-mode'));
    });

    passInput.addEventListener('input', function () { updateRules(); });
    userInput.addEventListener('input', function () {
      var len = Array.from(userInput.value.trim()).length;
      var count = document.getElementById('keweAuthUserCount');
      if (count) count.textContent = len + '/32';
      updateRules();
    });
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      submitForm();
    });

    state.gate = gate;
    // 认证状态返回前不显示登录表单，避免刷新/切换语言时“登录页一闪而过”。
    // showGate() 会在确认未登录后把它切回 flex。
    gate.style.display = 'none';
    state.inputs = {
      user: userInput, pass: passInput, confirm: confirmInput,
      submit: submit, err: err, rules: rules, boot: boot
    };
    updateRules();
    return gate;
  }

  function updateRules() {
    if (!state.inputs) return;
    var pw = state.inputs.pass.value;
    var name = state.inputs.user.value.trim();
    var r = passwordRules(pw);
    var checks = {
      user: usernameOk(name),
      len: r.len, upper: r.upper, lower: r.lower, digit: r.digit, symbol: r.symbol
    };
    var rows = state.inputs.rules.querySelectorAll('.kewe-auth-rule');
    for (var i = 0; i < rows.length; i++) {
      var spec = (rows[i].getAttribute('data-rule') || '').split(':');
      var ok = !!checks[spec[0]];
      rows[i].classList.toggle('ok', ok);
    }
  }

  function setMode(mode) {
    if (!state.inputs) return;
    state.mode = mode === 'register' ? 'register' : 'login';
    var reg = state.mode === 'register';
    document.getElementById('keweAuthTitle').textContent = lm(reg ? 'titleRegister' : 'titleLogin');
    document.getElementById('keweAuthSub').textContent = lm(reg ? 'subRegister' : 'subLogin');
    document.getElementById('keweAuthConfirmField').style.display = reg ? 'grid' : 'none';
    document.getElementById('keweAuthRules').style.display = reg ? 'grid' : 'none';
    document.getElementById('keweAuthSubmit').textContent = lm(reg ? 'submitRegister' : 'submitLogin');
    var tabs = document.querySelectorAll('.kewe-auth-tab');
    for (var i = 0; i < tabs.length; i++) tabs[i].classList.toggle('active', tabs[i].getAttribute('data-mode') === state.mode);
    var sw = document.querySelector('.kewe-auth-switch button');
    if (sw) sw.textContent = lm(reg ? 'switchToLogin' : 'switchToRegister');
    state.inputs.pass.autocomplete = reg ? 'new-password' : 'current-password';
    hideError();
    updateRules();
  }

  function showError(msg) {
    if (!state.inputs) return;
    state.inputs.err.textContent = msg;
    state.inputs.err.classList.add('show');
  }
  function hideError() {
    if (!state.inputs) return;
    state.inputs.err.classList.remove('show');
    state.inputs.err.textContent = '';
  }

  function setBusy(busy, text) {
    if (!state.inputs) return;
    state.inputs.submit.disabled = !!busy;
    state.inputs.submit.textContent = text || lm(state.mode === 'register' ? 'submitRegister' : 'submitLogin');
    state.inputs.boot.style.display = busy ? 'grid' : 'none';
    state.inputs.boot.querySelector('span:last-child').textContent = busy ? (text || lm('busy')) : lm('boot');
  }

  function api(path, body) {
    return fetch(path, {
      method: 'POST',
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        return { status: res.status, data: data };
      });
    });
  }

  function submitForm() {
    if (!state.inputs) return;
    hideError();
    var username = state.inputs.user.value.trim();
    var password = state.inputs.pass.value;
    var confirm = state.inputs.confirm.value;

    if (!username || !password) { showError(lm('errRequired')); return; }
    if (!usernameOk(username)) { showError(lm('errUser')); return; }
    if (!passwordOk(password)) { showError(lm('errPolicy')); return; }
    if (state.mode === 'register' && password !== confirm) {
      showError(lm('errConfirm'));
      return;
    }

    setBusy(true, lm('busy'));
    var started = Date.now();
    deriveVerifier(username, password).then(function (verifier) {
      var wait = Math.max(0, 120 - (Date.now() - started));
      setTimeout(function () {
        setBusy(true, lm(state.mode === 'register' ? 'regBusy' : 'loginBusy'));
        var path = state.mode === 'register' ? '/api/auth/register' : '/api/auth/login';
        api(path, { username: username, verifier: verifier }).then(function (r) {
          if (r.status >= 200 && r.status < 300 && r.data && r.data.ok) {
            state.authenticated = true;
            state.user = r.data.user || null;
            try { sessionStorage.setItem('kewe_just_authed', '1'); } catch (e) {}
            global.location.reload();
            return;
          }
          setBusy(false);
          var code = r.data && r.data.code;
          if (code === 'username_taken') showError(lm('errTaken'));
          else if (code === 'bad_credentials') showError(lm('errBad'));
          else showError((r.data && r.data.error) || lm('errNet'));
        }).catch(function () {
          setBusy(false);
          showError(lm('errNet'));
        });
      }, wait);
    }).catch(function () {
      setBusy(false);
      showError(lm('errCrypto'));
    });
  }

  function showGate(reason) {
    state.checking = false;
    if (document.body) buildGate();
    if (state.gate) {
      state.gate.style.display = 'flex';
    }
    try { document.documentElement.classList.add('kewe-auth-locked'); } catch (e) {}
  }

  function hideGate() {
    state.checking = false;
    if (state.gate) state.gate.style.display = 'none';
    try { document.documentElement.classList.remove('kewe-auth-locked'); } catch (e) {}
  }

  // ------------------------------------------------------------
  // 未登录 404：所有业务 API 都会带 X-Kewe-Auth
  // ------------------------------------------------------------
  function patchFetch() {
    if (!global.fetch || global.fetch.__keweAuthPatched) return;
    var orig = global.fetch;
    var wrapped = function (input, init) {
      var url = typeof input === 'string' ? input : ((input && input.url) || '');
      return orig.call(global, input, init).then(function (res) {
        try {
          if (res.status === 404 &&
              res.headers.get('X-Kewe-Auth') === 'required' &&
              url.indexOf('/api/auth/status') < 0) {
            state.authenticated = false;
            if (!state.shown404) {
              state.shown404 = true;
              setTimeout(function () { showGate('expired'); }, 0);
            }
          }
        } catch (e) {}
        return res;
      });
    };
    wrapped.__keweAuthPatched = true;
    global.fetch = wrapped;
  }

  // ------------------------------------------------------------
  // 账号菜单：退出登录（保留数据） / 注销账号（销毁数据）
  // ------------------------------------------------------------
  function injectAccountMenu() {
    if (!state.authenticated) return;
    var menu = document.getElementById('dscMoreMenu');
    if (!menu) return;

    // 退出登录：只结束会话，账号与数据全部保留。
    if (!document.getElementById('keweSignOutBtn')) {
      var out = el('button', 'dsc-more-item kewe-signout-item');
      out.id = 'keweSignOutBtn';
      out.type = 'button';
      out.title = lm('signOutMenu');
      out.innerHTML = '<span class="ic">👤</span><span class="tx"></span>';
      out.querySelector('.tx').textContent = lm('signOutMenu');
      out.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        openSignOutConfirm();
      });
      menu.appendChild(out);
    }

    // 注销账号：不可逆，走到下面红色的销毁确认。
    if (!document.getElementById('keweLogoutBtn')) {
      var del = el('button', 'dsc-more-item kewe-delete-item');
      del.id = 'keweLogoutBtn';
      del.type = 'button';
      del.title = lm('logoutMenu');
      del.innerHTML = '<span class="ic">⚠️</span><span class="tx"></span>';
      del.querySelector('.tx').textContent = lm('logoutMenu');
      del.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        openDeleteConfirm();
      });
      menu.appendChild(del);
    }
  }

  function clearLocalKeepLang(purgeAll) {
    try {
      var keepLang = localStorage.getItem(LANG_KEY);
      // 普通“退出登录”只结束会话，不清浏览器里的个人设置；
      // 否则 dsc_reasoningLevel、dsdt_active_inject_ids 等会被误清成默认值。
      // 只有“注销账号”这种不可逆操作才清空整个 localStorage。
      if (purgeAll) {
        localStorage.clear();
        if (keepLang) localStorage.setItem(LANG_KEY, keepLang);
      }
      sessionStorage.clear();
    } catch (e) {}
  }

  // 通用确认框：tone=safe 用于退出登录，tone=danger 用于注销账号。
  function openConfirm(opts) {
    if (document.getElementById(opts.id)) return;
    var overlay = el('div', 'kewe-logout-overlay');
    overlay.id = opts.id;
    var card = el('div', 'kewe-logout-card' + (opts.tone === 'safe' ? ' kewe-confirm-safe' : ''));
    card.innerHTML =
      '<div class="ico">' + opts.icon + '</div>' +
      '<h3></h3><p></p>' +
      '<div class="kewe-logout-actions">' +
      '<button type="button" class="kewe-logout-cancel"></button>' +
      '<button type="button" class="kewe-logout-confirm"></button>' +
      '</div>';
    card.querySelector('h3').textContent = opts.title;
    card.querySelector('p').textContent = opts.body;
    var cancel = card.querySelector('.kewe-logout-cancel');
    cancel.textContent = opts.cancel;
    var confirm = card.querySelector('.kewe-logout-confirm');
    confirm.textContent = opts.confirm;
    if (opts.tone === 'safe') confirm.classList.add('kewe-confirm-safe-btn');
    cancel.addEventListener('click', function () { overlay.remove(); });
    overlay.addEventListener('click', function (e) { if (e.target === overlay) overlay.remove(); });
    confirm.addEventListener('click', function () {
      cancel.disabled = true;
      confirm.disabled = true;
      confirm.textContent = opts.busy;
      api(opts.endpoint, {}).then(function (r) {
        if (r.status >= 200 && r.status < 300) {
          // 服务端已清 Cookie；普通退出只清会话状态，注销账号才清本机数据。
          clearLocalKeepLang(!!opts.purgeLocal);
          global.location.reload();
        } else {
          overlay.remove();
          if (global.dscToast) global.dscToast(opts.fail, 'error');
          else global.alert(opts.fail);
        }
      }).catch(function () {
        overlay.remove();
        if (global.dscToast) global.dscToast(opts.fail, 'error');
        else global.alert(opts.fail);
      });
    });
    overlay.appendChild(card);
    document.body.appendChild(overlay);
  }

  function openSignOutConfirm() {
    openConfirm({
      id: 'keweSignOutOverlay',
      tone: 'safe',
      purgeLocal: false,
      icon: '👤',
      endpoint: '/api/auth/logout',
      title: lm('signOutTitle'),
      body: lm('signOutBody'),
      cancel: lm('signOutCancel'),
      confirm: lm('signOutConfirm'),
      busy: lm('signOutBusy'),
      fail: lm('signOutFail')
    });
  }

  function openDeleteConfirm() {
    openConfirm({
      id: 'keweLogoutOverlay',
      tone: 'danger',
      purgeLocal: true,
      icon: '⚠️',
      endpoint: '/api/auth/delete',
      title: lm('logoutTitle'),
      body: lm('logoutBody'),
      cancel: lm('logoutCancel'),
      confirm: lm('logoutConfirm'),
      busy: lm('logoutBusy'),
      fail: lm('logoutFail')
    });
  }

  // ------------------------------------------------------------
  // 启动
  // ------------------------------------------------------------
  function checkSession() {
    return fetch('/api/auth/status', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          state.authReady = true;
          if (res.ok && data && data.authenticated) {
            state.authenticated = true;
            state.user = data.user || null;
            hideGate();
            setTimeout(injectAccountMenu, 50);
            setTimeout(injectAccountMenu, 900);
          } else {
            state.authenticated = false;
            showGate();
          }
        });
      })
      .catch(function () {
        state.authReady = true;
        state.authenticated = false;
        showGate();
      });
  }

  function boot() {
    state.lang = readLang();
    patchFetch();
    try { document.documentElement.classList.add('kewe-auth-locked'); } catch (e) {}
    // 首屏先挡住应用，但登录表单保持隐藏：等 /api/auth/status 返回后再决定。
    // 这样已登录用户刷新时不会看到登录页闪一下。
    if (document.body) buildGate();
    checkSession();
    document.addEventListener('DOMContentLoaded', function () {
      // 认证请求可能还没返回；不要在这里抢跑 showGate()。
      if (state.authReady) {
        if (state.authenticated) {
          if (state.gate) hideGate();
        } else {
          showGate();
        }
      }
      injectAccountMenu();
    });
  }

  global.KeweAuth = {
    isAuthenticated: function () { return state.authenticated; },
    user: function () { return state.user; },
    logout: openSignOutConfirm,
    deleteAccount: openDeleteConfirm,
    showGate: showGate,
    lang: function () { return state.lang; }
  };

  boot();
})(window);
