const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const extension = path.join(__dirname,'..','ForcedDark');

test('dynamic pages debounce subtree additions without rescanning on interaction churn', async () => {
  let mutationCallback;
  const observations = [];
  const documentListeners = new Map();
  const windowListeners = new Map();
  const timers = new Map();
  const clock = {now:0};
  let nextTimer = 0;
  let animationFrames = 0;
  class FakeDate extends Date { static now() { return clock.now; } }
  const root = {
    style: {setProperty: () => {}, removeProperty: () => {}},
    setAttribute: () => {},
    getAttribute: () => null
  };
  const document = {
    contentType: 'text/html',
    documentElement: root,
    addEventListener: (name,listener,options) => documentListeners.set(name,{listener,options})
  };
  const context = vm.createContext({
    console,
    Date: FakeDate,
    document,
    browser: {
      storage: {
        local: {get: async () => ({forcedDark:{enabled:false,background:'#121212'}})},
        onChanged: {addListener: () => {}}
      }
    },
    MutationObserver: class {
      constructor(callback) { mutationCallback = callback; }
      observe(target,options) { observations.push({target,options}); }
      disconnect() {}
    },
    Element: class {},
    requestAnimationFrame: () => { animationFrames++; return 1; },
    cancelAnimationFrame: () => {},
    setTimeout: (callback,delay) => {
      const id = ++nextTimer;
      timers.set(id,{callback,delay});
      return id;
    },
    clearTimeout: id => timers.delete(id),
    window: {addEventListener: (name,listener,options) => windowListeners.set(name,{listener,options})},
    matchMedia: () => ({addEventListener: () => {}})
  });
  vm.runInContext(fs.readFileSync(path.join(extension,'colors.js'),'utf8'),context);
  vm.runInContext(fs.readFileSync(path.join(extension,'content.js'),'utf8'),context);
  await new Promise(resolve => setImmediate(resolve));

  assert.deepEqual(JSON.parse(JSON.stringify(observations[0].options)),{subtree:true,childList:true});
  assert.equal(documentListeners.has('pointerover'),false);
  assert.equal(documentListeners.has('pointerout'),false);
  assert.equal(documentListeners.has('input'),false);
  assert.equal(documentListeners.has('transitionend'),false);
  assert.equal(documentListeners.has('load'),false);
  assert.equal(windowListeners.has('load'),true);
  assert.equal(animationFrames,0);

  const scheduled = () => [...timers.entries()].find(([,timer]) => timer.delay !== 1500);
  const initial = scheduled();
  assert.equal(initial[1].delay,0,'initial appearance must render without debounce delay');
  initial[1].callback();
  assert.equal(scheduled(),undefined);

  mutationCallback([{addedNodes:[]}]);
  mutationCallback([{addedNodes:[{nodeType:3}]}]);
  assert.equal(scheduled(),undefined);

  mutationCallback([{addedNodes:[{nodeType:1}]}]);
  assert.equal(scheduled()[1].delay,120);
  for (const now of [100,200,300,400,500,600]) {
    clock.now = now;
    mutationCallback([{addedNodes:[{nodeType:1}]}]);
    assert.equal(scheduled()[1].delay,120);
  }
  clock.now = 700;
  mutationCallback([{addedNodes:[{nodeType:1}]}]);
  assert.equal(scheduled()[1].delay,50,'continuous additions must render by the 750 ms deadline');
  assert.equal(animationFrames,0);
});
