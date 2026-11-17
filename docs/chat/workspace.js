'use strict';

// The browser chat controls are shared by the embedded app and the public chat.
const VeilWorkspace = (() => {
  const starters = [
    ['Explore my project', 'See how it fits together', 'Help me understand this project. Explain the main parts and suggest one useful place to start.'],
    ['Build something small', 'Plan a first feature', 'I want to build a small feature. Help me clarify the idea and break it into a few achievable steps.'],
    ['Find an improvement', 'Review one practical change', 'Review this project for one practical improvement. Explain why it matters before making changes.'],
  ];

  const mark = '<span class="workspace-mark" aria-hidden="true"></span>';
  const attachIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21.4 11.05l-9.2 9.2a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.9-2.9l8.5-8.5"/></svg>';

  function welcome(onPrompt) {
    const node = document.createElement('section');
    node.className = 'workspace-welcome';
    node.innerHTML = `
      <div class="workspace-emblem">${mark}</div>
      <h1>What would you like to make?</h1>
      <p>Start with an idea, a question, or one thing you want to improve.</p>
      <div class="workspace-starters">
        ${starters.map(([title, description]) => `
          <button type="button" class="workspace-starter">
            <strong>${title}</strong>
            <span>${description}</span>
            <i aria-hidden="true"></i>
          </button>`).join('')}
      </div>`;
    node.querySelectorAll('button').forEach((button, index) => {
      button.addEventListener('click', () => onPrompt(starters[index][2]));
    });
    return node;
  }

  function insertPrompt(input, prompt) {
    const text = input.value.trimEnd();
    if (!text.endsWith(prompt)) {
      input.setRangeText((text.trim() ? '\n\n' : '') + prompt, text.length, input.value.length, 'end');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }
    input.focus({ preventScroll: true });
  }

  function growPrompt(input) {
    input.style.height = 'auto';
    input.style.height = input.scrollHeight + 'px';
  }

  function shouldSend(event) {
    return event.key === 'Enter' && !event.shiftKey && !event.isComposing && event.keyCode !== 229
      && (event.ctrlKey || event.metaKey || matchMedia('(pointer: fine)').matches);
  }

  // Latch on upward movement. A distance check alone snaps small touch/trackpad
  // gestures back to the tail before the reader can accumulate any distance.
  function followTranscript(transcript, latest) {
    let pinned = true;
    let lastTop = 0;
    const empty = () => transcript.firstElementChild?.classList.contains('workspace-welcome');
    const beforePaint = () => {
      if (!transcript.clientHeight || empty()) return;
      const top = transcript.scrollTop;
      const atEnd = transcript.scrollHeight - top - transcript.clientHeight <= 4;
      if (atEnd && top >= lastTop) pinned = true;
      else if (top < lastTop - 1) pinned = false;
      lastTop = top;
      latest.hidden = pinned || atEnd;
    };
    const afterPaint = () => {
      if (!transcript.clientHeight) return;
      if (empty()) {
        latest.hidden = true;
        return;
      }
      if (pinned) transcript.scrollTop = transcript.scrollHeight;
      lastTop = transcript.scrollTop;
      latest.hidden = pinned || transcript.scrollHeight - lastTop - transcript.clientHeight <= 4;
    };
    const jump = () => {
      pinned = true;
      afterPaint();
    };
    transcript.addEventListener('scroll', beforePaint, { passive: true });
    latest.addEventListener('click', () => {
      jump();
      transcript.focus({ preventScroll: true });
    });
    const resize = new ResizeObserver(afterPaint);
    resize.observe(transcript);
    return { beforePaint, afterPaint, jump, dispose: () => resize.disconnect() };
  }

  return { mark, attachIcon, welcome, insertPrompt, growPrompt, shouldSend, followTranscript };
})();
