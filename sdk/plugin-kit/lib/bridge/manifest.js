// package.json "dshGo" manifest (docs/design/native-plugins-protocol.md §1): a locale-free parse
// cached per package.json, then a per-request render (locale, versions, live registrations).
import { readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { parseCapabilities, RESOURCE_KINDS } from "./capabilities.js";
import { validate as validateEffect } from "./effects.js";
import { ICON, ID, LIMITS, PLACEMENTS, PROTOCOL, SEMVER, SURFACES, WANTS } from "./limits.js";
import { chars, compareSemver, isPlainObject, parseText, resolveText, toJson, truncateChars, viewStats } from "./util.js";

const TOP_KEYS = new Set(["v", "minApp", "title", "icon", "wants", "assets", "contributes", "capabilities"]);
const ITEM_KEYS = {
  "composer.actions": new Set(["id", "label", "icon", "effect", "requires"]),
  "message.actions": new Set(["id", "label", "icon", "effect", "requires"]),
  "composer.strip": new Set(["id", "icon", "text", "panel"]),
  panels: new Set(["id", "title", "icon", "placement", "view", "micro"]),
};
const LABEL_LIMIT = { "composer.actions": LIMITS.textChars.composerAction, "message.actions": LIMITS.textChars.messageAction };

const issue = (path, code, severity, message) => ({ path, code, severity, message });
const ptr = (...parts) => `/dshGo${parts.map((p) => `/${String(p).replaceAll("~", "~0").replaceAll("/", "~1")}`).join("")}`;

/** Resolves a manifest-relative path inside the package directory, or undefined. */
export function insidePackage(pkgDir, rel) {
  if (typeof rel !== "string" || rel === "" || isAbsolute(rel) || rel.includes("\\") || rel.includes("\0")) return undefined;
  const full = resolve(pkgDir, rel);
  const r = relative(pkgDir, full);
  if (r === "" || r.startsWith("..") || isAbsolute(r)) return undefined;
  try {
    const realDir = realpathSync(pkgDir);
    const real = realpathSync(full);
    if (real !== realDir && !real.startsWith(realDir + sep)) return undefined;
  } catch {
    return full;   // not there yet: the caller stats it
  }
  return full;
}

/** Locale-free parse of `pkgJson.dshGo`. Never throws. */
export function parseManifest(pkgJson, pkgDir) {
  const issues = [];
  const out = {
    pkg: pkgJson.name,
    version: typeof pkgJson.version === "string" ? pkgJson.version : "0.0.0",
    valid: false,
    v: undefined,
    minApp: undefined,
    title: undefined,
    icon: undefined,
    wants: [],
    assetsDir: undefined,
    items: { "composer.actions": [], "message.actions": [], "composer.strip": [], panels: [] },
    ids: new Map(),
    issues,
  };
  const m = pkgJson.dshGo;
  const json = toJson(m);
  if (!isPlainObject(m) || json === undefined) {
    issues.push(issue("/dshGo", "invalid-manifest", "error", "dshGo must be an object"));
    return out;
  }
  if (json.bytes > LIMITS.manifestBytes) {
    issues.push(issue("/dshGo", "invalid-manifest", "error", `dshGo exceeds ${LIMITS.manifestBytes} bytes`));
    return out;
  }
  for (const k of Object.keys(m)) if (!TOP_KEYS.has(k)) issues.push(issue(ptr(k), "unknown-field", "warn", `unknown key ${k}`));

  if (!Number.isInteger(m.v) || m.v < 1) {
    issues.push(issue(ptr("v"), m.v === undefined ? "missing-field" : "invalid-field", "error", "v must be a positive integer (1)"));
    return out;
  }
  out.v = m.v;
  if (m.minApp !== undefined) {
    if (typeof m.minApp === "string" && SEMVER.test(m.minApp)) out.minApp = m.minApp;
    else issues.push(issue(ptr("minApp"), "invalid-field", "error", "minApp must be x.y.z"));
  }
  if (m.title !== undefined) {
    out.title = parseText(m.title);
    if (out.title === undefined) issues.push(issue(ptr("title"), "invalid-field", "error", "title must be a non-empty string or locale map"));
  }
  if (m.icon !== undefined) {
    if (typeof m.icon === "string" && ICON.test(m.icon)) out.icon = m.icon;
    else issues.push(issue(ptr("icon"), "invalid-field", "error", "icon must match ^[a-z][a-z0-9-]{0,31}$"));
  }
  if (m.wants !== undefined) {
    if (!Array.isArray(m.wants)) issues.push(issue(ptr("wants"), "invalid-field", "error", "wants must be an array"));
    else m.wants.forEach((w, i) => {
      if (WANTS.includes(w)) { if (!out.wants.includes(w)) out.wants.push(w); }
      else issues.push(issue(ptr("wants", i), "invalid-field", "error", `unknown want ${String(w).slice(0, 40)}`));
    });
  }
  if (m.assets !== undefined) {
    const dir = insidePackage(pkgDir, m.assets);
    let ok = false;
    try { ok = dir !== undefined && statSync(dir).isDirectory(); } catch {}
    if (ok) out.assetsDir = dir;
    else issues.push(issue(ptr("assets"), "invalid-field", "error", "assets must be a directory inside the package"));
  }
  if (!isPlainObject(m.contributes)) {
    issues.push(issue(ptr("contributes"), m.contributes === undefined ? "missing-field" : "invalid-field", "error", "contributes must be an object"));
    return out;
  }
  out.valid = true;
  if (out.v !== PROTOCOL) return out;   // rendered as unsupported; nothing else to read

  // Panel ids first: strips and effects may point at them.
  const panelIds = new Set();
  if (Array.isArray(m.contributes.panels)) {
    for (const p of m.contributes.panels) if (isPlainObject(p) && typeof p.id === "string" && ID.test(p.id)) panelIds.add(p.id);
  }

  for (const surface of Object.keys(m.contributes)) {
    if (RESOURCE_KINDS.includes(surface)) continue;   // v1.2: parseCapabilities
    const list = m.contributes[surface];
    if (!SURFACES.includes(surface)) {
      issues.push(issue(ptr("contributes", surface), "unknown-surface", "warn", `unknown surface ${surface}; ignored`));
      continue;
    }
    if (!Array.isArray(list)) {
      issues.push(issue(ptr("contributes", surface), "invalid-field", "error", `${surface} must be an array`));
      continue;
    }
    const cap = LIMITS.perPlugin[surface];
    list.forEach((raw, i) => {
      const at = (...p) => ptr("contributes", surface, i, ...p);
      if (!isPlainObject(raw)) { issues.push(issue(at(), "invalid-field", "error", "entry must be an object")); return; }
      for (const k of Object.keys(raw)) if (!ITEM_KEYS[surface].has(k)) issues.push(issue(at(k), "unknown-field", "warn", `unknown key ${k}`));
      if (typeof raw.id !== "string" || !ID.test(raw.id)) {
        issues.push(issue(at("id"), raw.id === undefined ? "missing-field" : "invalid-field", "error", "id must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$"));
        return;
      }
      if (out.ids.has(raw.id)) { issues.push(issue(at("id"), "duplicate-id", "error", `id ${raw.id} is already used by ${out.ids.get(raw.id)}`)); return; }
      if (out.items[surface].length >= cap) {
        if (out.items[surface].length === cap) issues.push(issue(at(), "too-many", "warn", `${surface} allows ${cap} per plugin; the rest are ignored`));
        out.items[surface].push(null);   // placeholder so only the first overflow is reported
        return;
      }
      const item = { id: raw.id };
      if (raw.icon !== undefined) {
        if (typeof raw.icon === "string" && ICON.test(raw.icon)) item.icon = raw.icon;
        else issues.push(issue(at("icon"), "invalid-field", "error", "icon must match ^[a-z][a-z0-9-]{0,31}$"));
      }
      if (surface === "composer.actions" || surface === "message.actions") {
        item.label = parseText(raw.label);
        if (item.label === undefined) { issues.push(issue(at("label"), raw.label === undefined ? "missing-field" : "invalid-field", "error", "label must be a non-empty string or locale map")); return; }
        if (raw.effect !== undefined) {
          const list = Array.isArray(raw.effect) ? raw.effect : [raw.effect];
          const effects = [];
          let ok = list.length >= 1 && list.length <= LIMITS.effectsPerInvoke;
          if (ok) list.forEach((e, j) => {
            const r = validateEffect(e, { panels: panelIds, static: true });
            if (r.effect) effects.push(r.effect);
            if (r.issue && r.issue.code !== "too-long") { ok = false; issues.push(issue(at("effect", ...(Array.isArray(raw.effect) ? [j] : [])), "invalid-field", "error", r.issue.message)); }
          });
          else issues.push(issue(at("effect"), "invalid-field", "error", `effect must be one effect or 1-${LIMITS.effectsPerInvoke} effects`));
          if (ok) item.effect = effects;
        }
      } else if (surface === "composer.strip") {
        if (raw.text !== undefined) {
          item.text = parseText(raw.text);
          if (item.text === undefined) issues.push(issue(at("text"), "invalid-field", "error", "text must be a non-empty string or locale map"));
        }
        if (raw.panel !== undefined) {
          if (typeof raw.panel === "string" && panelIds.has(raw.panel)) item.panel = raw.panel;
          else issues.push(issue(at("panel"), "invalid-field", "error", "panel must be one of this plugin's panel ids"));
        }
      } else {
        item.title = parseText(raw.title);
        if (item.title === undefined) { issues.push(issue(at("title"), raw.title === undefined ? "missing-field" : "invalid-field", "error", "title must be a non-empty string or locale map")); return; }
        item.placement = [];
        if (raw.placement === undefined) item.placement.push("session.tab");
        else if (!Array.isArray(raw.placement)) issues.push(issue(at("placement"), "invalid-field", "error", "placement must be an array"));
        else raw.placement.forEach((p, j) => {
          if (PLACEMENTS.includes(p)) { if (!item.placement.includes(p)) item.placement.push(p); }
          else issues.push(issue(at("placement", j), "invalid-field", "error", `unknown placement ${String(p).slice(0, 40)}`));
        });
        if (item.placement.length === 0) item.placement.push("session.tab");
        if (raw.view !== undefined) {
          const file = insidePackage(pkgDir, raw.view);
          let st;
          try { st = file === undefined ? undefined : statSync(file); } catch {}
          if (st === undefined || !st.isFile() || !file.endsWith(".json")) issues.push(issue(at("view"), "view-file", "error", "view must be a .json file inside the package"));
          else if (st.size > LIMITS.viewBytes) issues.push(issue(at("view"), "view-file", "error", `view file exceeds ${LIMITS.viewBytes} bytes`));
          else item.viewFile = file;
        }
      }
      out.ids.set(raw.id, surface);
      out.items[surface].push(item);
    });
    out.items[surface] = out.items[surface].filter((x) => x !== null);
  }
  parseCapabilities(m, out);
  return out;
}

/**
 * Plugin row of the contributions response. `caps`: { versions: number[], app, locale };
 * `live`: { panels: Map id->{data:boolean}, strips: Set, handlers: Set, degraded: boolean,
 * runtimeIssues: issue[] }.
 */
export function renderPlugin(parsed, caps, live) {
  const issues = [...parsed.issues];
  const text = (t, max, path) => {
    const s = resolveText(t, caps.locale);
    if (s === undefined) return undefined;
    if (chars(s) <= max) return s;
    issues.push(issue(path, "too-long", "warn", `exceeds ${max} characters for locale ${caps.locale || "default"}; truncated`));
    return truncateChars(s, max);
  };
  let state = "ok";
  if (!parsed.valid) state = "invalid";
  else if (parsed.v !== PROTOCOL || !caps.versions.includes(parsed.v)) {
    state = "unsupported";
    issues.push(issue(ptr("v"), "unsupported-version", "error", `protocol v${parsed.v} is not supported (app speaks ${caps.versions.join(",")})`));
  } else if (parsed.minApp !== undefined && compareSemver(caps.app, parsed.minApp) < 0) {
    state = "needs-app";
    issues.push(issue(ptr("minApp"), "needs-app", "error", `needs app ${parsed.minApp} (have ${caps.app})`));
  } else if (live.degraded) {
    state = "degraded";
  }
  const row = {
    pkg: parsed.pkg,
    version: parsed.version,
    title: text(parsed.title, LIMITS.textChars.pluginTitle, ptr("title")) ?? truncateChars(parsed.pkg, LIMITS.textChars.pluginTitle),
    ...(parsed.icon === undefined ? {} : { icon: parsed.icon }),
    wants: parsed.wants,
    state,
    native: state === "ok",
    contributes: { "composer.actions": [], "message.actions": [], "composer.strip": [], panels: [] },
    issues,
  };
  if (state === "ok") {
    for (const surface of ["composer.actions", "message.actions"]) {
      parsed.items[surface].forEach((it, i) => {
        const handled = it.effect !== undefined || live.handlers.has(it.id);
        const supported = (it.requires ?? []).every((x) => (caps.features ?? []).includes(x));
        const ready = handled && supported;
        if (!handled) issues.push(issue(ptr("contributes", surface, i), "no-handler", "warn", `${it.id} has no effect and no on("${it.id}") handler`));
        row.contributes[surface].push({
          id: it.id,
          ...(it.requires === undefined ? {} : { requires: it.requires }),
          label: text(it.label, LABEL_LIMIT[surface], ptr("contributes", surface, i, "label")),
          ...(it.icon === undefined ? {} : { icon: it.icon }),
          ...(it.effect === undefined ? {} : { effect: it.effect }),
          ready,
        });
      });
    }
    parsed.items["composer.strip"].forEach((it, i) => {
      const liveStrip = live.strips.has(it.id);
      const tappable = it.panel !== undefined || live.handlers.has(it.id);
      const ready = liveStrip || tappable || it.text !== undefined;
      if (!ready) issues.push(issue(ptr("contributes", "composer.strip", i), "no-handler", "warn", `${it.id} has no text, panel, strip("${it.id}") or on("${it.id}")`));
      row.contributes["composer.strip"].push({
        id: it.id,
        ...(it.icon === undefined ? {} : { icon: it.icon }),
        text: it.text === undefined ? null : text(it.text, LIMITS.textChars.stripText, ptr("contributes", "composer.strip", i, "text")),
        ...(it.panel === undefined ? {} : { panel: it.panel }),
        tappable,
        live: liveStrip,
        ready,
      });
    });
    parsed.items.panels.forEach((it, i) => {
      const reg = live.panels.get(it.id);
      const ready = reg !== undefined || it.viewFile !== undefined;
      if (!ready) issues.push(issue(ptr("contributes", "panels", i), "no-handler", "warn", `${it.id} has no view file and no panel("${it.id}") registration`));
      row.contributes.panels.push({
        id: it.id,
        title: text(it.title, LIMITS.textChars.panelTitle, ptr("contributes", "panels", i, "title")),
        ...(it.icon === undefined ? {} : { icon: it.icon }),
        placement: it.placement,
        ...(it.micro === undefined ? {} : { micro: it.micro }),
        ready,
        live: reg?.data === true,
      });
    });
  }
  // v1.2 (only for plugins that declare capabilities): kept even when this app negotiated none.
  if (parsed.capabilities !== undefined) {
    row.capabilities = [...parsed.capabilities];
    for (const kind of RESOURCE_KINDS) if (parsed.items[kind] !== undefined) row.contributes[kind] = state === "ok" ? parsed.items[kind].map((x) => ({ ...x })) : [];
  }
  issues.push(...live.runtimeIssues);
  return row;
}

/** Resolved display title of a panel for one locale. */
export function panelTitle(item, locale) {
  const s = resolveText(item.title, locale) ?? item.id;
  return chars(s) <= LIMITS.textChars.panelTitle ? s : truncateChars(s, LIMITS.textChars.panelTitle);
}


/**
 * Pure entry for the SDK check and test hosts (no DSH): what the bridge would publish for one
 * package.json. Static view files are read and checked like GET /views does.
 * opts: { locale = "zh", app = "999.0.0", versions = [1],
 *         handlers = "assume" (every contribution counts as registered) | iterable of on() ids,
 *         panels / strips / dataPanels = iterables of panel() / strip() / panel-with-data ids }.
 * Returns { state, plugin, issues } (plugin = the contributions row; issues as in §3.3), or
 * { state: "absent", plugin: null, issues: [] } when package.json has no dshGo.
 */
export function checkManifest(pkgJson, pkgDir, opts = {}) {
  if (!isPlainObject(pkgJson) || pkgJson.dshGo === undefined) return { state: "absent", plugin: null, issues: [] };
  const parsed = parseManifest(pkgJson, pkgDir);
  const caps = { versions: opts.versions ?? [PROTOCOL], app: opts.app ?? "999.0.0", locale: opts.locale ?? "zh" };
  const assume = opts.handlers === undefined || opts.handlers === "assume";
  const all = (surfaces) => surfaces.flatMap((k) => parsed.items[k].map((it) => it.id));
  const dataPanels = new Set(opts.dataPanels ?? []);
  const panelIds = assume ? all(["panels"]) : [...(opts.panels ?? [])];
  const live = {
    panels: new Map(panelIds.map((id) => [id, { data: dataPanels.has(id) }])),
    strips: new Set(assume ? all(["composer.strip"]) : (opts.strips ?? [])),
    handlers: new Set(assume ? all(["composer.actions", "message.actions", "composer.strip", "panels"]) : opts.handlers),
    degraded: false,
    runtimeIssues: [],
  };
  const plugin = renderPlugin(parsed, caps, live);
  const issues = [...plugin.issues];
  parsed.items.panels.forEach((it) => {
    if (it.viewFile === undefined) return;
    const at = `/dshGo/contributes/panels/${parsed.items.panels.indexOf(it)}/view`;
    let view;
    try {
      view = JSON.parse(readFileSync(it.viewFile, "utf8"));
    } catch {
      issues.push(issue(at, "view-file", "error", "view file is not JSON"));
      return;
    }
    const json = isPlainObject(view) ? toJson(view) : undefined;
    if (json === undefined) { issues.push(issue(at, "view-file", "error", "view file must hold a JSON object")); return; }
    if (json.bytes > LIMITS.viewBytes) { issues.push(issue(at, "view-file", "error", `view exceeds ${LIMITS.viewBytes} bytes`)); return; }
    const st = viewStats(view);
    if (st.nodes > LIMITS.viewNodes || st.depth > LIMITS.viewDepth) issues.push(issue(at, "too-many", "warn", `view has ${st.nodes} nodes / depth ${st.depth} (max ${LIMITS.viewNodes} / ${LIMITS.viewDepth}); the app truncates`));
  });
  return { state: plugin.state, plugin, issues };
}
