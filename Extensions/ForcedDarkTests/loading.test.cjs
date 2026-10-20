const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const extension = path.join(__dirname,'..','ForcedDark');

test('loading canvas follows the configured Forced Dark background', async () => {
  const property = '--browser-forced-dark-background';
  const calls = [];
  let loadingTimeout;
  let storageChanged;
  const root = {
    style: {
      setProperty: (...args) => calls.push(['set',...args]),
      removeProperty: name => calls.push(['remove',name])
    },
    setAttribute: () => {},
    getAttribute: () => null
  };
  const context = vm.createContext({
    console,
    document: {
      contentType: 'text/html',
      documentElement: root,
      addEventListener: () => {}
    },
    browser: {
      storage: {
        local: {get: async () => ({forcedDark:{enabled:true,background:'#17211c'}})},
        onChanged: {addListener: listener => { storageChanged = listener; }}
      }
    },
    MutationObserver: class { observe() {} disconnect() {} },
    Element: class {},
    requestAnimationFrame: () => 1,
    cancelAnimationFrame: () => {},
    setTimeout: (callback,delay) => { if (delay === 1500) loadingTimeout = callback; return 1; },
    clearTimeout: () => {},
    window: {addEventListener: () => {}},
    matchMedia: () => ({addEventListener: () => {}})
  });
  vm.runInContext(fs.readFileSync(path.join(extension,'colors.js'),'utf8'),context);
  vm.runInContext(fs.readFileSync(path.join(extension,'content.js'),'utf8'),context);
  await new Promise(resolve => setImmediate(resolve));

  assert.deepEqual(calls.at(-1),['set',property,'#17211c','important']);
  storageChanged({forcedDark:{newValue:{enabled:true,background:'#211c19'}}},'local');
  assert.deepEqual(calls.at(-1),['set',property,'#211c19','important']);
  loadingTimeout();
  assert.deepEqual(calls.at(-1),['remove',property]);

  const css = fs.readFileSync(path.join(extension,'loading.css'),'utf8');
  assert.match(css,/background-color: var\(--browser-forced-dark-background, #121212\) !important/);
});
