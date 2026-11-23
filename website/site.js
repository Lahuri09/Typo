document.body.classList.add("js");

const nav = document.getElementById("navigation");
const menu = document.querySelector(".mobile-toggle");

function toggleMenu(open) {
  nav.classList.toggle("open", open);
  menu.setAttribute("aria-expanded", String(open));
  menu.textContent = open ? "Закрыть" : "Меню";
}

menu.addEventListener("click", () => toggleMenu(menu.getAttribute("aria-expanded") === "false"));
nav.addEventListener("click", (event) => {
  if (event.target.closest("a")) toggleMenu(false);
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && menu.getAttribute("aria-expanded") === "true") {
    toggleMenu(false);
    menu.focus();
  }
});

function bindTabs(list, panel, activate) {
  const buttons = [...list.querySelectorAll('[role="tab"]')];
  function set(active) {
    for (const button of buttons) {
      button.setAttribute("aria-selected", String(button === active));
      button.tabIndex = button === active ? 0 : -1;
    }
    panel.setAttribute("aria-labelledby", active.id);
    activate(active);
  }
  for (const button of buttons) button.addEventListener("click", () => set(button));
  list.addEventListener("keydown", (event) => {
    const current = buttons.indexOf(document.activeElement);
    if (current < 0) return;
    let next;
    if (event.key === "ArrowRight") next = (current + 1) % buttons.length;
    else if (event.key === "ArrowLeft") next = (current + buttons.length - 1) % buttons.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = buttons.length - 1;
    else return;
    event.preventDefault();
    set(buttons[next]);
    buttons[next].focus();
  });
}

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const motionEase = getComputedStyle(document.documentElement).getPropertyValue("--ease").trim();

function showFrame(element) {
  if (reducedMotion.matches || !element.animate) return;
  element.getAnimations().forEach((animation) => animation.cancel());
  element.animate(
    [{ opacity: .2, transform: "translateY(5px)" }, { opacity: 1, transform: "translateY(0)" }],
    { duration: 200, easing: motionEase },
  );
}

function playback(render, onState) {
  let timeout;
  let running = false;

  function stop() {
    clearTimeout(timeout);
    running = false;
    onState(false);
  }

  return {
    stop,
    get running() { return running; },
    play(length, interval = 1080, loop = false) {
      stop();
      running = true;
      onState(true);
      function next(index, cycle) {
        render(index, cycle);
        const last = index === length - 1;
        if (last && !loop) {
          stop();
          return;
        }
        const delay = typeof interval === "function" ? interval(index) : interval;
        timeout = setTimeout(() => next(last ? 0 : index + 1, last ? cycle + 1 : cycle), delay);
      }
      next(0, 0);
    },
  };
}

const editSamples = [
  ["Оля привет, я уже закончил отчёт. Завтра скину его тебе на почту, чтобы ты могла его посмотреть.",
   "Оля, привет! Я уже закончил отчёт. Завтра скину его тебе на почту, чтобы ты могла его посмотреть."],
  ["Оля, привет! Я закончил отчёт. Завтра вышлю отчёт тебе на почту, чтобы ты смогла ознакомиться с отчётом.",
   "Оля, привет! Завтра пришлю готовый отчёт на почту."],
  ["Оля, привет! С отчётом всё готово, завтра скину его тебе на почту.",
   "Ольга, добрый день! Отчёт готов. Отправлю его вам по электронной почте завтра."],
  ["Ольга, уведомляю о завершении подготовки отчёта. Документ будет направлен вам завтра.",
   "Оля, привет! Отчёт готов. Завтра пришлю его тебе."],
];

