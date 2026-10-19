(() => {
  "use strict";
  const reveal = () => document.documentElement?.setAttribute("data-browser-forced-dark-ready", "");
  // A failed page pass must never leave content hidden by the loading sheet.
  setTimeout(reveal,1500);
  if (document.contentType.startsWith("image/")) { reveal(); return; }
  const C = globalThis.ForcedDarkColors;
  const api = globalThis.browser ?? globalThis.chrome;
  const attribute = "data-browser-forced-dark";
  const skip = new Set(["SCRIPT","STYLE","LINK","META","HEAD","TITLE","IMG","PICTURE","VIDEO","CANVAS","IFRAME","OBJECT","EMBED"]);
  let preferences = C.defaults;
  let timer;
  let nextID = 0;
  const ids = new WeakMap();
  const roots = new Map();
  const observer = new MutationObserver(schedule);
  const colorPattern = /(?:rgba?|color|lab|lch|oklab|oklch|hsl|hsla)\([^)]*\)/g;
  function createSheet(root) {
    // Constructed sheets use CSSOM, so a site's style-src CSP cannot block the
    // extension by rejecting an inline <style> text node.
    const sheet = new CSSStyleSheet();
    root.adoptedStyleSheets = [...root.adoptedStyleSheets,sheet];
    roots.set(root,sheet);
    return sheet;
  }
  function observe() {
    for (const root of roots.keys()) observer.observe(root, {subtree:true,childList:true,attributes:true,characterData:true});
  }
  function schedule() {
    if (timer !== undefined) return;
    timer = requestAnimationFrame(() => { timer = undefined; render(); });
  }
  function rule(element, declarations, pseudo = "") {
    if (!declarations.length) return "";
    let id = ids.get(element);
    if (id === undefined) { id = ++nextID; ids.set(element,id); }
    if (element.getAttribute(attribute) !== String(id)) element.setAttribute(attribute,id);
    return `[${attribute}="${id}"]${pseudo}{${declarations.join(";")}}`;
  }
  const declaration = (property,color) => `${property}:${C.css(color)}!important`;
  function splitList(value) {
    let depth = 0, start = 0;
    const values = [];
    for (let i = 0; i < value.length; i++) {
      if (value[i] === "(") depth++;
      if (value[i] === ")") depth--;
      if (value[i] === "," && depth === 0) { values.push(value.slice(start,i).trim()); start = i+1; }
    }
    values.push(value.slice(start).trim());
    return values;
  }
  function transitions(style) {
    const properties = splitList(style.transitionProperty);
    if (properties.length === 1 && properties[0] === "none") return null;
    const duration = splitList(style.transitionDuration), delay = splitList(style.transitionDelay), easing = splitList(style.transitionTimingFunction);
    const motion = "opacity transform translate scale rotate filter backdrop-filter box-shadow text-shadow clip-path width height min-width min-height max-width max-height margin padding inset border-width border-radius flex-grow flex-shrink flex-basis gap grid-template-columns grid-template-rows background-position background-size left right top bottom font-size font-weight line-height letter-spacing word-spacing visibility".split(" ");
    return properties.flatMap((property,i) => {
      const keep = property === "all" ? motion : /color|^(background|border|outline|fill|stroke|caret)$/i.test(property) ? [] : [property];
      return keep.map(name => `${name} ${duration[i%duration.length]} ${easing[i%easing.length]} ${delay[i%delay.length]}`);
    }).join(",") || "none";
  }
  function properties(style, backdrop, imageBackdrop = false) {
    const result = [];
    // An authored color transition would animate through the original bright
    // color each time our sheet is temporarily disabled for measurement.
    // Keep motion/geometry transitions, but publish color changes atomically.
    const transition = transitions(style);
    if (transition) result.push(`transition:${transition}!important`);
    const bg = C.parse(style.backgroundColor);
    const darkBG = C.background(bg,C.parse(preferences.background));
    if (bg && bg[3] > 0) result.push(declaration("background-color",darkBG));
    const effective = darkBG ? C.composite(darkBG,backdrop) : backdrop;
    for (const property of ["color","-webkit-text-fill-color","text-decoration-color","caret-color","fill","stroke"]) {
      const color = C.parse(style.getPropertyValue(property));
      if (color) result.push(declaration(property,imageBackdrop ? color : C.foreground(color,effective)));
    }
    for (const edge of ["top","right","bottom","left"]) {
      const color = C.parse(style.getPropertyValue(`border-${edge}-color`));
      if (color && style.getPropertyValue(`border-${edge}-style`) !== "none") {
        result.push(declaration(`border-${edge}-color`,C.background(color,C.parse(preferences.background))));
      }
    }
    const outline = C.parse(style.outlineColor);
    if (outline && style.outlineStyle !== "none") result.push(declaration("outline-color",C.foreground(outline,effective)));
    const gradient = style.backgroundImage;
    if (gradient.includes("gradient(") && !gradient.includes("url(")) {
      result.push(`background-image:${gradient.replace(colorPattern,text => C.css(C.background(C.parse(text),C.parse(preferences.background))))}!important`);
    }
    return {declarations:result,backdrop:effective};
  }
  function render() {
    if (!document.documentElement) return;
    observer.disconnect();
    for (const [root,style] of roots) {
      if (root !== document && !root.host.isConnected) { roots.delete(root); }
      else style.disabled = true;
    }
    // Removing the loading guard and publishing the finished colors happen in
    // the same task; the browser cannot paint the authored white page between.
    reveal();
    if (!preferences.enabled) { observe(); return; }
    if (!roots.has(document)) createSheet(document);
    const surface = C.parse(preferences.background);
    const rootStyle = getComputedStyle(document.documentElement);
    const bodyStyle = document.body && getComputedStyle(document.body);
    const base = [bodyStyle?.backgroundColor,rootStyle.backgroundColor].map(C.parse).find(color => color && color[3] >= 0.95);
    const canvas = base ? C.background(base,surface) : surface;
    const scrollbar = `*{scrollbar-color:#747474 ${preferences.background}!important}*::-webkit-scrollbar-track{background-color:${preferences.background}!important}*::-webkit-scrollbar-thumb{background-color:#747474!important;border-color:${preferences.background}!important}`;
    const output = new Map([[document,[`html{background-color:${C.css(canvas)}!important;color-scheme:dark!important}`,scrollbar]]]);
    const backdrops = new WeakMap();
    const imageBackdrops = new WeakMap();
    function walk(root, inherited) {
      const rules = output.get(root) ?? [scrollbar];
      output.set(root,rules);
      for (const element of root.querySelectorAll("*")) {
        if (skip.has(element.tagName)) continue;
        const parent = element.parentElement;
        const backdrop = backdrops.get(parent) ?? inherited;
        const style = getComputedStyle(element);
        const bg = C.parse(style.backgroundColor);
        const coveringImage = style.backgroundImage.includes("url(") && /cover|100%/.test(style.backgroundSize);
        const hasImage = coveringImage || ((bg?.[3] ?? 0) < 0.95 && imageBackdrops.get(parent));
        const values = properties(style,backdrop,hasImage);
        backdrops.set(element,values.backdrop);
        imageBackdrops.set(element,hasImage);
        rules.push(rule(element,values.declarations));
        for (const pseudo of ["::before","::after","::marker","::placeholder"]) {
          if (pseudo === "::placeholder" && !["INPUT","TEXTAREA"].includes(element.tagName)) continue;
          if (pseudo === "::marker" && style.display !== "list-item") continue;
          const pseudoStyle = getComputedStyle(element,pseudo);
          if (["::before","::after"].includes(pseudo) && ["none","normal",""].includes(pseudoStyle.content)) continue;
          rules.push(rule(element,properties(pseudoStyle,values.backdrop,hasImage).declarations,pseudo));
        }
        if (element.shadowRoot) {
          if (!roots.has(element.shadowRoot)) createSheet(element.shadowRoot);
          walk(element.shadowRoot,values.backdrop);
        }
      }
    }
    try {
      walk(document,canvas);
      for (const [root,rules] of output) {
        const style = roots.get(root);
        if (!root.adoptedStyleSheets.includes(style)) root.adoptedStyleSheets = [...root.adoptedStyleSheets,style];
        style.replaceSync(rules.join("\n"));
        style.disabled = false;
      }
    } finally { observe(); }
  }
  api.storage.local.get("forcedDark").then(value => {
    preferences = C.settings(value.forcedDark);
    schedule();
  }).catch(schedule);
  api.storage.onChanged.addListener((changes,area) => {
    if (area !== "local" || !changes.forcedDark) return;
    preferences = C.settings(changes.forcedDark.newValue);
    schedule();
  });
  // Stylesheets, media queries, form states and viewport changes can alter
  // computed colors without changing an element's style attribute.
  document.addEventListener("load",schedule,true);
  document.addEventListener("DOMContentLoaded",schedule,{once:true});
  for (const event of ["change","input","pointerup","focusin","focusout","transitionend"]) document.addEventListener(event,schedule,true);
  // Recompute hover colors when crossing an interactive control, rather than
  // rescanning for every child span/icon crossed while moving the pointer.
  const control = node => node instanceof Element ? node.closest("a,button,input,select,textarea,summary,[role=button],[tabindex]") : null;
  document.addEventListener("pointerover",event => {
    const next = control(event.target), previous = control(event.relatedTarget);
    if (next !== previous && (next || previous)) schedule();
  },true);
  document.addEventListener("pointerout",event => { if (!event.relatedTarget && control(event.target)) schedule(); },true);
  window.addEventListener("resize",schedule);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change",schedule);
  observer.observe(document,{subtree:true,childList:true,attributes:true});
  schedule();
})();
