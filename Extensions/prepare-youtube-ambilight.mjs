import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const source = process.argv[2];
if (!source) throw new Error('Usage: node prepare-youtube-ambilight.mjs UPSTREAM_FOLDER');
const manifestPath = resolve(source, 'src/manifest.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

// WebKit applies YouTube's CSP to DOM-inserted script tags and dynamic imports.
// Let the extension engine inject the helper into the page world, and load the
// renderer and CSS declaratively in the isolated extension world.
const scripts = [];
for (const entry of manifest.content_scripts) {
  if (!entry.js?.includes('scripts/content.js')) {
    scripts.push(entry);
    continue;
  }
  scripts.push({
    ...entry,
    js: ['scripts/injected.js'],
    world: 'MAIN',
  });
  scripts.push({
    ...entry,
    js: ['scripts/content.js', 'scripts/content-main.js'],
    css: ['styles/content.css'],
    world: 'ISOLATED',
  });
}
manifest.content_scripts = scripts;
manifest.version = '2.38.17.2';
delete manifest.minimum_chrome_version;
delete manifest.browser_specific_settings;
// These files no longer need to be exposed to page script fetches.
for (const entry of manifest.web_accessible_resources) {
  entry.resources = entry.resources.filter(resource => ![
    'scripts/content-main.js', 'scripts/injected.js', 'styles/content.css',
  ].includes(resource));
}
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
// manifest-copy.js replaces its version placeholder with package.json's version.
const packagePath = resolve(source, 'package.json');
const packageJSON = JSON.parse(readFileSync(packagePath, 'utf8'));
packageJSON.version = manifest.version;
writeFileSync(packagePath, JSON.stringify(packageJSON, null, 2) + '\n');

copyFileSync(fileURLToPath(new URL('./compatibility/canvas-blur.js', import.meta.url)),
  resolve(source, 'src/scripts/libs/canvas-blur.js'));
const projectorPath = resolve(source, 'src/scripts/libs/projector-webgl.js');
let projector = readFileSync(projectorPath, 'utf8');
const replaceOnce = (before, after) => {
  if (projector.split(before).length !== 2) throw new Error('Upstream projector changed: ' + before);
  projector = projector.replace(before, after);
};
replaceOnce("import ProjectorShadow from './projector-shadow';",
  "import ProjectorShadow from './projector-shadow';\nimport CanvasBlur from './canvas-blur';");
replaceOnce('  remove() {', '  remove() {\n    this.blurFallback?.dispose();');
replaceOnce("    this.projectors[0] = {", `    if (!('filter' in this.blurCtx) && !this.blurFallback) {
      this.blurFallback = new CanvasBlur();
    }
    this.projectors[0] = {`);
replaceOnce('      this.blurCtx.filter = `blur(${blurPx / this.blurCanvasScale}px)`;',
  '      this.blurSigma = blurPx / this.blurCanvasScale;\n      this.blurCtx.filter = `blur(${this.blurSigma}px)`;');
replaceOnce('    if (this.settings.showResolutions)\n      this.blurDrawTime = performance.now() - start;',
  `    this.blurFallback?.apply(this.blurCanvas, this.blurCtx, this.blurSigma);
    if (this.settings.showResolutions)
      this.blurDrawTime = performance.now() - start;`);
writeFileSync(projectorPath, projector);

writeFileSync(resolve(source, 'src/scripts/content.js'), `import { getVersion } from './libs/utils';
import { setErrorHandler, wrapErrorHandler } from './libs/generic';
import { defaultCrashOptions, storage } from './libs/storage';
import SentryReporter, { setCrashOptions, setVersion } from './libs/errors/sentry-reporter';
import { injectedScript } from './libs/messaging/injected';

setErrorHandler((ex) => SentryReporter.captureException(ex));

injectedScript.addMessageListener('error', (injectedEx) => {
  const ex = new Error(injectedEx.message);
  ex.name = injectedEx.name;
  ex.stack = injectedEx.stack;
  if (injectedEx.details) ex.details = injectedEx.details;
  SentryReporter.captureException(ex);
});

// Styles, the page helper, and the renderer are injected by the manifest.
wrapErrorHandler(async function loadContentScript() {
  setVersion(getVersion());
  try {
    setCrashOptions((await storage.get('crashOptions')) || defaultCrashOptions);
  } catch (ex) {
    SentryReporter.captureException(ex);
  }
  storage.addListener(function storageListener(changes) {
    if (changes.crashOptions?.newValue) setCrashOptions(changes.crashOptions.newValue);
  });
})();
`);