const examples = {
  voice: {
    title: "Диктуйте в любом поле",
    description: "Надиктуйте сообщение, письмо или заметку. Текст появится там, где стоит курсор.",
    context: "Сообщение коллеге",
    frames: [
      { text: "", action: "recording", time: "2:00", hold: 880 },
      { text: "Перенесём созвон", action: "recording", time: "1:59", partial: true, hold: 650 },
      { text: "Перенесём созвон на завтра.", action: "recording", time: "1:58", hold: 1350 },
      { text: "Перенесём созвон на завтра. В одиннадцать удобно?", action: "recording", time: "1:57", hold: 1550 },
      { text: "Перенесём созвон на завтра. В одиннадцать удобно?", action: "done" },
    ],
  },
  edit: {
    title: "Правьте выделенный текст",
    description: "Исправляйте ошибки, сокращайте текст или меняйте его тон. Результат появится прямо в документе.",
    context: "Заметка",
    frames: [
      { action: "idle", hold: 1250 },
      { action: "select", hold: 1200 },
      { action: "aim", hold: 760 },
      { action: "press", hold: 520 },
      { action: "done" },
    ],
  },
  layout: {
    title: "Печатайте на своём языке",
    description: "Typo исправляет раскладку прямо во время набора. Исправление можно отменить своей клавишей.",
    context: "Сообщение в чате",
    frames: [
      { text: "", key: "ABC", action: "typing", hold: 850 },
      { text: "gh", key: "ABC", action: "typing", partial: true, hold: 390 },
      { text: "ghbd", key: "ABC", action: "typing", partial: true, hold: 420 },
      { text: "ghbdtn", key: "ABC", action: "typing", hold: 1050 },
      { text: "привет", key: "РУС", action: "done" },
    ],
  },

};

const examplePanel = document.getElementById("example-panel");
const exampleTabs = document.getElementById("example-tabs");
const exampleTitle = document.getElementById("example-title");
const exampleDescription = document.getElementById("example-description");
const exampleContext = document.getElementById("example-context");
const exampleText = document.getElementById("example-text");
const runExample = document.getElementById("example-run");
const exampleContent = document.getElementById("example-content");
const exampleArt = document.getElementById("example-art");
const exampleTime = document.getElementById("example-time");
const exampleKey = document.getElementById("example-key");

let mode = "voice";
let currentFrame = 0;
let currentCycle = 0;
let exampleVisible = false;
let autoplay = true;
const editChoices = [...document.querySelectorAll("#example-choices [data-choice]")];
let exampleStarted = false;
let artEntrance;

function renderExample(index, cycle = currentCycle) {
  const frame = examples[mode].frames[index];
  currentFrame = index;
  currentCycle = cycle;
  exampleContent.dataset.action = frame.action;
  let text = frame.text ?? "";
  if (mode === "edit") {
    const choice = cycle % editSamples.length;
    text = editSamples[choice][frame.action === "done" ? 1 : 0];
    editChoices.forEach((card, index) => card.classList.toggle("is-target", index === choice));
  }
  if (exampleText.textContent !== text) exampleText.textContent = text;
  exampleTime.textContent = frame.time || "";
  exampleKey.hidden = !frame.key;
  exampleKey.textContent = frame.key || "";
}

function nextReducedFrame() {
  return examples[mode].frames.findIndex((frame, index) => index > currentFrame && !frame.partial);
}

function updateExampleControl(playing = examplePlayer.running) {
  runExample.hidden = false;
  exampleContent.dataset.playing = String(playing);
  if (reducedMotion.matches) {
    runExample.textContent = nextReducedFrame() === -1 ? "К началу" : "Следующий шаг";
  } else {
    runExample.textContent = playing ? "Остановить" : exampleStarted ? "Повторить" : "Смотреть пример";
  }
}

const examplePlayer = playback(renderExample, updateExampleControl);

function playExample() {
  const frames = examples[mode].frames;
  if (reducedMotion.matches || !exampleVisible || !autoplay || document.hidden) return;
  exampleStarted = true;
  examplePlayer.play(frames.length, (index) => frames[index].hold ?? 2650, true);
}

