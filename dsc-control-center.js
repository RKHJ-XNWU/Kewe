/* ============================================================
 * dsc-control-center.js —— 全局输出档位 + 实时上下文控制中心
 * 无依赖；六种语言；服务端持久化；本地估算与 provider usage 分开展示。
 * ============================================================ */
(function () {
    'use strict';

    var OPTIONS = [64000, 128000, 256000, 384000];
    var DEFAULT_OUTPUT = 256000;
    var LEGACY_OUTPUT = { 65536: 64000, 131072: 128000, 262144: 256000, 393216: 384000 };
    var CONTEXT_WINDOW = 1024000; // 1024K × 1000
    var STORAGE_KEY = 'dsc_output_limit_v2';
    var state = {
        output: DEFAULT_OUTPUT,
        server: null,
        serverKey: '',
        outputOpen: false,
        contextOpen: false,
        saving: false,
        contextLoading: false,
        lastFocus: null
    };

    var COPY = {
        zh: {
            outputOpen: '打开全模型最大输出选择器', outputTitle: '最大输出核心', outputSubtitle: '选择一个档位，立即强制应用到全部模型',
            outputEyebrow: '全局输出协议', maxOutput: '最大输出', currentChoice: '当前选择', outputHint: '四档自由选择 · 默认 256K · 自动保存',
            tier64: '疾速', tier128: '均衡', tier256: '深研', tier384: '无界',
            desc64: '短回复 · 低延迟', desc128: '日常对话 · 稳定均衡', desc256: '长文创作 · 深度推理 · 默认档位', desc384: '极限输出 · 最高档位',
            providerNote: '输出档位使用自定义 K：1K = 1000 tokens。此处设置的是请求上限；上游服务商自身的模型限制仍然有效。', outputSaved: '全模型最大输出已切换为 {0}', outputSaveError: '档位保存失败，请重试',
            contextOpen: '查看实时上下文窗口', contextTitle: '上下文窗口', contextSubtitle: '动态查看当前会话的上下文占用与真实用量', contextEyebrow: '实时上下文监测',
            live: '实时', estimated: '实时估算', providerReported: '上游实测', used: '已占用', remaining: '剩余空间', capacity: '窗口容量',
            messages: '消息数量', characters: '正文字符', currentModel: '当前模型', outputCap: '输出上限', cumulativeUsage: '累计真实用量',
            noProviderData: '完成一次模型请求后，这里会显示上游返回的真实 token 用量。', localEstimate: '占用值为本地与全会话统计的实时估算，不用于计费；上游实测值单独标注。',
            refreshNow: '立即刷新', close: '关闭', lastUpdated: '更新于 {0}', emptySession: '等待会话数据', tokens: 'tokens', syncing: '同步中',
            gameHint: '选择你的输出能量核心', defaultBadge: '默认', selectedBadge: '已装备', selectBadge: '选择', of: '/'
        },
        ja: {
            outputOpen: '全モデルの最大出力セレクターを開く', outputTitle: '最大出力コア', outputSubtitle: 'レベルを選ぶと、すべてのモデルへ即時に強制適用されます',
            outputEyebrow: 'グローバル出力プロトコル', maxOutput: '最大出力', currentChoice: '現在の選択', outputHint: '4 段階 · 初期値 256K · 自動保存',
            tier64: '迅速', tier128: '均衡', tier256: '深層', tier384: '無限',
            desc64: '短い応答 · 低遅延', desc128: '日常会話 · 安定バランス', desc256: '長文作成 · 深い推論 · 初期値', desc384: '極限出力 · 最高レベル',
            providerNote: '出力段階はカスタム K（1K = 1000 tokens）を使用します。ここで設定するのはリクエスト上限です。プロバイダー側のモデル制限も引き続き適用されます。', outputSaved: '全モデルの最大出力を {0} に切り替えました', outputSaveError: 'レベルの保存に失敗しました。もう一度お試しください',
            contextOpen: 'リアルタイムのコンテキストを表示', contextTitle: 'コンテキストウィンドウ', contextSubtitle: '現在の会話の使用量とプロバイダー実測値を動的に表示', contextEyebrow: 'リアルタイムコンテキスト監視',
            live: 'ライブ', estimated: 'リアルタイム推定', providerReported: 'プロバイダー実測', used: '使用量', remaining: '残り容量', capacity: 'ウィンドウ容量',
            messages: 'メッセージ数', characters: '本文の文字数', currentModel: '現在のモデル', outputCap: '出力上限', cumulativeUsage: '累計実測トークン',
            noProviderData: 'モデルリクエスト完了後、プロバイダーが返した実際の token 使用量を表示します。', localEstimate: '使用量はローカルと全会話統計によるリアルタイム推定で、課金には使用しません。プロバイダー実測値は別途表示します。',
            refreshNow: '今すぐ更新', close: '閉じる', lastUpdated: '{0} に更新', emptySession: '会話データを待機中', tokens: 'tokens', syncing: '同期中',
            gameHint: '出力エネルギーコアを選択', defaultBadge: '初期値', selectedBadge: '装備中', selectBadge: '選択', of: '/'
        },
        en: {
            outputOpen: 'Open maximum output selector for all models', outputTitle: 'Maximum output core', outputSubtitle: 'Choose a tier and enforce it instantly across every model',
            outputEyebrow: 'Global output protocol', maxOutput: 'Maximum output', currentChoice: 'Current selection', outputHint: 'Four tiers · 256K by default · Saved automatically',
            tier64: 'Swift', tier128: 'Balanced', tier256: 'Deep', tier384: 'Ultra',
            desc64: 'Short replies · Low latency', desc128: 'Daily chat · Stable balance', desc256: 'Long writing · Deep reasoning · Default', desc384: 'Extreme output · Maximum tier',
            providerNote: 'Output tiers use custom K: 1K = 1,000 tokens. This sets the requested cap; provider-specific model limits still apply.', outputSaved: 'Maximum output for all models is now {0}', outputSaveError: 'Could not save the tier. Please try again.',
            contextOpen: 'View live context window', contextTitle: 'Context window', contextSubtitle: 'Live occupancy for this conversation and reported provider usage', contextEyebrow: 'Live context monitor',
            live: 'Live', estimated: 'Live estimate', providerReported: 'Provider reported', used: 'Used', remaining: 'Remaining', capacity: 'Window capacity',
            messages: 'Messages', characters: 'Content characters', currentModel: 'Current model', outputCap: 'Output cap', cumulativeUsage: 'Cumulative reported usage',
            noProviderData: 'After a model request completes, the token usage reported by the provider will appear here.', localEstimate: 'Occupancy is a live estimate from local and full-session statistics, never a billing value. Provider-reported usage is labelled separately.',
            refreshNow: 'Refresh now', close: 'Close', lastUpdated: 'Updated at {0}', emptySession: 'Waiting for conversation data', tokens: 'tokens', syncing: 'Syncing',
            gameHint: 'Choose your output energy core', defaultBadge: 'Default', selectedBadge: 'Equipped', selectBadge: 'Select', of: '/'
        },
        ko: {
            outputOpen: '모든 모델의 최대 출력 선택기 열기', outputTitle: '최대 출력 코어', outputSubtitle: '단계를 선택하면 모든 모델에 즉시 강제 적용됩니다',
            outputEyebrow: '전역 출력 프로토콜', maxOutput: '최대 출력', currentChoice: '현재 선택', outputHint: '4단계 · 기본값 256K · 자동 저장',
            tier64: '신속', tier128: '균형', tier256: '심층', tier384: '초월',
            desc64: '짧은 답변 · 낮은 지연', desc128: '일상 대화 · 안정적 균형', desc256: '장문 작성 · 심층 추론 · 기본값', desc384: '극한 출력 · 최고 단계',
            providerNote: '출력 단계는 사용자 지정 K(1K = 1000 tokens)를 사용합니다. 여기서 설정하는 값은 요청 상한이며, 제공사의 모델별 제한도 계속 적용됩니다.', outputSaved: '모든 모델의 최대 출력이 {0}(으)로 변경되었습니다', outputSaveError: '단계를 저장하지 못했습니다. 다시 시도하세요',
            contextOpen: '실시간 컨텍스트 창 보기', contextTitle: '컨텍스트 윈도우', contextSubtitle: '현재 대화의 점유율과 제공사 실측 사용량을 실시간으로 확인', contextEyebrow: '실시간 컨텍스트 모니터',
            live: '실시간', estimated: '실시간 추정', providerReported: '제공사 실측', used: '사용량', remaining: '남은 공간', capacity: '창 용량',
            messages: '메시지 수', characters: '본문 문자 수', currentModel: '현재 모델', outputCap: '출력 상한', cumulativeUsage: '누적 실측 사용량',
            noProviderData: '모델 요청이 완료되면 제공사가 반환한 실제 token 사용량이 여기에 표시됩니다.', localEstimate: '점유량은 로컬 및 전체 대화 통계의 실시간 추정값으로 과금에 사용되지 않습니다. 제공사 실측값은 별도로 표시합니다.',
            refreshNow: '지금 새로고침', close: '닫기', lastUpdated: '{0} 업데이트', emptySession: '대화 데이터 대기 중', tokens: 'tokens', syncing: '동기화 중',
            gameHint: '출력 에너지 코어를 선택하세요', defaultBadge: '기본값', selectedBadge: '장착됨', selectBadge: '선택', of: '/'
        },
        ru: {
            outputOpen: 'Открыть выбор максимального вывода для всех моделей', outputTitle: 'Ядро максимального вывода', outputSubtitle: 'Выберите уровень — он немедленно применится ко всем моделям',
            outputEyebrow: 'Глобальный протокол вывода', maxOutput: 'Максимальный вывод', currentChoice: 'Текущий выбор', outputHint: 'Четыре уровня · 256K по умолчанию · Автосохранение',
            tier64: 'Быстро', tier128: 'Баланс', tier256: 'Глубоко', tier384: 'Максимум',
            desc64: 'Короткие ответы · Низкая задержка', desc128: 'Ежедневный чат · Стабильный баланс', desc256: 'Длинные тексты · Глубокий анализ · По умолчанию', desc384: 'Предельный вывод · Максимальный уровень',
            providerNote: 'Для уровней вывода используется пользовательский K: 1K = 1000 tokens. Здесь задаётся лимит запроса; собственные ограничения моделей у провайдера также действуют.', outputSaved: 'Максимальный вывод всех моделей переключён на {0}', outputSaveError: 'Не удалось сохранить уровень. Повторите попытку',
            contextOpen: 'Открыть контекстное окно в реальном времени', contextTitle: 'Контекстное окно', contextSubtitle: 'Динамическая загрузка текущего диалога и фактические данные провайдера', contextEyebrow: 'Мониторинг контекста в реальном времени',
            live: 'Онлайн', estimated: 'Оценка в реальном времени', providerReported: 'Данные провайдера', used: 'Занято', remaining: 'Осталось', capacity: 'Ёмкость окна',
            messages: 'Сообщения', characters: 'Символы текста', currentModel: 'Текущая модель', outputCap: 'Лимит вывода', cumulativeUsage: 'Суммарное фактическое использование',
            noProviderData: 'После завершения запроса здесь появятся фактические данные о tokens от провайдера.', localEstimate: 'Загрузка — это оперативная оценка по локальным и полным данным диалога, а не значение для оплаты. Данные провайдера показаны отдельно.',
            refreshNow: 'Обновить сейчас', close: 'Закрыть', lastUpdated: 'Обновлено в {0}', emptySession: 'Ожидание данных диалога', tokens: 'tokens', syncing: 'Синхронизация',
            gameHint: 'Выберите энергетическое ядро вывода', defaultBadge: 'По умолчанию', selectedBadge: 'Выбрано', selectBadge: 'Выбрать', of: '/'
        },
        fr: {
            outputOpen: 'Ouvrir le sélecteur de sortie maximale pour tous les modèles', outputTitle: 'Noyau de sortie maximale', outputSubtitle: 'Choisissez un niveau pour l’imposer immédiatement à tous les modèles',
            outputEyebrow: 'Protocole global de sortie', maxOutput: 'Sortie maximale', currentChoice: 'Sélection actuelle', outputHint: 'Quatre niveaux · 256K par défaut · Enregistrement automatique',
            tier64: 'Rapide', tier128: 'Équilibré', tier256: 'Profond', tier384: 'Ultime',
            desc64: 'Réponses courtes · Faible latence', desc128: 'Dialogue quotidien · Équilibre stable', desc256: 'Textes longs · Raisonnement profond · Par défaut', desc384: 'Sortie extrême · Niveau maximal',
            providerNote: 'Les niveaux de sortie utilisent un K personnalisé : 1K = 1 000 tokens. Ceci définit la limite demandée ; les restrictions propres aux modèles du fournisseur restent applicables.', outputSaved: 'La sortie maximale de tous les modèles est passée à {0}', outputSaveError: 'Impossible d’enregistrer le niveau. Réessayez',
            contextOpen: 'Afficher la fenêtre de contexte en direct', contextTitle: 'Fenêtre de contexte', contextSubtitle: 'Occupation dynamique de la conversation et usage réel du fournisseur', contextEyebrow: 'Surveillance du contexte en direct',
            live: 'Direct', estimated: 'Estimation en direct', providerReported: 'Données fournisseur', used: 'Utilisé', remaining: 'Espace restant', capacity: 'Capacité de la fenêtre',
            messages: 'Messages', characters: 'Caractères du contenu', currentModel: 'Modèle actuel', outputCap: 'Limite de sortie', cumulativeUsage: 'Usage réel cumulé',
            noProviderData: 'Après une requête, les tokens réels renvoyés par le fournisseur apparaîtront ici.', localEstimate: 'L’occupation est une estimation en direct fondée sur les statistiques locales et globales, jamais une valeur de facturation. Les données du fournisseur sont indiquées séparément.',
            refreshNow: 'Actualiser', close: 'Fermer', lastUpdated: 'Mis à jour à {0}', emptySession: 'En attente des données de conversation', tokens: 'tokens', syncing: 'Synchronisation',
            gameHint: 'Choisissez votre noyau d’énergie de sortie', defaultBadge: 'Défaut', selectedBadge: 'Équipé', selectBadge: 'Choisir', of: '/'
        }
    };

    function lang() {
        try {
            var l = String(window.I18N && window.I18N.getLang ? window.I18N.getLang() : 'zh').slice(0, 2);
            return COPY[l] ? l : 'zh';
        } catch (e) { return 'zh'; }
    }
    function tr(key) {
        var pack = COPY[lang()] || COPY.zh;
        var value = pack[key] == null ? key : pack[key];
        if (arguments.length > 1) {
            var args = Array.prototype.slice.call(arguments, 1);
            value = String(value).replace(/\{(\d+)\}/g, function (m, i) {
                return args[i] == null ? m : String(args[i]);
            });
        }
        return value;
    }
    function $(id) { return document.getElementById(id); }
    function validOutput(value) { var n = LEGACY_OUTPUT[Number(value)] || Number(value); return OPTIONS.indexOf(n) >= 0 ? n : DEFAULT_OUTPUT; }
    function label(tokens) { return (Number(tokens) / 1000) + 'K'; }
    function formatInt(value) {
        try { return Math.max(0, Number(value) || 0).toLocaleString(lang() === 'zh' ? 'zh-CN' : lang()); }
        catch (e) { return String(Math.max(0, Number(value) || 0)); }
    }
    function formatCompact(value) {
        var n = Math.max(0, Number(value) || 0);
        if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace('.0', '') + 'K';
        return String(Math.round(n));
    }
    function notify(message, type) {
        var host = $('dscCcToastRegion');
        if (!host) {
            host = document.createElement('div');
            host.id = 'dscCcToastRegion';
            host.className = 'dsc-cc-toast-region';
            host.setAttribute('aria-live', 'polite');
            document.body.appendChild(host);
        }
        var item = document.createElement('div');
        item.className = 'dsc-cc-toast ' + (type || 'info');
        item.textContent = message;
        host.appendChild(item);
        setTimeout(function () { item.classList.add('leaving'); }, 2600);
        setTimeout(function () { if (item.parentNode) item.parentNode.removeChild(item); }, 3000);
    }

    function buildUi() {
        if (!$('dscOutputOverlay')) {
            var output = document.createElement('div');
            output.id = 'dscOutputOverlay';
            output.className = 'dsc-cc-overlay';
            output.setAttribute('aria-hidden', 'true');
            output.innerHTML =
                '<section class="dsc-cc-dialog dsc-output-dialog" role="dialog" aria-modal="true" aria-labelledby="dscOutputTitle">' +
                '<div class="dsc-cc-aurora" aria-hidden="true"></div>' +
                '<header class="dsc-cc-head"><div><div class="dsc-cc-eyebrow" data-cc="outputEyebrow"></div>' +
                '<h2 id="dscOutputTitle" data-cc="outputTitle"></h2><p data-cc="outputSubtitle"></p></div>' +
                '<button type="button" class="dsc-cc-close" data-close="output" aria-label="Close">×</button></header>' +
                '<div class="dsc-output-core" aria-hidden="true"><span class="dsc-core-orbit orbit-a"></span><span class="dsc-core-orbit orbit-b"></span>' +
                '<div class="dsc-core-center"><small data-cc="currentChoice"></small><strong id="dscOutputCurrent">256K</strong><span data-cc="maxOutput"></span></div></div>' +
                '<div class="dsc-output-game-hint" data-cc="gameHint"></div><div id="dscOutputOptions" class="dsc-output-options" role="radiogroup"></div>' +
                '<div class="dsc-output-meta"><span data-cc="outputHint"></span><span class="dsc-output-global" data-cc="outputEyebrow"></span></div>' +
                '<p class="dsc-cc-note" data-cc="providerNote"></p></section>';
            document.body.appendChild(output);
        }
        if (!$('dscContextOverlay')) {
            var context = document.createElement('div');
            context.id = 'dscContextOverlay';
            context.className = 'dsc-cc-overlay';
            context.setAttribute('aria-hidden', 'true');
            context.innerHTML =
                '<section class="dsc-cc-dialog dsc-context-dialog" role="dialog" aria-modal="true" aria-labelledby="dscContextTitle">' +
                '<header class="dsc-cc-head"><div><div class="dsc-cc-eyebrow" data-cc="contextEyebrow"></div>' +
                '<h2 id="dscContextTitle" data-cc="contextTitle"></h2><p data-cc="contextSubtitle"></p></div>' +
                '<button type="button" class="dsc-cc-close" data-close="context" aria-label="Close">×</button></header>' +
                '<div class="dsc-context-hero"><div class="dsc-context-ring-wrap"><svg class="dsc-context-ring" viewBox="0 0 128 128" aria-hidden="true">' +
                '<defs><linearGradient id="dscCtxGradient" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#22d3ee"/><stop offset=".55" stop-color="#0ea5e9"/><stop offset="1" stop-color="#14b8a6"/></linearGradient></defs>' +
                '<circle class="dsc-ring-track" cx="64" cy="64" r="54"/><circle id="dscCtxRingProgress" class="dsc-ring-progress" cx="64" cy="64" r="54"/></svg>' +
                '<div class="dsc-ring-value"><strong id="dscCtxPercent">0%</strong><span data-cc="used"></span></div></div>' +
                '<div class="dsc-context-primary"><div class="dsc-live-pill"><i></i><span data-cc="live"></span></div>' +
                '<div class="dsc-context-used"><strong id="dscCtxUsed">0</strong><span data-cc="tokens"></span></div>' +
                '<div class="dsc-context-remaining"><span data-cc="remaining"></span><strong id="dscCtxRemaining">1024K</strong></div>' +
                '<div class="dsc-context-model"><span data-cc="currentModel"></span><strong id="dscCtxModel">—</strong></div></div></div>' +
                '<div class="dsc-context-grid"><div><span data-cc="capacity"></span><strong>1024K</strong></div>' +
                '<div><span data-cc="outputCap"></span><strong id="dscCtxOutput">256K</strong></div>' +
                '<div><span data-cc="messages"></span><strong id="dscCtxMessages">0</strong></div>' +
                '<div><span data-cc="characters"></span><strong id="dscCtxCharacters">0</strong></div></div>' +
                '<div class="dsc-provider-card"><div class="dsc-provider-title"><span data-cc="providerReported"></span><strong id="dscCtxReported">—</strong></div>' +
                '<div class="dsc-provider-row"><span data-cc="cumulativeUsage"></span><strong id="dscCtxBilled">—</strong></div>' +
                '<p id="dscCtxProviderNote" data-cc="noProviderData"></p></div>' +
                '<p class="dsc-cc-note" data-cc="localEstimate"></p>' +
                '<footer class="dsc-context-footer"><span id="dscCtxUpdated" class="dsc-context-updated"></span>' +
                '<button type="button" id="dscCtxRefresh" class="dsc-cc-refresh" data-cc="refreshNow"></button></footer></section>';
            document.body.appendChild(context);
        }
        buildOutputOptions();
        renderTexts();
    }

    function buildOutputOptions() {
        var host = $('dscOutputOptions');
        if (!host) return;
        host.innerHTML = '';
        OPTIONS.forEach(function (tokens, index) {
            var key = label(tokens).replace('K', '');
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'dsc-output-option tier-' + key;
            button.dataset.tokens = String(tokens);
            button.setAttribute('role', 'radio');
            button.innerHTML =
                '<span class="dsc-option-scan" aria-hidden="true"></span><span class="dsc-option-index">0' + (index + 1) + '</span>' +
                '<span class="dsc-option-tier" data-tier></span><strong>' + label(tokens) + '</strong>' +
                '<span class="dsc-option-tokens">' + formatInt(tokens) + ' ' + tr('tokens') + '</span>' +
                '<span class="dsc-option-desc" data-desc></span><span class="dsc-option-badge" data-badge></span>';
            button.addEventListener('click', function () { selectOutput(tokens); });
            host.appendChild(button);
        });
    }

    function renderTexts() {
        var nodes = document.querySelectorAll('[data-cc]');
        for (var i = 0; i < nodes.length; i++) {
            var key = nodes[i].getAttribute('data-cc');
            nodes[i].textContent = tr(key);
        }
        var outputBtn = $('dscOutputLimitBtn');
        var contextBtn = $('dscContextBtn');
        if (outputBtn) { outputBtn.title = tr('outputOpen'); outputBtn.setAttribute('aria-label', tr('outputOpen')); }
        if (contextBtn) { contextBtn.title = tr('contextOpen'); contextBtn.setAttribute('aria-label', tr('contextOpen')); }
        var closeButtons = document.querySelectorAll('.dsc-cc-close');
        for (var j = 0; j < closeButtons.length; j++) closeButtons[j].setAttribute('aria-label', tr('close'));
        var options = document.querySelectorAll('.dsc-output-option');
        for (var k = 0; k < options.length; k++) {
            var tokens = Number(options[k].dataset.tokens);
            var key = label(tokens).replace('K', '');
            options[k].querySelector('[data-tier]').textContent = tr('tier' + key);
            options[k].querySelector('[data-desc]').textContent = tr('desc' + key);
            options[k].querySelector('.dsc-option-tokens').textContent = formatInt(tokens) + ' ' + tr('tokens');
        }
        renderOutput();
        updateContext();
    }

    function renderOutput() {
        var current = label(state.output);
        var ids = ['dscOutputCurrent', 'dscOutputButtonValue', 'dscCtxOutput'];
        ids.forEach(function (id) { if ($(id)) $(id).textContent = current; });
        var options = document.querySelectorAll('.dsc-output-option');
        for (var i = 0; i < options.length; i++) {
            var on = Number(options[i].dataset.tokens) === state.output;
            options[i].classList.toggle('selected', on);
            options[i].setAttribute('aria-checked', on ? 'true' : 'false');
            var badge = options[i].querySelector('[data-badge]');
            if (badge) badge.textContent = on ? tr('selectedBadge') : (Number(options[i].dataset.tokens) === DEFAULT_OUTPUT ? tr('defaultBadge') : tr('selectBadge'));
            options[i].disabled = state.saving;
        }
        document.documentElement.style.setProperty('--dsc-output-tier', '"' + current + '"');
    }

    function applyOutput(value, dispatch) {
        state.output = validOutput(value);
        try { localStorage.setItem(STORAGE_KEY, String(state.output)); } catch (e) {}
        try { if (typeof window.dscSetOutputLimit === 'function') window.dscSetOutputLimit(state.output); } catch (e1) {}
        renderOutput();
        if (dispatch) {
            try { window.dispatchEvent(new CustomEvent('dsc:outputchange', { detail: { tokens: state.output, label: label(state.output) } })); } catch (e2) {}
        }
    }

    async function loadOutput() {
        var local = DEFAULT_OUTPUT;
        try { local = validOutput(localStorage.getItem(STORAGE_KEY)); } catch (e) {}
        applyOutput(local, false);
        try {
            var res = await fetch('/api/ds-chat/output-limit', { cache: 'no-store' });
            if (!res.ok) throw new Error('HTTP ' + res.status);
            var data = await res.json();
            applyOutput(data.maxOutput, false);
        } catch (e2) { /* 离线时保留本地值，后端恢复后仍会读取其持久化档位。 */ }
    }

    async function selectOutput(tokens) {
        tokens = validOutput(tokens);
        if (state.saving) return;
        if (tokens === state.output) { closePanel('output'); return; }
        state.saving = true;
        renderOutput();
        try {
            var res = await fetch('/api/ds-chat/output-limit', {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ tokens: tokens })
            });
            var data = await res.json().catch(function () { return {}; });
            if (!res.ok || !data.success) throw new Error(data.error || ('HTTP ' + res.status));
            applyOutput(data.maxOutput || tokens, true);
            notify(tr('outputSaved', label(state.output)), 'success');
            setTimeout(function () { closePanel('output'); }, 180);
        } catch (e) {
            notify(tr('outputSaveError'), 'error');
        } finally {
            state.saving = false;
            renderOutput();
        }
    }

    function estimateTextTokens(text) {
        var s = String(text == null ? '' : text);
        if (!s) return 0;
        var cjk = (s.match(/[\u3000-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff]/g) || []).length;
        var length = 0;
        try { length = Array.from(s).length; } catch (e) { length = s.length; }
        return cjk + Math.ceil(Math.max(0, length - cjk) / 4);
    }

    function liveSnapshot() {
        try {
            if (typeof window.dscGetLiveContext === 'function') return window.dscGetLiveContext();
        } catch (e) {}
        return { sessionId: '', messages: [], draft: '', liveContent: '', liveReasoning: '', sending: false, model: '', dimension: 'ds' };
    }

    function localEstimate(snapshot) {
        var total = estimateTextTokens(snapshot.draft) + estimateTextTokens(snapshot.liveContent) + estimateTextTokens(snapshot.liveReasoning);
        var messages = snapshot.messages || [];
        for (var i = 0; i < messages.length; i++) {
            total += 4 + estimateTextTokens(messages[i] && messages[i].content);
        }
        return total;
    }

    function updateContext() {
        var snap = liveSnapshot();
        var key = String(snap.sessionId || '') + '|' + String(snap.dimension || 'ds');
        var server = state.server && state.serverKey === key ? state.server : null;
        var local = localEstimate(snap);
        var estimated = Math.max(local, server ? Number(server.estimatedTokens) || 0 : 0);
        var reported = server ? Number(server.reportedTokens) || 0 : 0;
        var used = Math.max(estimated, reported);
        var ratio = Math.min(1, used / CONTEXT_WINDOW);
        var percent = ratio * 100;
        var remaining = Math.max(0, CONTEXT_WINDOW - used);
        if ($('dscCtxUsed')) $('dscCtxUsed').textContent = formatInt(used);
        if ($('dscCtxRemaining')) $('dscCtxRemaining').textContent = formatCompact(remaining);
        if ($('dscCtxPercent')) $('dscCtxPercent').textContent = (percent < 0.1 && percent > 0 ? percent.toFixed(2) : percent.toFixed(1)) + '%';
        if ($('dscCtxRingProgress')) {
            $('dscCtxRingProgress').style.strokeDashoffset = String(339.292 * (1 - ratio));
            $('dscCtxRingProgress').classList.toggle('warning', ratio >= 0.75);
            $('dscCtxRingProgress').classList.toggle('danger', ratio >= 0.9);
        }
        if ($('dscCtxMessages')) $('dscCtxMessages').textContent = formatInt(server ? server.messages : (snap.messages || []).length);
        if ($('dscCtxCharacters')) $('dscCtxCharacters').textContent = formatInt(server ? server.characters : 0);
        if ($('dscCtxModel')) $('dscCtxModel').textContent = snap.model || tr('emptySession');
        if ($('dscCtxReported')) $('dscCtxReported').textContent = reported ? formatInt(reported) + ' ' + tr('tokens') : '—';
        if ($('dscCtxBilled')) $('dscCtxBilled').textContent = server && server.billedTokens ? formatInt(server.billedTokens) + ' ' + tr('tokens') : '—';
        if ($('dscCtxProviderNote')) $('dscCtxProviderNote').textContent = reported ? '' : tr('noProviderData');
        if ($('dscCtxUpdated')) {
            var time = new Date();
            $('dscCtxUpdated').textContent = tr('lastUpdated', time.toLocaleTimeString(lang(), { hour: '2-digit', minute: '2-digit', second: '2-digit' }));
        }
        var compact = $('dscContextCompactValue');
        if (compact) compact.textContent = formatCompact(used);
        var compactPct = $('dscContextCompactPct');
        if (compactPct) compactPct.textContent = Math.round(percent) + '%';
        var contextBtn = $('dscContextBtn');
        if (contextBtn) {
            contextBtn.style.setProperty('--context-fill', percent.toFixed(2) + '%');
            contextBtn.classList.toggle('warning', ratio >= 0.75);
            contextBtn.classList.toggle('danger', ratio >= 0.9);
            contextBtn.setAttribute('data-used', String(used));
        }
        return { used: used, remaining: remaining, percent: percent, reported: reported, estimated: estimated, model: snap.model };
    }

    async function refreshContext() {
        var snap = liveSnapshot();
        if (!snap.sessionId || state.contextLoading) { updateContext(); return; }
        var key = String(snap.sessionId) + '|' + String(snap.dimension || 'ds');
        state.contextLoading = true;
        try {
            var url = '/api/ds-chat/context?sessionId=' + encodeURIComponent(snap.sessionId) +
                '&dim=' + encodeURIComponent(snap.dimension || 'ds') + '&model=' + encodeURIComponent(snap.model || '');
            var res = await fetch(url, { cache: 'no-store' });
            if (!res.ok) throw new Error('HTTP ' + res.status);
            var data = await res.json();
            state.server = data;
            state.serverKey = key;
            if (data.maxOutput) applyOutput(data.maxOutput, false);
        } catch (e) {
            if (state.serverKey !== key) { state.server = null; state.serverKey = key; }
        } finally {
            state.contextLoading = false;
            updateContext();
        }
    }

    function openPanel(name) {
        buildUi();
        var isOutput = name === 'output';
        var overlay = $(isOutput ? 'dscOutputOverlay' : 'dscContextOverlay');
        if (!overlay) return;
        closePanel(isOutput ? 'context' : 'output', true);
        state.lastFocus = document.activeElement;
        state[isOutput ? 'outputOpen' : 'contextOpen'] = true;
        overlay.classList.add('open');
        overlay.setAttribute('aria-hidden', 'false');
        document.body.classList.add('dsc-cc-modal-open');
        if (!isOutput) refreshContext();
        var focus = overlay.querySelector(isOutput ? '.dsc-output-option.selected' : '.dsc-cc-close');
        setTimeout(function () { if (focus) focus.focus(); }, 60);
    }

    function closePanel(name, silent) {
        var isOutput = name === 'output';
        var overlay = $(isOutput ? 'dscOutputOverlay' : 'dscContextOverlay');
        state[isOutput ? 'outputOpen' : 'contextOpen'] = false;
        if (overlay) { overlay.classList.remove('open'); overlay.setAttribute('aria-hidden', 'true'); }
        if (!state.outputOpen && !state.contextOpen) document.body.classList.remove('dsc-cc-modal-open');
        if (!silent && state.lastFocus && state.lastFocus.focus) {
            try { state.lastFocus.focus(); } catch (e) {}
        }
    }

    function trapFocus(event) {
        if (event.key === 'Escape') {
            if (state.outputOpen) closePanel('output');
            if (state.contextOpen) closePanel('context');
            return;
        }
        if (event.key !== 'Tab' || (!state.outputOpen && !state.contextOpen)) return;
        var overlay = $(state.outputOpen ? 'dscOutputOverlay' : 'dscContextOverlay');
        if (!overlay) return;
        var list = overlay.querySelectorAll('button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]');
        if (!list.length) return;
        var first = list[0], last = list[list.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }

    function bindEvents() {
        var outputBtn = $('dscOutputLimitBtn');
        var contextBtn = $('dscContextBtn');
        if (outputBtn) outputBtn.addEventListener('click', function () { openPanel('output'); });
        if (contextBtn) contextBtn.addEventListener('click', function () { openPanel('context'); });
        ['dscOutputOverlay', 'dscContextOverlay'].forEach(function (id) {
            var overlay = $(id);
            if (!overlay) return;
            overlay.addEventListener('click', function (event) {
                if (event.target === overlay) closePanel(id === 'dscOutputOverlay' ? 'output' : 'context');
                var close = event.target.closest ? event.target.closest('[data-close]') : null;
                if (close) closePanel(close.getAttribute('data-close'));
            });
        });
        if ($('dscCtxRefresh')) $('dscCtxRefresh').addEventListener('click', refreshContext);
        document.addEventListener('keydown', trapFocus);
        window.addEventListener('dsc:langchange', function () { buildOutputOptions(); renderTexts(); });
        var input = $('dscInput');
        if (input) input.addEventListener('input', updateContext, { passive: true });
        document.addEventListener('visibilitychange', function () { if (!document.hidden) { updateContext(); if (state.contextOpen) refreshContext(); } });
    }

    function init() {
        buildUi();
        bindEvents();
        loadOutput();
        updateContext();
        refreshContext();
        setInterval(updateContext, 500);
        setInterval(function () { if (state.contextOpen && !document.hidden) refreshContext(); }, 2500);
    }

    window.DscControlCenter = {
        options: OPTIONS.slice(),
        defaultOutput: DEFAULT_OUTPUT,
        contextWindow: CONTEXT_WINDOW,
        getOutputLimit: function () { return state.output; },
        getContextSnapshot: updateContext,
        estimateTextTokens: estimateTextTokens,
        refreshContext: refreshContext,
        openOutput: function () { openPanel('output'); },
        openContext: function () { openPanel('context'); }
    };

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
})();
