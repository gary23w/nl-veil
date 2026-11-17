import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./workspace.js', import.meta.url), 'utf8');

function workspace(finePointer) {
  return vm.runInNewContext(source + '\nVeilWorkspace;', {
    matchMedia: () => ({ matches: finePointer }),
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
  });
}

test('small upward scrolls keep the reader parked when streaming adds content', () => {
  class Transcript extends EventTarget {
    scrollHeight = 400;
    clientHeight = 100;
    #top = 0;
    get scrollTop() { return this.#top; }
    set scrollTop(value) { this.#top = Math.min(value, this.scrollHeight - this.clientHeight); }
    focus() {}
  }
  const transcript = new Transcript();
  const latest = new EventTarget();
  const follow = workspace(true).followTranscript(transcript, latest);
  follow.afterPaint();
  assert.equal(transcript.scrollTop, 300);
  assert.equal(latest.hidden, true);

  transcript.scrollTop -= 6;
  follow.beforePaint();
  transcript.scrollHeight += 100;
  follow.afterPaint();
  assert.equal(transcript.scrollTop, 294);
  assert.equal(latest.hidden, false);

  latest.dispatchEvent(new Event('click'));
  assert.equal(transcript.scrollTop, 400);
  assert.equal(latest.hidden, true);
  transcript.scrollHeight += 25;
  follow.afterPaint();
  assert.equal(transcript.scrollTop, 425);
  follow.dispose();
});

test('Enter preserves multiline, composition, and touch input', () => {
  const enter = { key: 'Enter' };
  const desktop = workspace(true);
  const touch = workspace(false);
  assert.equal(desktop.shouldSend(enter), true);
  assert.equal(desktop.shouldSend({ ...enter, shiftKey: true }), false);
  assert.equal(desktop.shouldSend({ ...enter, isComposing: true }), false);
  assert.equal(touch.shouldSend(enter), false);
  assert.equal(touch.shouldSend({ ...enter, ctrlKey: true }), true);
});
