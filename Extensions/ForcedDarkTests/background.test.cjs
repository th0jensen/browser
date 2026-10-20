const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const extension = path.join(__dirname,'..','ForcedDark');

test('background publishes initial and changed appearance to Browser', async () => {
  const messages = [];
  let changed;
  const context = vm.createContext({
    browser: {
      runtime: {sendNativeMessage: async (...args) => { messages.push(args); }},
      storage: {
        local: {get: async () => ({forcedDark:{enabled:true,background:'#17211c'}})},
        onChanged: {addListener: listener => { changed = listener; }}
      }
    }
  });
  context.importScripts = filename => vm.runInContext(fs.readFileSync(path.join(extension,filename),'utf8'),context);
  vm.runInContext(fs.readFileSync(path.join(extension,'background.js'),'utf8'),context);
  await new Promise(resolve => setImmediate(resolve));

  assert.deepEqual(JSON.parse(JSON.stringify(messages[0])),['dev.athas.browser.forced-dark',
    {type:'appearance',enabled:true,background:'#17211c'}]);
  changed({forcedDark:{newValue:{enabled:false,background:'#211c19'}}},'local');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(JSON.parse(JSON.stringify(messages[1])),['dev.athas.browser.forced-dark',
    {type:'appearance',enabled:false,background:'#211c19'}]);
});