function selectExample(selected) {
  examplePlayer.stop();
  mode = selected;
  const example = examples[mode];
  exampleStarted = false;
  exampleContent.dataset.mode = mode;
  exampleTitle.textContent = example.title;
  exampleDescription.textContent = example.description;
  exampleContext.textContent = example.context || "";
  renderExample(0, 0);
  updateExampleControl();
}

selectExample(mode);

const exampleObserver = new IntersectionObserver(([entry]) => {
  exampleVisible = entry.intersectionRatio >= .3;
  if (exampleVisible) playExample();
  else examplePlayer.stop();
}, { threshold: .3 });
exampleObserver.observe(examplePanel);

document.addEventListener("visibilitychange", () => {
  if (document.hidden) examplePlayer.stop();
  else playExample();
});

bindTabs(exampleTabs, examplePanel, (tab) => {
  if (tab.dataset.example === mode) return;
  selectExample(tab.dataset.example);
  artEntrance?.cancel();
  if (!reducedMotion.matches) {
    artEntrance = exampleArt.animate?.(
      [{ opacity: .5, transform: "translateY(4px) scale(.986)" }, { opacity: 1, transform: "none" }],
      { duration: 520, easing: motionEase },
    );
  }
  playExample();
});

runExample.addEventListener("click", () => {
  if (reducedMotion.matches) {
    const next = nextReducedFrame();
    renderExample(next === -1 ? 0 : next, currentCycle + (next === -1 ? 1 : 0));
    updateExampleControl();
  } else if (examplePlayer.running) {
    autoplay = false;
    examplePlayer.stop();
  } else {
    autoplay = true;
    playExample();
  }
});

reducedMotion.addEventListener("change", () => {
  artEntrance?.cancel();
  examplePlayer.stop();
  playExample();
});

const installMethods = document.getElementById("install-methods");
const installPanel = document.getElementById("install-panel");
const installFrame = document.getElementById("install-frame");
const installRun = document.getElementById("install-run");
const installGuides = {
  archive: document.getElementById("archive-guide"),
  codex: document.getElementById("codex-guide"),
  source: document.getElementById("source-guide"),
};
const installIntro = {
  archive: "Архив → Программы → Разрешения",
  codex: "Запрос → Установка → Разрешения",
  source: "Исходники → Сборка → Первый запуск",
};
let installMode = "archive";
let installStarted = false;

function installSteps() {
  return [...installGuides[installMode].querySelectorAll(".install-steps li")];
}

function renderInstall(index, animate = false) {
  const steps = installSteps();
  steps.forEach((step, position) => {
    if (position === index) step.setAttribute("aria-current", "step");
    else step.removeAttribute("aria-current");
  });
  installFrame.textContent = steps[index]?.dataset.cue || installIntro[installMode];
  if (animate) showFrame(installFrame);
}

const installPlayer = playback((index) => renderInstall(index, true), (playing) => {
  installRun.textContent = playing ? "Остановить" : installStarted ? "Повторить шаги" : "Показать шаги";
});

bindTabs(installMethods, installPanel, (tab) => {
  installMode = tab.dataset.method;
  installStarted = false;
  installPlayer.stop();
  for (const [mode, guide] of Object.entries(installGuides)) guide.hidden = mode !== installMode;
  renderInstall(-1);
});

installRun.addEventListener("click", () => {
  if (installPlayer.running) {
    installPlayer.stop();
    return;
  }
  installStarted = true;
  installPlayer.play(installSteps().length);
});

for (const button of document.querySelectorAll("[data-copy-target]")) {
  const contents = document.getElementById(button.dataset.copyTarget).querySelector("code");
  const feedback = document.getElementById(button.dataset.copyFeedback);
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(contents.textContent);
      feedback.textContent = button.dataset.copyTarget === "build-commands" ? "Команды скопированы." : "Скопировано.";
    } catch {
      const range = document.createRange();
      range.selectNodeContents(contents);
      window.getSelection().removeAllRanges();
      window.getSelection().addRange(range);
      feedback.textContent = "Текст выделен. Нажмите ⌘C, чтобы скопировать.";
    }
  });
}
