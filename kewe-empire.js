/* ============================================================
 * kewe-empire.js —— 一句话指挥中心 / 知识库数据库 / SOS 保命 / 全站特效
 * 设计原则：只叠加功能，不侵入原聊天状态；所有私有 API 由后端 404 门禁保护。
 * ============================================================ */
(function () {
  'use strict';

  var SUPPORTED = ['zh', 'en', 'ja', 'ko', 'ru', 'fr'];
  var STORAGE_EMERGENCY = 'kewe_emergency_v1';
  var STORAGE_CONTACTS = 'kewe_emergency_contacts_v1';
  var state = {
    commandOpen: false,
    knowledgeOpen: false,
    emergencyOpen: false,
    lastKnowledgeQuery: '',
    fxBuilt: false,
    layers: {}
  };

  var T = {
    zh: {
      headSub: 'SOVEREIGN COMMAND / 私人行动中枢',
      commandTitle: '一句话，调动一切',
      commandSub: '说目标，不要说步骤。模型会先检索账号知识库，再决定直接回答、调用手机工具，或进入保命流程。',
      commandPlaceholder: '例如：打开单词本 / 记住我的紧急联系人 / 帮我查手机上的资料 / 救命',
      go: '执行',
      chipKnowledge: '知识库',
      kbMenu: '知识库状态',
      loginRequired: '需要登录',
      kbReadFailed: '读取失败',
      kbUnitEntries: '条',
      kbUnitDomains: '域',
      kbUnitChars: '字',
      chipEmergency: 'SOS 保命',
      chipPhone: '手机自动化',
      chipNewChat: '新会话',
      chipForum: '帖子广场',
      chipVocab: '单词本',
      chipSettings: '设置',
      statusSkill: 'SKILL',
      statusEntries: '知识条目',
      statusModel: '行动引擎',
      online: '在线',
      commandNote: 'POWERED BY KEWE · 账号级记忆 · 明文聊天数据 · 六语界面',
      knowledgeTitle: '知识库 / 数据库',
      knowledgeSub: '模型知道什么，就在这里',
      dbEntries: '条目',
      dbChars: '字符',
      dbBase: '基础文档',
      dbTopics: '主题',
      searchPlaceholder: '搜索知识、偏好、决定、路径…',
      search: '检索',
      newNote: '新建知识',
      viewSkill: '查看 skill.md',
      empty: '还没有知识条目。点“新建知识”，让模型开始记住你。',
      noResult: '没有检索到相关条目。',
      detailTitle: '知识正文',
      edit: '编辑',
      delete: '删除',
      close: '关闭',
      noteTitle: '标题',
      noteTags: '标签（逗号分隔）',
      noteContent: '正文（可以是计划、偏好、资料、SOP）',
      save: '保存到数据库',
      cancel: '取消',
      saved: '已保存到知识库',
      deleted: '已删除',
      account: '账号目录',
      dbPath: '数据库',
      emergencyTitle: 'SOS / 保命',
      emergencySub: '网站不能代替救援机构。危险时先离开危险源，再拨号。',
      emergencyNote: '如果现在有立即危险：到有人的、亮的地方；拨打 110 / 120 / 119；说清位置、发生什么、几个人、有没有人受伤。',
      police: '报警 / 被威胁 / 失踪',
      medical: '急救 / 受伤 / 呼吸困难',
      fire: '火灾 / 被困 / 救援',
      call: '拨打',
      contacts: '紧急联系人',
      noContacts: '还没有联系人。先添加一个你信得过的人。',
      contactName: '姓名',
      contactPhone: '电话',
      addContact: '添加联系人',
      medicalCard: '随身医疗卡',
      name: '姓名',
      blood: '血型',
      allergies: '过敏',
      meds: '用药',
      note: '备注',
      saveCard: '保存医疗卡（本地 + 账号知识库）',
      location: '定位与分享',
      locate: '读取当前位置',
      copy: '复制位置',
      locating: '定位中…',
      locationHint: '只有你点击并授权后才读取；不上传后台。',
      locationFail: '定位失败，请检查系统权限。',
      copied: '位置已复制',
      closeSos: '返回',
      savedCard: '医疗卡已保存',
      contactsSaved: '联系人已更新',
      contactDelete: '删除',
      invalidPhone: '电话不能为空',
      forwarded: '已交给模型自动执行（工具模式已开启）',
      noInput: '先说一句话。',
      language: '语言',
      open: '打开',
      baseDoc: '基础',
      accountDoc: '账号',
      cmdKnowledge: '好的，打开知识库',
      cmdVocab: '打开日语单词本',
      cmdForum: '打开帖子广场',
      cmdNew: '新会话已准备',
      cmdSettings: '打开设置',
      cmdLang: '正在切换语言并刷新',
      cmdSos: '进入 SOS 保命模式',
      cmdForward: '已交给模型',
      refreshed: '已刷新',
      modelOffline: '模型未就绪，已把指令放进输入框。',
      searchSkill: '行动手册'
    },
    en: {
      headSub: 'SOVEREIGN COMMAND / PRIVATE OPS',
      commandTitle: 'One sentence. Everything moves.',
      commandSub: 'State the goal, not the steps. The model checks your knowledge DB first, then answers, runs phone tools, or enters safety mode.',
      commandPlaceholder: 'e.g. open my vocab book / remember my emergency contact / search my phone / help me',
      go: 'Run',
      chipKnowledge: 'Knowledge',
      kbMenu: 'Knowledge status',
      loginRequired: 'Login required',
      kbReadFailed: 'Failed to read',
      kbUnitEntries: 'entries',
      kbUnitDomains: 'domains',
      kbUnitChars: 'chars',
      chipEmergency: 'SOS',
      chipPhone: 'Phone ops',
      chipNewChat: 'New chat',
      chipForum: 'Forum',
      chipVocab: 'Vocab',
      chipSettings: 'Settings',
      statusSkill: 'SKILL',
      statusEntries: 'Entries',
      statusModel: 'Engine',
      online: 'ONLINE',
      commandNote: 'POWERED BY KEWE · ACCOUNT MEMORY · PLAINTEXT CHAT · SIX LANGUAGES',
      knowledgeTitle: 'Knowledge / Database',
      knowledgeSub: 'What the model knows lives here',
      dbEntries: 'Entries',
      dbChars: 'Chars',
      dbBase: 'Base docs',
      dbTopics: 'Topics',
      searchPlaceholder: 'Search knowledge, preferences, decisions, paths…',
      search: 'Search',
      newNote: 'New entry',
      viewSkill: 'View skill.md',
      empty: 'No entries yet. Tap “New entry” and the model starts remembering you.',
      noResult: 'No matching entries.',
      detailTitle: 'Entry',
      edit: 'Edit',
      delete: 'Delete',
      close: 'Close',
      noteTitle: 'Title',
      noteTags: 'Tags (comma separated)',
      noteContent: 'Body — plans, preferences, references, SOPs',
      save: 'Save to database',
      cancel: 'Cancel',
      saved: 'Saved to knowledge DB',
      deleted: 'Deleted',
      account: 'Account dir',
      dbPath: 'Database',
      emergencyTitle: 'SOS / LIFELINE',
      emergencySub: 'This site is not a rescue service. Move away from danger, then call.',
      emergencyNote: 'Immediate danger: get to a lit place with people; call 110 / 120 / 119; say where you are, what happened, how many people, and injuries.',
      police: 'Police / threat / missing',
      medical: 'Ambulance / injury / breathing',
      fire: 'Fire / trapped / rescue',
      call: 'Call',
      contacts: 'Emergency contacts',
      noContacts: 'No contacts yet. Add someone you trust.',
      contactName: 'Name',
      contactPhone: 'Phone',
      addContact: 'Add contact',
      medicalCard: 'Medical card',
      name: 'Name',
      blood: 'Blood type',
      allergies: 'Allergies',
      meds: 'Medication',
      note: 'Notes',
      saveCard: 'Save card (local + account knowledge)',
      location: 'Location & share',
      locate: 'Get current location',
      copy: 'Copy location',
      locating: 'Locating…',
      locationHint: 'Only read after you tap and grant permission; not uploaded.',
      locationFail: 'Location failed. Check system permission.',
      copied: 'Location copied',
      closeSos: 'Back',
      savedCard: 'Medical card saved',
      contactsSaved: 'Contacts updated',
      contactDelete: 'Delete',
      invalidPhone: 'Phone cannot be empty',
      forwarded: 'Handed to the model (tool mode enabled)',
      noInput: 'Say something first.',
      language: 'Language',
      open: 'Open',
      baseDoc: 'BASE',
      accountDoc: 'ACCOUNT',
      cmdKnowledge: 'Opening knowledge',
      cmdVocab: 'Opening vocab book',
      cmdForum: 'Opening forum',
      cmdNew: 'New chat ready',
      cmdSettings: 'Opening settings',
      cmdLang: 'Switching language and reloading',
      cmdSos: 'Entering SOS lifeline',
      cmdForward: 'Handed to the model',
      refreshed: 'Refreshed',
      modelOffline: 'Model not ready; command placed in the input box.',
      searchSkill: 'Skill'
    },
    ja: {
      headSub: 'SOVEREIGN COMMAND / 専用作戦中枢',
      commandTitle: '一言で、すべてを動かす',
      commandSub: '手順ではなく目標を言ってください。モデルはまず知識ベースを検索し、回答・スマホ操作・安全モードを選びます。',
      commandPlaceholder: '例：単語帳を開く / 緊急連絡先を覚える / スマホを検索 / 助けて',
      go: '実行',
      chipKnowledge: '知識ベース',
      kbMenu: '知識ベース状態',
      loginRequired: 'ログインが必要です',
      kbReadFailed: '読み込みに失敗しました',
      kbUnitEntries: '件',
      kbUnitDomains: '領域',
      kbUnitChars: '文字',
      chipEmergency: 'SOS 救命',
      chipPhone: 'スマホ操作',
      chipNewChat: '新規会話',
      chipForum: '投稿広場',
      chipVocab: '単語帳',
      chipSettings: '設定',
      statusSkill: 'SKILL',
      statusEntries: '知識',
      statusModel: '実行エンジン',
      online: 'オンライン',
      commandNote: 'POWERED BY KEWE · アカウント記憶 · チャットは平文 · 6言語',
      knowledgeTitle: '知識ベース / データベース',
      knowledgeSub: 'モデルが知っていることは、ここに',
      dbEntries: '条目',
      dbChars: '文字',
      dbBase: '基礎資料',
      dbTopics: '主題',
      searchPlaceholder: '知識・好み・決定・パスを検索…',
      search: '検索',
      newNote: '新規知識',
      viewSkill: 'skill.md を表示',
      empty: '条目がありません。「新規知識」から記憶を始めましょう。',
      noResult: '該当する条目がありません。',
      detailTitle: '本文',
      edit: '編集',
      delete: '削除',
      close: '閉じる',
      noteTitle: 'タイトル',
      noteTags: 'タグ（カンマ区切り）',
      noteContent: '本文（計画・好み・資料・SOP）',
      save: 'データベースに保存',
      cancel: 'キャンセル',
      saved: '知識ベースに保存しました',
      deleted: '削除しました',
      account: 'アカウント',
      dbPath: 'データベース',
      emergencyTitle: 'SOS / 救命',
      emergencySub: 'このサイトは救助機関ではありません。危険から離れてから電話してください。',
      emergencyNote: '直ちに危険なら、人がいる明るい場所へ。110 / 120 / 119 に連絡し、場所・状況・人数・けがを伝えてください。',
      police: '警察 / 脅迫 / 失踪',
      medical: '救急 / けが / 呼吸困難',
      fire: '火災 / 閉じ込め / 救助',
      call: '発信',
      contacts: '緊急連絡先',
      noContacts: '連絡先がありません。信頼できる人を追加してください。',
      contactName: '名前',
      contactPhone: '電話',
      addContact: '連絡先を追加',
      medicalCard: '医療カード',
      name: '名前',
      blood: '血液型',
      allergies: 'アレルギー',
      meds: '服薬',
      note: 'メモ',
      saveCard: '医療カードを保存（ローカル＋知識ベース）',
      location: '位置情報',
      locate: '現在地を取得',
      copy: '位置をコピー',
      locating: '測位中…',
      locationHint: 'タップと許可の後だけ取得。バックエンドへ送信しません。',
      locationFail: '測位に失敗しました。権限を確認してください。',
      copied: '位置をコピーしました',
      closeSos: '戻る',
      savedCard: '医療カードを保存しました',
      contactsSaved: '連絡先を更新しました',
      contactDelete: '削除',
      invalidPhone: '電話番号を入力してください',
      forwarded: 'モデルに渡しました（ツールモード有効）',
      noInput: '先に一言入力してください。',
      language: '言語',
      open: '開く',
      baseDoc: '基礎',
      accountDoc: 'アカウント',
      cmdKnowledge: '知識ベースを開きます',
      cmdVocab: '単語帳を開きます',
      cmdForum: '投稿広場を開きます',
      cmdNew: '新規会話を準備しました',
      cmdSettings: '設定を開きます',
      cmdLang: '言語を切り替えて再読み込みします',
      cmdSos: 'SOS 救命モードへ',
      cmdForward: 'モデルに渡しました',
      refreshed: '更新しました',
      modelOffline: 'モデル未起動。入力欄に指令を入れました。',
      searchSkill: '行動手順'
    },
    ko: {
      headSub: 'SOVEREIGN COMMAND / 개인 작전 본부',
      commandTitle: '한 문장으로 모든 것을',
      commandSub: '단계가 아니라 목표를 말하세요. 모델이 먼저 지식 DB를 검색한 뒤 답변·휴대폰 조작·안전 모드를 선택합니다.',
      commandPlaceholder: '예: 단어장 열기 / 긴급 연락처 기억 / 휴대폰 검색 / 살려줘',
      go: '실행',
      chipKnowledge: '지식',
      kbMenu: '지식 상태',
      loginRequired: '로그인이 필요합니다',
      kbReadFailed: '읽기 실패',
      kbUnitEntries: '항목',
      kbUnitDomains: '영역',
      kbUnitChars: '자',
      chipEmergency: 'SOS',
      chipPhone: '휴대폰 자동화',
      chipNewChat: '새 대화',
      chipForum: '게시판',
      chipVocab: '단어장',
      chipSettings: '설정',
      statusSkill: 'SKILL',
      statusEntries: '지식',
      statusModel: '엔진',
      online: '온라인',
      commandNote: 'POWERED BY KEWE · 계정 기억 · 평문 채팅 · 6개 언어',
      knowledgeTitle: '지식 / 데이터베이스',
      knowledgeSub: '모델이 아는 것이 여기에 있습니다',
      dbEntries: '항목',
      dbChars: '문자',
      dbBase: '기본 문서',
      dbTopics: '주제',
      searchPlaceholder: '지식·선호·결정·경로 검색…',
      search: '검색',
      newNote: '새 지식',
      viewSkill: 'skill.md 보기',
      empty: '항목이 없습니다. “새 지식”으로 기억을 시작하세요.',
      noResult: '일치하는 항목이 없습니다.',
      detailTitle: '본문',
      edit: '편집',
      delete: '삭제',
      close: '닫기',
      noteTitle: '제목',
      noteTags: '태그(쉼표 구분)',
      noteContent: '본문 — 계획·선호·자료·SOP',
      save: 'DB에 저장',
      cancel: '취소',
      saved: '지식 DB에 저장됨',
      deleted: '삭제됨',
      account: '계정 폴더',
      dbPath: 'DB',
      emergencyTitle: 'SOS / 생명선',
      emergencySub: '이 사이트는 구조 기관이 아닙니다. 위험에서 벗어난 뒤 전화하세요.',
      emergencyNote: '즉시 위험하면 사람이 있는 밝은 곳으로. 110 / 120 / 119에 위치·상황·인원·부상을 말하세요.',
      police: '경찰 / 위협 / 실종',
      medical: '구급 / 부상 / 호흡곤란',
      fire: '화재 / 갇힘 / 구조',
      call: '전화',
      contacts: '긴급 연락처',
      noContacts: '연락처가 없습니다. 믿을 수 있는 사람을 추가하세요.',
      contactName: '이름',
      contactPhone: '전화',
      addContact: '연락처 추가',
      medicalCard: '의료 카드',
      name: '이름',
      blood: '혈액형',
      allergies: '알레르기',
      meds: '복용약',
      note: '메모',
      saveCard: '의료 카드 저장(로컬+지식 DB)',
      location: '위치 공유',
      locate: '현재 위치 읽기',
      copy: '위치 복사',
      locating: '위치 확인 중…',
      locationHint: '탭과 권한 허용 후에만 읽으며 서버로 전송하지 않습니다.',
      locationFail: '위치 확인 실패. 권한을 확인하세요.',
      copied: '위치 복사됨',
      closeSos: '뒤로',
      savedCard: '의료 카드 저장됨',
      contactsSaved: '연락처 갱신됨',
      contactDelete: '삭제',
      invalidPhone: '전화번호를 입력하세요',
      forwarded: '모델에 전달됨(도구 모드 켜짐)',
      noInput: '먼저 한 문장을 입력하세요.',
      language: '언어',
      open: '열기',
      baseDoc: '기본',
      accountDoc: '계정',
      cmdKnowledge: '지식 DB를 엽니다',
      cmdVocab: '단어장을 엽니다',
      cmdForum: '게시판을 엽니다',
      cmdNew: '새 대화 준비됨',
      cmdSettings: '설정을 엽니다',
      cmdLang: '언어를 바꾸고 새로고침합니다',
      cmdSos: 'SOS 생명선 모드',
      cmdForward: '모델에 전달됨',
      refreshed: '새로고침됨',
      modelOffline: '모델이 준비되지 않아 입력창에 명령을 넣었습니다.',
      searchSkill: '행동 지침'
    },
    ru: {
      headSub: 'SOVEREIGN COMMAND / ЛИЧНЫЙ ШТАБ',
      commandTitle: 'Одна фраза. Всё движется.',
      commandSub: 'Говорите цель, а не шаги. Модель сначала проверит базу знаний, затем ответит, запустит телефон или режим безопасности.',
      commandPlaceholder: 'напр.: открыть словарь / запомнить экстренный контакт / найти в телефоне / помогите',
      go: 'Запуск',
      chipKnowledge: 'Знания',
      kbMenu: 'Статус знаний',
      loginRequired: 'Требуется вход',
      kbReadFailed: 'Не удалось прочитать',
      kbUnitEntries: 'записей',
      kbUnitDomains: 'доменов',
      kbUnitChars: 'символов',
      chipEmergency: 'SOS',
      chipPhone: 'Телефон',
      chipNewChat: 'Новый чат',
      chipForum: 'Форум',
      chipVocab: 'Словарь',
      chipSettings: 'Настройки',
      statusSkill: 'SKILL',
      statusEntries: 'Знания',
      statusModel: 'Движок',
      online: 'ОНЛАЙН',
      commandNote: 'POWERED BY KEWE · ПАМЯТЬ АККАУНТА · ЧАТ В ОТКРЫТОМ ВИДЕ · 6 ЯЗЫКОВ',
      knowledgeTitle: 'Знания / База данных',
      knowledgeSub: 'То, что знает модель — здесь',
      dbEntries: 'Записи',
      dbChars: 'Символы',
      dbBase: 'Базовые',
      dbTopics: 'Темы',
      searchPlaceholder: 'Поиск знаний, предпочтений, решений, путей…',
      search: 'Поиск',
      newNote: 'Новая запись',
      viewSkill: 'Открыть skill.md',
      empty: 'Записей пока нет. Нажмите «Новая запись».',
      noResult: 'Ничего не найдено.',
      detailTitle: 'Текст',
      edit: 'Изменить',
      delete: 'Удалить',
      close: 'Закрыть',
      noteTitle: 'Заголовок',
      noteTags: 'Теги (через запятую)',
      noteContent: 'Текст — планы, предпочтения, справки, SOP',
      save: 'Сохранить в БД',
      cancel: 'Отмена',
      saved: 'Сохранено в базе знаний',
      deleted: 'Удалено',
      account: 'Папка аккаунта',
      dbPath: 'База',
      emergencyTitle: 'SOS / ЛИНИЯ ЖИЗНИ',
      emergencySub: 'Сайт не заменяет службу спасения. Уйдите от опасности, затем звоните.',
      emergencyNote: 'При непосредственной опасности: в светлое место с людьми; 110 / 120 / 119; скажите где вы, что случилось, сколько людей, травмы.',
      police: 'Полиция / угроза / пропал',
      medical: 'Скорая / травма / дыхание',
      fire: 'Пожар / заперт / спасение',
      call: 'Звонок',
      contacts: 'Экстренные контакты',
      noContacts: 'Контактов нет. Добавьте доверенного человека.',
      contactName: 'Имя',
      contactPhone: 'Телефон',
      addContact: 'Добавить контакт',
      medicalCard: 'Медкарта',
      name: 'Имя',
      blood: 'Группа крови',
      allergies: 'Аллергии',
      meds: 'Лекарства',
      note: 'Примечание',
      saveCard: 'Сохранить карту (локально + знания)',
      location: 'Геолокация',
      locate: 'Определить местоположение',
      copy: 'Копировать местоположение',
      locating: 'Определение…',
      locationHint: 'Только после нажатия и разрешения; не отправляется на сервер.',
      locationFail: 'Ошибка геолокации. Проверьте разрешение.',
      copied: 'Местоположение скопировано',
      closeSos: 'Назад',
      savedCard: 'Медкарта сохранена',
      contactsSaved: 'Контакты обновлены',
      contactDelete: 'Удалить',
      invalidPhone: 'Введите телефон',
      forwarded: 'Передано модели (режим инструментов включён)',
      noInput: 'Сначала введите фразу.',
      language: 'Язык',
      open: 'Открыть',
      baseDoc: 'БАЗА',
      accountDoc: 'АККАУНТ',
      cmdKnowledge: 'Открываю базу знаний',
      cmdVocab: 'Открываю словарь',
      cmdForum: 'Открываю форум',
      cmdNew: 'Новый чат готов',
      cmdSettings: 'Открываю настройки',
      cmdLang: 'Переключаю язык и обновляю',
      cmdSos: 'Режим SOS',
      cmdForward: 'Передано модели',
      refreshed: 'Обновлено',
      modelOffline: 'Модель не готова; команда вставлена в поле ввода.',
      searchSkill: 'Инструкция'
    },
    fr: {
      headSub: 'SOVEREIGN COMMAND / CENTRE PRIVÉ',
      commandTitle: 'Une phrase. Tout s’exécute.',
      commandSub: 'Dites l’objectif, pas les étapes. Le modèle consulte d’abord votre base de connaissances, puis répond, pilote le téléphone ou passe en sécurité.',
      commandPlaceholder: 'ex. ouvrir mon vocabulaire / retenir mon contact d’urgence / chercher dans mon téléphone / au secours',
      go: 'Lancer',
      chipKnowledge: 'Connaissances',
      kbMenu: 'État des connaissances',
      loginRequired: 'Connexion requise',
      kbReadFailed: 'Échec de la lecture',
      kbUnitEntries: 'entrées',
      kbUnitDomains: 'domaines',
      kbUnitChars: 'caractères',
      chipEmergency: 'SOS',
      chipPhone: 'Téléphone',
      chipNewChat: 'Nouveau chat',
      chipForum: 'Forum',
      chipVocab: 'Vocabulaire',
      chipSettings: 'Réglages',
      statusSkill: 'SKILL',
      statusEntries: 'Entrées',
      statusModel: 'Moteur',
      online: 'EN LIGNE',
      commandNote: 'POWERED BY KEWE · MÉMOIRE COMPTE · CHAT EN CLAIR · 6 LANGUES',
      knowledgeTitle: 'Connaissances / Base',
      knowledgeSub: 'Ce que le modèle sait est ici',
      dbEntries: 'Entrées',
      dbChars: 'Caractères',
      dbBase: 'Docs de base',
      dbTopics: 'Thèmes',
      searchPlaceholder: 'Chercher connaissances, préférences, décisions, chemins…',
      search: 'Chercher',
      newNote: 'Nouvelle entrée',
      viewSkill: 'Voir skill.md',
      empty: 'Aucune entrée. Touchez « Nouvelle entrée ».',
      noResult: 'Aucun résultat.',
      detailTitle: 'Contenu',
      edit: 'Modifier',
      delete: 'Supprimer',
      close: 'Fermer',
      noteTitle: 'Titre',
      noteTags: 'Tags (séparés par des virgules)',
      noteContent: 'Contenu — plans, préférences, références, SOP',
      save: 'Enregistrer dans la base',
      cancel: 'Annuler',
      saved: 'Enregistré dans la base',
      deleted: 'Supprimé',
      account: 'Compte',
      dbPath: 'Base',
      emergencyTitle: 'SOS / LIGNE DE VIE',
      emergencySub: 'Ce site ne remplace pas les secours. Éloignez-vous du danger, puis appelez.',
      emergencyNote: 'Danger immédiat : allez dans un lieu éclairé avec du monde ; appelez 110 / 120 / 119 ; dites où vous êtes, ce qui s’est passé, combien de personnes, les blessures.',
      police: 'Police / menace / disparition',
      medical: 'Secours / blessure / respiration',
      fire: 'Incendie / coincé / sauvetage',
      call: 'Appeler',
      contacts: "Contacts d'urgence",
      noContacts: "Aucun contact. Ajoutez une personne de confiance.",
      contactName: 'Nom',
      contactPhone: 'Téléphone',
      addContact: 'Ajouter un contact',
      medicalCard: 'Carte médicale',
      name: 'Nom',
      blood: 'Groupe sanguin',
      allergies: 'Allergies',
      meds: 'Médicaments',
      note: 'Notes',
      saveCard: 'Enregistrer (local + connaissances)',
      location: 'Position & partage',
      locate: 'Obtenir la position',
      copy: 'Copier la position',
      locating: 'Localisation…',
      locationHint: 'Lue seulement après votre accord ; non envoyée au serveur.',
      locationFail: 'Échec de la localisation. Vérifiez la permission.',
      copied: 'Position copiée',
      closeSos: 'Retour',
      savedCard: 'Carte médicale enregistrée',
      contactsSaved: 'Contacts mis à jour',
      contactDelete: 'Supprimer',
      invalidPhone: 'Numéro requis',
      forwarded: 'Transmis au modèle (outils activés)',
      noInput: 'Dites d’abord une phrase.',
      language: 'Langue',
      open: 'Ouvrir',
      baseDoc: 'BASE',
      accountDoc: 'COMPTE',
      cmdKnowledge: 'Ouverture des connaissances',
      cmdVocab: 'Ouverture du vocabulaire',
      cmdForum: 'Ouverture du forum',
      cmdNew: 'Nouveau chat prêt',
      cmdSettings: 'Ouverture des réglages',
      cmdLang: 'Changement de langue et rechargement',
      cmdSos: 'Mode SOS',
      cmdForward: 'Transmis au modèle',
      refreshed: 'Actualisé',
      modelOffline: 'Modèle non prêt ; commande placée dans le champ.',
      searchSkill: 'Manuel'
    }
  };

  function lang() {
    try {
      if (window.I18N && typeof window.I18N.getLang === 'function') {
        var l = window.I18N.getLang();
        if (SUPPORTED.indexOf(l) >= 0) return l;
      }
      var saved = localStorage.getItem('dsc_ui_lang2');
      if (SUPPORTED.indexOf(saved) >= 0) return saved;
    } catch (e) {}
    return 'zh';
  }
  function tr(k) {
    var l = lang();
    return (T[l] && T[l][k]) || T.zh[k] || k;
  }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != undefined) e.textContent = text;
    return e;
  }
  function toast(msg) {
    var e = document.getElementById('kweToast');
    if (!e) {
      e = el('div', 'kwe-toast');
      e.id = 'kweToast';
      document.body.appendChild(e);
    }
    e.textContent = msg;
    e.classList.add('show');
    clearTimeout(e.__timer);
    e.__timer = setTimeout(function () { e.classList.remove('show'); }, 3200);
  }
  function isAuthed() {
    var gate = document.getElementById('keweAuthGate');
    var locked = document.documentElement.classList.contains('kewe-auth-locked');
    // 不调用 getComputedStyle：它会在每个 MutationObserver 回调里强制重排。
    // 门禁显隐由 kewe-auth.js 写入 inline display，直接读 style 即可。
    if (gate && gate.style.display && gate.style.display !== 'none') return false;
    return !locked;
  }
  function closeLayer(layer) {
    if (!layer) return;
    layer.style.display = 'none';
    document.body.style.overflow = '';
  }
  function openLayer(layer) {
    if (!layer) return;
    layer.style.display = 'block';
    document.body.style.overflow = 'hidden';
  }

  // ------------------------------------------------------------
  // 全站特效
  // ------------------------------------------------------------
  function buildFx() {
    if (state.fxBuilt) return;
    state.fxBuilt = true;
    var fx = el('div');
    fx.id = 'keweEmpireFx';
    fx.setAttribute('aria-hidden', 'true');
    fx.innerHTML = '<div class="kwe-fx-aurora kwe-fx-a1"></div>' +
      '<div class="kwe-fx-aurora kwe-fx-a2"></div>' +
      '<div class="kwe-fx-aurora kwe-fx-a3"></div>' +
      '<div class="kwe-fx-grid"></div><div class="kwe-fx-scan"></div>';
    for (var i = 0; i < 18; i++) {
      var p = el('span', 'kwe-fx-particle');
      p.style.left = (4 + Math.random() * 92) + '%';
      p.style.top = (30 + Math.random() * 65) + '%';
      p.style.animationDuration = (9 + Math.random() * 16) + 's';
      p.style.animationDelay = (-Math.random() * 18) + 's';
      p.style.setProperty('--kwe-drift', (Math.random() * 90 - 45) + 'px');
      fx.appendChild(p);
    }
    document.body.appendChild(fx);
  }

  function buildPowerOrb() {
    if (document.getElementById('kewePowerOrb')) return;
    var btn = el('button', '', '');
    btn.id = 'kewePowerOrb';
    btn.type = 'button';
    btn.title = tr('commandTitle');
    btn.setAttribute('aria-label', tr('commandTitle'));
    btn.innerHTML = '<svg viewBox="0 0 40 40" aria-hidden="true">' +
      '<circle cx="20" cy="20" r="12.5" fill="none" stroke="#a5f3fc" stroke-width="1.4"/>' +
      '<circle cx="20" cy="20" r="7.2" fill="none" stroke="#c4b5fd" stroke-width="1.2" stroke-dasharray="2 3"/>' +
      '<path d="M20 8.5 L22.2 17.7 L31.5 20 L22.2 22.3 L20 31.5 L17.8 22.3 L8.5 20 L17.8 17.7 Z" fill="#fff"/>' +
      '<circle cx="20" cy="20" r="1.6" fill="#fbbf24"/></svg>' +
      '<span class="kwe-orb-badge">ON</span>';
    btn.addEventListener('click', function () { openCommand(); });
    // 2026-11-26 · 挂到 app 内：随 app 一起显隐，且层级低于 .dsc-modal-overlay(100001)/全屏页(100080)，
    // 不再浮在确认弹窗、单词本、论坛等页面上方抢点击。
    var orbHost = document.getElementById('deepseekChatApp') || document.body;
    orbHost.appendChild(btn);
  }

  // ------------------------------------------------------------
  // 指挥中心
  // ------------------------------------------------------------
  function buildCommandLayer() {
    if (state.layers.command) return state.layers.command;
    var layer = el('div', 'kwe-layer');
    layer.id = 'keweCommandLayer';
    layer.setAttribute('role', 'dialog');
    layer.setAttribute('aria-label', tr('commandTitle'));
    layer.innerHTML =
      '<div class="kwe-shell">' +
        '<div class="kwe-head">' +
          '<div class="kwe-head-mark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="12" cy="12" r="8.2"/><path d="M12 5.2v13.6M5.2 12h13.6" opacity=".45"/><path d="M12 2.4l1.5 3.2L16.8 7l-2.1 2.7.3 3.4-3-1.4-3 1.4.3-3.4L5.7 7l3.3-1.4L12 2.4Z" fill="currentColor" stroke="none"/></svg></div>' +
          '<div class="kwe-head-title"><b>KEWE SOVEREIGN</b><span>' + tr('headSub') + '</span></div>' +
          '<button type="button" class="kwe-close" data-kwe-close="command" aria-label="' + tr('close') + '">×</button>' +
        '</div>' +
        '<div class="kwe-command-body">' +
          '<div class="kwe-core" aria-hidden="true"><div class="kwe-core-ring"></div><div class="kwe-core-orb"><svg viewBox="0 0 48 48" fill="none"><circle cx="24" cy="24" r="14" stroke="#a5f3fc" stroke-width="1.2" opacity=".8"/><ellipse cx="24" cy="24" rx="20" ry="6.5" transform="rotate(-24 24 24)" stroke="#e0f2fe" stroke-width="1" opacity=".65"/><ellipse cx="24" cy="24" rx="19" ry="6" transform="rotate(38 24 24)" stroke="#c4b5fd" stroke-width="1" opacity=".45"/><path d="M24 8.5l2.4 9.5 9.6 2.4-9.6 2.5-2.4 9.6-2.5-9.6L12 24l9.5-2.6L24 8.5Z" fill="#fde68a"/></svg><span class="kwe-core-label">CORE ONLINE</span></div></div>' +
          '<h1 class="kwe-command-title">' + tr('commandTitle') + '</h1>' +
          '<p class="kwe-command-sub">' + tr('commandSub') + '</p>' +
          '<div class="kwe-command-inputrow"><input class="kwe-command-input" id="kweCommandInput" type="text" autocomplete="off" placeholder="' + tr('commandPlaceholder') + '"><button type="button" class="kwe-command-go" id="kweCommandGo" aria-label="' + tr('go') + '">➤</button></div>' +
          '<div class="kwe-chips">' +
            '<button type="button" class="kwe-chip" data-kwe-act="knowledge">◈ ' + tr('chipKnowledge') + '</button>' +
            '<button type="button" class="kwe-chip" data-kwe-act="emergency" style="border-color:rgba(251,44,77,.32);color:#fecdd3">＋ ' + tr('chipEmergency') + '</button>' +
            '<button type="button" class="kwe-chip" data-kwe-act="phone">⌁ ' + tr('chipPhone') + '</button>' +
            '<button type="button" class="kwe-chip" data-kwe-act="newchat">＋ ' + tr('chipNewChat') + '</button>' +
            '<button type="button" class="kwe-chip" data-kwe-act="forum">▤ ' + tr('chipForum') + '</button>' +
            '<button type="button" class="kwe-chip" data-kwe-act="vocab">▥ ' + tr('chipVocab') + '</button>' +
            '<button type="button" class="kwe-chip" data-kwe-act="settings">⚙ ' + tr('chipSettings') + '</button>' +
          '</div>' +
          '<div class="kwe-command-status">' +
            '<div class="kwe-stat"><small>' + tr('statusSkill') + '</small><b>skill.md</b></div>' +
            '<div class="kwe-stat"><small>' + tr('statusEntries') + '</small><b id="kweOrbEntries">—</b></div>' +
            '<div class="kwe-stat"><small>' + tr('statusModel') + '</small><b style="color:#67e8f9">' + tr('online') + '</b></div>' +
          '</div>' +
          '<p class="kwe-command-note">' + tr('commandNote') + '</p>' +
        '</div>' +
      '</div>';
    layer.style.display = 'none';
    document.body.appendChild(layer);
    state.layers.command = layer;

    layer.querySelector('[data-kwe-close="command"]').addEventListener('click', function () { closeLayer(layer); state.commandOpen = false; });
    layer.addEventListener('click', function (e) { if (e.target === layer) { closeLayer(layer); state.commandOpen = false; } });
    var input = layer.querySelector('#kweCommandInput');
    layer.querySelector('#kweCommandGo').addEventListener('click', function () { runCommand(input.value); });
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); runCommand(input.value); } });
    Array.prototype.forEach.call(layer.querySelectorAll('[data-kwe-act]'), function (btn) {
      btn.addEventListener('click', function () {
        var act = btn.getAttribute('data-kwe-act');
        if (act === 'knowledge') openKnowledge();
        else if (act === 'emergency') openEmergency();
        else if (act === 'phone') {
          closeLayer(layer); state.commandOpen = false;
          setToolMode(true);
          forwardToModel(tr('chipPhone') + ' · ' + tr('commandPlaceholder'));
        } else {
          executeShortcut(act);
        }
      });
    });
    return layer;
  }

  function openCommand() {
    if (!isAuthed()) { openEmergency(); return; }
    var layer = buildCommandLayer();
    openLayer(layer);
    state.commandOpen = true;
    var input = layer.querySelector('#kweCommandInput');
    setTimeout(function () { try { input.focus(); } catch (e) {} }, 140);
    refreshCommandStats();
  }

  function refreshCommandStats() {
    var b = document.getElementById('kweOrbEntries');
    if (!b) return;
    fetch('/api/knowledge/status', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (d && typeof d.entries === 'number') b.textContent = String(d.entries);
      }).catch(function () { b.textContent = '—'; });
  }

  function setToolMode(on) {
    try { if (typeof window.dscSetToolMode === 'function') window.dscSetToolMode(!!on); } catch (e) {}
  }

  function press(id) {
    var e = document.getElementById(id);
    if (!e) return false;
    try { e.click(); return true; } catch (x) { return false; }
  }

  function executeShortcut(act) {
    closeLayer(state.layers.command);
    state.commandOpen = false;
    if (act === 'vocab') { if (press('dscVocabBtn')) toast(tr('cmdVocab')); }
    else if (act === 'forum') { if (press('dscForumBtn')) toast(tr('cmdForum')); }
    else if (act === 'newchat') {
      if (press('dscNewBtn')) toast(tr('cmdNew'));
    } else if (act === 'settings') {
      if (press('dscSettingsBtn')) toast(tr('cmdSettings'));
    } else if (act === 'language') {
      if (window.I18N && window.I18N.setLang) window.I18N.setLang('en', { reload: true });
    }
  }

  function runCommand(raw) {
    var text = String(raw || '').trim();
    if (!text) { toast(tr('noInput')); return; }
    var low = text.toLowerCase();
    if (/(救命|遇到危险|危险|sos|help me|emergency|助けて|살려|구조|помоги|опасн|au secours|urgence|danger)/i.test(text)) {
      closeLayer(state.layers.command); state.commandOpen = false; openEmergency(); return;
    }
    if (/(知识|knowledge|知識|지식|знани|connaissance|database|数据库|數據庫|база данных)/i.test(text)) {
      closeLayer(state.layers.command); state.commandOpen = false; openKnowledge(text); return;
    }
    if (/(单词|単語|vocab|단어|словар|vocabulaire)/i.test(text)) { executeShortcut('vocab'); return; }
    if (/(帖子|投稿|广场|forum|広場|게시판|форум)/i.test(text)) { executeShortcut('forum'); return; }
    if (/(新会话|新規|new chat|新しい会話|새 대화|новый чат|nouveau chat)/i.test(low)) { executeShortcut('newchat'); return; }
    if (/(设置|設定|settings|설정|настрой|réglage)/i.test(text)) { executeShortcut('settings'); return; }
    var langMatch = null;
    if (/(日本|japanese|ja|日本語)/i.test(text)) langMatch = 'ja';
    else if (/(英文|英语|english|en|英語|영어|англ|anglais)/i.test(text)) langMatch = 'en';
    else if (/(中文|chinese|zh|中国語|중국어|китай|chinois)/i.test(text)) langMatch = 'zh';
    else if (/(韩文|韩语|korean|ko|한국어|корей|coréen)/i.test(text)) langMatch = 'ko';
    else if (/(俄文|俄语|russian|ru|русск|russe)/i.test(text)) langMatch = 'ru';
    else if (/(法文|法语|french|fr|français|франц)/i.test(text)) langMatch = 'fr';
    if (langMatch) {
      closeLayer(state.layers.command); state.commandOpen = false;
      if (window.I18N && window.I18N.setLang) window.I18N.setLang(langMatch, { reload: true });
      return;
    }
    // 其余全部交给模型；开启工具模式，让它能查知识库、操作手机。
    closeLayer(state.layers.command); state.commandOpen = false;
    setToolMode(true);
    forwardToModel(text);
  }

  function forwardToModel(text) {
    var input = document.getElementById('dscInput');
    if (!input) { toast(tr('modelOffline')); return; }
    input.value = text;
    try { input.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
    try { input.focus(); } catch (e) {}
    setTimeout(function () {
      var btn = document.getElementById('dscSendBtn');
      if (btn) {
        try { btn.click(); toast(tr('forwarded')); return; } catch (e) {}
      }
      toast(tr('modelOffline'));
    }, 90);
  }

  // ------------------------------------------------------------
  // 知识库 / 数据库
  // ------------------------------------------------------------
  function buildKnowledgeLayer() {
    if (state.layers.knowledge) return state.layers.knowledge;
    var layer = el('div', 'kwe-layer');
    layer.id = 'keweKnowledgeLayer';
    layer.innerHTML =
      '<div class="kwe-shell">' +
        '<div class="kwe-head">' +
          '<div class="kwe-head-mark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><ellipse cx="12" cy="6" rx="7.5" ry="3"/><path d="M4.5 6v6c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3V6"/><path d="M4.5 12v6c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3v-6"/></svg></div>' +
          '<div class="kwe-head-title"><b>' + tr('knowledgeTitle') + '</b><span>' + tr('knowledgeSub') + '</span></div>' +
          '<button type="button" class="kwe-close" data-kwe-close="knowledge" aria-label="' + tr('close') + '">×</button>' +
        '</div>' +
        '<div class="kwe-db-stats">' +
          '<div class="kwe-db-stat"><small>' + tr('dbEntries') + '</small><b id="kweDbEntries">—</b></div>' +
          '<div class="kwe-db-stat"><small>' + tr('dbChars') + '</small><b id="kweDbChars">—</b></div>' +
          '<div class="kwe-db-stat"><small>' + tr('dbBase') + '</small><b id="kweDbBase">—</b></div>' +
          '<div class="kwe-db-stat"><small>' + tr('dbTopics') + '</small><b id="kweDbTopics">—</b></div>' +
        '</div>' +
        '<div class="kwe-search-row"><input class="kwe-input" id="kweKnowledgeSearch" type="search" placeholder="' + tr('searchPlaceholder') + '"><button type="button" class="kwe-btn primary" id="kweKnowledgeSearchBtn">' + tr('search') + '</button></div>' +
        '<div class="kwe-search-row" style="margin-top:-2px"><button type="button" class="kwe-btn" id="kweKnowledgeNew">＋ ' + tr('newNote') + '</button><button type="button" class="kwe-btn" id="kweKnowledgeSkill">◈ ' + tr('viewSkill') + '</button></div>' +
        '<div class="kwe-knowledge-list" id="kweKnowledgeList"></div>' +
        '<div class="kwe-entry-detail" id="kweKnowledgeDetail"><h3 id="kweDetailTitle"></h3><div class="meta" id="kweDetailMeta"></div><div class="kwe-entry-content" id="kweDetailContent"></div><div class="kwe-entry-actions"><button type="button" class="kwe-btn" id="kweDetailEdit">' + tr('edit') + '</button><button type="button" class="kwe-btn danger" id="kweDetailDelete">' + tr('delete') + '</button></div></div>' +
        '<div class="kwe-form" id="kweKnowledgeForm"><h3 id="kweFormTitle">' + tr('newNote') + '</h3><input class="kwe-input" id="kweFormTitleInput" placeholder="' + tr('noteTitle') + '" maxlength="160"><input class="kwe-input" id="kweFormTags" placeholder="' + tr('noteTags') + '"><textarea id="kweFormContent" placeholder="' + tr('noteContent') + '"></textarea><div class="kwe-entry-actions"><button type="button" class="kwe-btn" id="kweFormCancel">' + tr('cancel') + '</button><button type="button" class="kwe-btn primary" id="kweFormSave">' + tr('save') + '</button></div></div>' +
        '<div class="kwe-panel-title"><span id="kweDbPaths" style="font-size:9px;color:#6883a7;text-align:left;word-break:break-all;line-height:1.5"></span></div>' +
      '</div>';
    layer.style.display = 'none';
    document.body.appendChild(layer);
    state.layers.knowledge = layer;

    layer.querySelector('[data-kwe-close="knowledge"]').addEventListener('click', function () { closeLayer(layer); state.knowledgeOpen = false; });
    layer.addEventListener('click', function (e) { if (e.target === layer) { closeLayer(layer); state.knowledgeOpen = false; } });
    var searchInput = layer.querySelector('#kweKnowledgeSearch');
    layer.querySelector('#kweKnowledgeSearchBtn').addEventListener('click', function () { searchKnowledgeUI(searchInput.value); });
    searchInput.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); searchKnowledgeUI(searchInput.value); } });
    layer.querySelector('#kweKnowledgeNew').addEventListener('click', function () { showKnowledgeForm(); });
    layer.querySelector('#kweKnowledgeSkill').addEventListener('click', function () { openKnowledgeEntry('base:skill.md'); });
    layer.querySelector('#kweFormCancel').addEventListener('click', function () {
      layer.querySelector('#kweKnowledgeForm').classList.remove('open');
      layer.querySelector('#kweKnowledgeForm').removeAttribute('data-id');
      layer.querySelector('#kweKnowledgeList').style.display = '';
    });
    layer.querySelector('#kweFormSave').addEventListener('click', saveKnowledgeForm);
    layer.querySelector('#kweDetailEdit').addEventListener('click', function () {
      var id = layer.querySelector('#kweKnowledgeDetail').getAttribute('data-id') || '';
      var content = layer.querySelector('#kweDetailContent').textContent || '';
      showKnowledgeForm(id, layer.querySelector('#kweDetailTitle').textContent || '', content);
    });
    layer.querySelector('#kweDetailDelete').addEventListener('click', function () {
      var id = layer.querySelector('#kweKnowledgeDetail').getAttribute('data-id') || '';
      if (!id) return;
      if (!window.confirm(tr('delete') + ' · ' + id + '?')) return;
      fetch('/api/knowledge/delete', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: id }) })
        .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
        .then(function () { toast(tr('deleted')); closeDetail(); refreshKnowledgeStatus(); searchKnowledgeUI(searchInput.value); })
        .catch(function () { toast('DELETE FAILED'); });
    });
    return layer;
  }

  function openKnowledge(initialQuery) {
    if (!isAuthed()) { toast('404 · ' + tr('loginRequired')); openEmergency(); return; }
    var layer = buildKnowledgeLayer();
    openLayer(layer);
    state.knowledgeOpen = true;
    refreshKnowledgeStatus();
    var search = layer.querySelector('#kweKnowledgeSearch');
    if (initialQuery) {
      var q = String(initialQuery).replace(/^.*?[\s:：]+/, '');
      search.value = q;
      searchKnowledgeUI(q);
    } else {
      searchKnowledgeUI('');
    }
    setTimeout(function () { try { search.focus(); } catch (e) {} }, 140);
  }

  function refreshKnowledgeStatus() {
    fetch('/api/knowledge/status', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (d) {
        var set = function (id, v) { var e = document.getElementById(id); if (e) e.textContent = v; };
        set('kweDbEntries', String(d.entries == null ? '—' : d.entries));
        set('kweDbChars', String(d.totalChars == null ? '—' : d.totalChars));
        set('kweDbBase', String(d.baseDocs == null ? '—' : d.baseDocs));
        var topics = d.topics && typeof d.topics === 'object' ? Object.keys(d.topics).length : 0;
        set('kweDbTopics', String(topics));
        var p = document.getElementById('kweDbPaths');
        if (p) p.textContent = tr('account') + ': ' + (d.accountRoot || 'data/users/.../knowledge') + ' · ' + tr('dbPath') + ': ' + (d.dbFile || 'db.json');
      }).catch(function () {});
  }

  function searchKnowledgeUI(q) {
    state.lastKnowledgeQuery = q || '';
    var layer = state.layers.knowledge;
    if (!layer) return;
    var list = layer.querySelector('#kweKnowledgeList');
    list.textContent = '';
    closeDetail();
    fetch('/api/knowledge/search?q=' + encodeURIComponent(q || '') + '&limit=40', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (d) {
        var items = (d && d.items) || [];
        if (!items.length) {
          var empty = el('div', '', tr('empty'));
          empty.style.cssText = 'padding:22px 10px;text-align:center;color:#8195b5;font-size:11px;line-height:1.7';
          list.appendChild(empty);
          return;
        }
        items.forEach(function (it) {
          var btn = el('button', 'kwe-entry');
          btn.type = 'button';
          var mark = el('div', 'kwe-entry-mark', it.kind === 'base' ? '◈' : '▣');
          var copy = el('div', 'kwe-entry-copy');
          copy.appendChild(el('b', '', it.title || it.id));
          copy.appendChild(el('small', '', (it.preview || '').slice(0, 140)));
          var kind = el('span', 'kwe-entry-kind', it.kind === 'base' ? tr('baseDoc') : tr('accountDoc'));
          btn.appendChild(mark); btn.appendChild(copy); btn.appendChild(kind);
          btn.addEventListener('click', function () { openKnowledgeEntry(it.id); });
          list.appendChild(btn);
        });
      }).catch(function () {
        list.appendChild(el('div', '', '404 / ' + tr('noResult')));
      });
  }

  function closeDetail() {
    var d = document.getElementById('kweKnowledgeDetail');
    if (d) { d.classList.remove('open'); d.removeAttribute('data-id'); }
    var f = document.getElementById('kweKnowledgeForm');
    if (f) f.classList.remove('open');
  }

  function openKnowledgeEntry(id) {
    if (!state.layers.knowledge) buildKnowledgeLayer();
    fetch('/api/knowledge/entry?id=' + encodeURIComponent(id), { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (d) {
        var entry = (d && d.entry) || {};
        var detail = document.getElementById('kweKnowledgeDetail');
        detail.classList.add('open');
        detail.setAttribute('data-id', entry.id || '');
        document.getElementById('kweDetailTitle').textContent = entry.title || entry.id || tr('detailTitle');
        var meta = document.getElementById('kweDetailMeta');
        meta.textContent = '';
        var tags = Array.isArray(entry.tags) ? entry.tags : [];
        tags.forEach(function (tg) { meta.appendChild(el('span', '', '#' + tg)); });
        meta.appendChild(el('span', '', entry.kind === 'base' ? tr('baseDoc') : tr('accountDoc')));
        document.getElementById('kweDetailContent').textContent = entry.content || '';
        var del = document.getElementById('kweDetailDelete');
        var edit = document.getElementById('kweDetailEdit');
        if (entry.kind === 'base') { del.style.display = 'none'; edit.style.display = 'none'; }
        else { del.style.display = ''; edit.style.display = ''; }
        closeLayer(state.layers.knowledge);
        openLayer(state.layers.knowledge);
        state.knowledgeOpen = true;
        var box = document.querySelector('#kweKnowledgeLayer .kwe-entry-content');
        if (box) box.scrollTop = 0;
      }).catch(function () { toast('404 · ' + tr('noResult')); });
  }

  function showKnowledgeForm(id, title, content) {
    var layer = state.layers.knowledge;
    if (!layer) return;
    var form = layer.querySelector('#kweKnowledgeForm');
    form.classList.add('open');
    form.setAttribute('data-id', id || '');
    layer.querySelector('#kweFormTitle').textContent = id ? tr('edit') : tr('newNote');
    layer.querySelector('#kweFormTitleInput').value = title || '';
    layer.querySelector('#kweFormTags').value = '';
    layer.querySelector('#kweFormContent').value = content || '';
    layer.querySelector('#kweFormTitleInput').focus();
    layer.querySelector('#kweKnowledgeList').style.display = 'none';
  }

  function saveKnowledgeForm() {
    var layer = state.layers.knowledge;
    if (!layer) return;
    var form = layer.querySelector('#kweKnowledgeForm');
    var title = layer.querySelector('#kweFormTitleInput').value.trim();
    var content = layer.querySelector('#kweFormContent').value.trim();
    var tags = layer.querySelector('#kweFormTags').value.split(',').map(function (x) { return x.trim(); }).filter(Boolean);
    if (!title || !content) { toast(tr('noInput')); return; }
    var payload = { title: title, content: content, tags: tags };
    var id = form.getAttribute('data-id');
    if (id) payload.id = id;
    fetch('/api/knowledge/save', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function () {
        toast(tr('saved'));
        form.classList.remove('open');
        layer.querySelector('#kweKnowledgeList').style.display = '';
        refreshKnowledgeStatus();
        searchKnowledgeUI(state.lastKnowledgeQuery);
      }).catch(function () { toast('SAVE FAILED / 404'); });
  }

  // ------------------------------------------------------------
  // SOS 保命
  // ------------------------------------------------------------
  function readJSON(key, fallback) {
    try {
      var raw = localStorage.getItem(key);
      if (!raw) return fallback;
      var x = JSON.parse(raw);
      return x == null ? fallback : x;
    } catch (e) { return fallback; }
  }
  function writeJSON(key, val) {
    try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) {}
  }

  function buildEmergencyLayer() {
    if (state.layers.emergency) return state.layers.emergency;
    var layer = el('div', 'kwe-layer');
    layer.id = 'keweEmergencyLayer';
    layer.innerHTML =
      '<div class="kwe-shell">' +
        '<div class="kwe-head">' +
          '<div class="kwe-head-mark kwe-sos-mark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M12 3.2l8 3.4v5.3c0 4.8-3.2 8.4-8 10-4.8-1.6-8-5.2-8-10V6.6l8-3.4Z"/><path d="M12 8v5"/><circle cx="12" cy="16.2" r=".9" fill="currentColor" stroke="none"/></svg></div>' +
          '<div class="kwe-head-title"><b>' + tr('emergencyTitle') + '</b><span>' + tr('emergencySub') + '</span></div>' +
          '<button type="button" class="kwe-close" data-kwe-close="sos" aria-label="' + tr('closeSos') + '">×</button>' +
        '</div>' +
        '<div class="kwe-sos-headline"><h1>SOS</h1><p>' + tr('emergencyNote') + '</p></div>' +
        '<div class="kwe-sos-numbers">' +
          '<a class="kwe-sos-number police" href="tel:110"><b>110</b><span>' + tr('police') + '</span></a>' +
          '<a class="kwe-sos-number medical" href="tel:120"><b>120</b><span>' + tr('medical') + '</span></a>' +
          '<a class="kwe-sos-number fire" href="tel:119"><b>119</b><span>' + tr('fire') + '</span></a>' +
        '</div>' +
        '<div class="kwe-sos-grid">' +
          '<div class="kwe-sos-card"><h3>◈ ' + tr('contacts') + '</h3><div id="kweContactsList"></div><input class="kwe-input" id="kweContactName" placeholder="' + tr('contactName') + '"><input class="kwe-input" id="kweContactPhone" type="tel" placeholder="' + tr('contactPhone') + '"><button type="button" class="kwe-btn" id="kweContactAdd">＋ ' + tr('addContact') + '</button></div>' +
          '<div class="kwe-sos-card"><h3>◈ ' + tr('medicalCard') + '</h3><input class="kwe-input" id="kweSosName" placeholder="' + tr('name') + '"><input class="kwe-input" id="kweSosBlood" placeholder="' + tr('blood') + '"><input class="kwe-input" id="kweSosAllergies" placeholder="' + tr('allergies') + '"><input class="kwe-input" id="kweSosMeds" placeholder="' + tr('meds') + '"><button type="button" class="kwe-btn primary" id="kweSosSaveCard">' + tr('saveCard') + '</button></div>' +
          '<div class="kwe-sos-card kwe-sos-location"><h3>◈ ' + tr('location') + '</h3><p>' + tr('locationHint') + '</p><div id="kweLocationText" style="margin-top:5px;color:#e9d5ff;font-size:12px;word-break:break-all"></div><div style="display:flex;gap:6px"><button type="button" class="kwe-btn" id="kweLocate">⌖ ' + tr('locate') + '</button><button type="button" class="kwe-btn" id="kweCopyLocation">⧉ ' + tr('copy') + '</button></div></div>' +
          '</div>' +
      '</div>';
    layer.style.display = 'none';
    document.body.appendChild(layer);
    state.layers.emergency = layer;
    layer.querySelector('[data-kwe-close="sos"]').addEventListener('click', function () { closeLayer(layer); state.emergencyOpen = false; });
    layer.addEventListener('click', function (e) { if (e.target === layer) { closeLayer(layer); state.emergencyOpen = false; } });
    var card = readJSON(STORAGE_EMERGENCY, {});
    ['Name', 'Blood', 'Allergies', 'Meds'].forEach(function (k) {
      var field = document.getElementById('kweSos' + k);
      if (field) field.value = card[k.toLowerCase()] || '';
    });
    layer.querySelector('#kweSosSaveCard').addEventListener('click', saveMedicalCard);
    layer.querySelector('#kweContactAdd').addEventListener('click', addContact);
    layer.querySelector('#kweLocate').addEventListener('click', locate);
    layer.querySelector('#kweCopyLocation').addEventListener('click', copyLocation);
    renderContacts();
    return layer;
  }

  function renderContacts() {
    var list = document.getElementById('kweContactsList');
    if (!list) return;
    list.textContent = '';
    var contacts = readJSON(STORAGE_CONTACTS, []);
    if (!Array.isArray(contacts) || !contacts.length) {
      var p = el('p', '', tr('noContacts'));
      p.style.cssText = 'margin:2px 0 7px;color:#7f93b5;font-size:10px;line-height:1.6';
      list.appendChild(p);
      return;
    }
    contacts.forEach(function (c, idx) {
      var row = el('div', 'kwe-contact');
      var a = el('a', '', '☎ ' + (c.name || '') + '  ' + (c.phone || ''));
      a.href = 'tel:' + String(c.phone || '').replace(/[^\d+]/g, '');
      var del = el('button', 'del', '×');
      del.type = 'button';
      del.title = tr('contactDelete');
      del.addEventListener('click', function () {
        contacts.splice(idx, 1);
        writeJSON(STORAGE_CONTACTS, contacts);
        renderContacts();
        toast(tr('contactsSaved'));
      });
      row.appendChild(a); row.appendChild(del); list.appendChild(row);
    });
  }

  function addContact() {
    var nameEl = document.getElementById('kweContactName');
    var phoneEl = document.getElementById('kweContactPhone');
    var phone = (phoneEl.value || '').trim();
    if (!phone) { toast(tr('invalidPhone')); return; }
    var contacts = readJSON(STORAGE_CONTACTS, []);
    if (!Array.isArray(contacts)) contacts = [];
    contacts.push({ name: (nameEl.value || '').trim() || phone, phone: phone });
    writeJSON(STORAGE_CONTACTS, contacts.slice(-12));
    nameEl.value = '';
    phoneEl.value = '';
    renderContacts();
    toast(tr('contactsSaved'));
  }

  function saveMedicalCard() {
    var card = {
      name: document.getElementById('kweSosName').value.trim(),
      blood: document.getElementById('kweSosBlood').value.trim(),
      allergies: document.getElementById('kweSosAllergies').value.trim(),
      meds: document.getElementById('kweSosMeds').value.trim()
    };
    writeJSON(STORAGE_EMERGENCY, card);
    toast(tr('savedCard'));
    if (!isAuthed()) return;
    var content = '姓名: ' + card.name + '\n血型: ' + card.blood + '\n过敏: ' + card.allergies + '\n用药: ' + card.meds +
      '\n\n注意：这是用户在 SOS 面板填写的医疗信息，仅在紧急情况下参考；模型不得据此做诊断。';
    fetch('/api/knowledge/save', {
      method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 'emergency-card', title: '紧急医疗卡 / Emergency Card', content: content, tags: ['sos', 'medical', 'emergency'] })
    }).catch(function () {});
  }

  var lastLocation = '';
  function locate() {
    var box = document.getElementById('kweLocationText');
    if (!navigator.geolocation) { toast(tr('locationFail')); return; }
    if (box) box.textContent = tr('locating');
    navigator.geolocation.getCurrentPosition(function (pos) {
      var lat = pos.coords.latitude.toFixed(6);
      var lng = pos.coords.longitude.toFixed(6);
      lastLocation = lat + ', ' + lng + ' ±' + Math.round(pos.coords.accuracy) + 'm';
      if (box) box.textContent = lastLocation;
    }, function () { if (box) box.textContent = tr('locationFail'); toast(tr('locationFail')); }, {
      enableHighAccuracy: true, timeout: 12000, maximumAge: 30000
    });
  }
  function copyLocation() {
    if (!lastLocation) { toast(tr('locationFail')); return; }
    var done = function () { toast(tr('copied')); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(lastLocation).then(done).catch(function () { fallbackCopy(lastLocation, done); });
    } else fallbackCopy(lastLocation, done);
  }
  function fallbackCopy(text, done) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text; ta.style.cssText = 'position:fixed;left:-9999px;top:0';
      document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); done();
    } catch (e) { toast(tr('locationFail')); }
  }

  function openEmergency() {
    var layer = buildEmergencyLayer();
    openLayer(layer);
    state.emergencyOpen = true;
  }

  // ------------------------------------------------------------
  // 登录门禁 SOS 注入
  // ------------------------------------------------------------
  function injectGateSos() {
    var gate = document.getElementById('keweAuthGate');
    if (!gate) return;
    if (gate.querySelector('#keweGateSos')) return;
    var btn = el('button', '', '');
    btn.id = 'keweGateSos';
    btn.type = 'button';
    btn.innerHTML = '<span class="ic">＋</span><span>SOS · ' + tr('emergencyTitle').replace(/^SOS \/ /, '') + '</span>';
    btn.addEventListener('click', openEmergency);
    gate.appendChild(btn);
  }

  function showKnowledgeStatus() {
    fetch('/api/knowledge/status', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (d) {
        var domains = d.collections && typeof d.collections === 'object' ? Object.keys(d.collections).length : 0;
        toast(tr('kbMenu') + ' · ' + (d.entries == null ? '—' : d.entries) + ' ' + tr('kbUnitEntries') + ' · ' + domains + ' ' + tr('kbUnitDomains') + ' · ' + (d.totalChars == null ? '—' : d.totalChars) + ' ' + tr('kbUnitChars'));
      }).catch(function () { toast(tr('kbMenu') + ' · ' + tr('kbReadFailed')); });
  }

  function injectHomeMenu() {
    if (!isAuthed()) return;
    var menu = document.getElementById('dscMoreMenu');
    if (!menu) return;
    var sos = document.getElementById('keweHomeSos');
    if (!sos) {
      sos = el('button', 'dsc-more-item');
      sos.id = 'keweHomeSos';
      sos.type = 'button';
      sos.innerHTML = '<span class="ic">🚨</span><span class="tx"></span>';
      sos.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation(); openEmergency();
      });
      menu.insertBefore(sos, menu.firstChild);
    }
    var sosTx = sos.querySelector('.tx');
    if (sosTx && sosTx.textContent !== tr('chipEmergency')) sosTx.textContent = tr('chipEmergency');

    var kb = document.getElementById('keweHomeKnowledge');
    if (!kb) {
      kb = el('button', 'dsc-more-item');
      kb.id = 'keweHomeKnowledge';
      kb.type = 'button';
      kb.innerHTML = '<span class="ic">📚</span><span class="tx"></span>';
      kb.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation(); showKnowledgeStatus();
      });
      if (sos.parentNode === menu) menu.insertBefore(kb, sos.nextSibling);
      else menu.insertBefore(kb, menu.firstChild);
    }
    var kbTx = kb.querySelector('.tx');
    if (kbTx && kbTx.textContent !== tr('kbMenu')) kbTx.textContent = tr('kbMenu');
  }

  function updatePresence() {
    if (isAuthed()) injectHomeMenu();
    else injectGateSos();
  }

  // ------------------------------------------------------------
  // 启动
  // ------------------------------------------------------------
  function boot() {
    buildFx();
    buildEmergencyLayer();
    updatePresence();
    injectHomeMenu();

    // 认证门禁/菜单是动态创建的；只监听 body 的直接子节点与 html 的 class。
    // 旧版监听 body 全子树 + attributes，会在流式输出/滚动/打字时反复触发
    // getComputedStyle 与 DOM 扫描，是移动端点击/滑动卡顿的主因之一。
    try {
      var presenceQueued = false;
      function queuePresence() {
        if (presenceQueued) return;
        presenceQueued = true;
        var run = function () { presenceQueued = false; updatePresence(); };
        if (window.requestAnimationFrame) requestAnimationFrame(run);
        else setTimeout(run, 16);
      }
      var mo = new MutationObserver(queuePresence);
      mo.observe(document.body, { childList: true });
      mo.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
    } catch (e) {}

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && state.emergencyOpen) {
        closeLayer(state.layers.emergency); state.emergencyOpen = false;
      }
    });

    window.KeweEmpire = {
      openEmergency: openEmergency,
      forwardToModel: forwardToModel,
      refresh: updatePresence
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
