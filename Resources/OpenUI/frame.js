(() => {
  'use strict';
  const PROTOCOL = 2;
  const MAX_SOURCE_BYTES = 262144;
  const MAX_STATE_BYTES = 16384;
  const api = window.__OpenUI;
  const status = document.getElementById('status');
  const source = document.getElementById('source');
  const rootNode = document.getElementById('root');
  const native = window.webkit?.messageHandlers?.openui;
  const encoder = new TextEncoder();
  let current = null, gesture = null, lastAction = -Infinity, lastHeight = 0, heightFrame = 0, recovery = 0, failed = false;
  let stateTimer = 0, emptyTimer = 0, pendingState = null, lastState = '', generation = 0;
  const emit = message => {
    const envelope = { ...message, protocol: PROTOCOL };
    if (native) native.postMessage(envelope);
    else if (window.parent !== window) window.parent.postMessage({ ...envelope, channel: 'dsh-openui' }, '*');
  };
  const requestHeight = () => {
    if (heightFrame) return;
    heightFrame = requestAnimationFrame(() => {
      heightFrame = 0;
      // Measure content, not body.scrollHeight (which can equal the old viewport
      // and prevent shrink-to-fit). A small inset absorbs fractional font metrics.
      const bottom = Math.max(rootNode.getBoundingClientRect().bottom,
        rootNode.offsetTop + rootNode.scrollHeight, status.getBoundingClientRect().bottom,
        source.hidden ? 0 : source.getBoundingClientRect().bottom);
      if (bottom > 11997 && !failed) { failure('answer-too-tall'); return; }
      const height = Math.min(12000, Math.max(44, Math.ceil(bottom) + 3));
      if (Number.isFinite(height) && height !== lastHeight) { lastHeight = height; emit({ type: 'height', height }); }
    });
  };
  const sizeObserver = new ResizeObserver(requestHeight);
  for (const element of [rootNode, status, source]) sizeObserver.observe(element);
  document.fonts?.ready.then(requestHeight);
  const safeState = state => {
    if (!state || typeof state !== 'object' || Array.isArray(state)) return null;
    try {
      let count = 0; const seen = new Set();
      const check = (value, depth) => {
        if (depth > 8 || ++count > 2048) return false;
        if (value === null || typeof value === 'string' || typeof value === 'boolean') return true;
        if (typeof value === 'number') return Number.isFinite(value);
        if (typeof value !== 'object' || seen.has(value)) return false;
        seen.add(value); const okay = Object.values(value).every(child => check(child, depth + 1)); seen.delete(value); return okay;
      };
      if (!check(state, 0)) return null;
      const encoded = JSON.stringify(state);
      return encoder.encode(encoded).length <= MAX_STATE_BYTES ? JSON.parse(encoded) : null;
    } catch (error) { return null; }
  };
  const flushState = () => {
    clearTimeout(stateTimer);
    if (failed || !pendingState) return;
    const encoded = JSON.stringify(pendingState);
    if (encoded !== lastState) { lastState = encoded; emit({ type: 'state', state: pendingState }); }
    pendingState = null;
  };
  const stateUpdate = state => {
    if (failed || current?.isStreaming) return;
    const safe = safeState(state); if (!safe) return;
    pendingState = safe;
    clearTimeout(stateTimer); stateTimer = setTimeout(flushState, 150);
  };
  window.addEventListener('pagehide', flushState);
  document.addEventListener('visibilitychange', () => { if (document.hidden) flushState(); });
  window.dshOpenUIFlushState = flushState;
  const rememberGesture = event => { if (event.isTrusted && !current?.isStreaming) gesture = performance.now(); };
  document.addEventListener('click', event => { rememberGesture(event); if (event.target.closest?.('a')) event.preventDefault(); }, true);
  document.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') rememberGesture(event); }, true);
  document.addEventListener('submit', event => event.preventDefault(), true);
  const failure = reason => {
    failed = true; gesture = null; clearTimeout(stateTimer); clearTimeout(emptyTimer); pendingState = null;
    status.textContent = current?.labels?.error || 'This interactive answer could not be displayed.';
    source.hidden = false; source.open = true;
    emit({ type: 'error', message: reason }); requestHeight();
  };
  if (!api?.React || !api?.createRoot || !api?.Renderer || !api?.openuiChatLibrary) { failure('runtime-unavailable'); return; }
  class Boundary extends api.React.Component {
    constructor(props) { super(props); this.state = { failed: false }; }
    static getDerivedStateFromError() { return { failed: true }; }
    componentDidCatch() { failure('render-failed'); }
    render() { return this.state.failed ? null : this.props.children; }
  }
  const root = api.createRoot(rootNode);
  const action = event => {
    const now = performance.now();
    if (failed || current?.isStreaming || gesture === null || now - gesture > 1500 || now - lastAction < 1000) return;
    gesture = null;
    if (event?.type === 'CopyToClipboard') {
      const text = event.params?.text;
      if (typeof text === 'string' && encoder.encode(text).length <= MAX_STATE_BYTES) { lastAction = now; emit({ type: 'copy', text }); }
      return;
    }
    if (event?.type !== 'continue_conversation') return;
    try {
      const encoded = JSON.stringify(event);
      if (encoder.encode(encoded).length <= MAX_STATE_BYTES) { lastAction = now; emit({ type: 'action', event: JSON.parse(encoded) }); }
    } catch (error) { /* Invalid events never leave the sandbox. */ }
  };
  const onError = errors => {
    if (!errors?.length || current?.isStreaming) return;
    const fatal = errors.some(error => error.severity !== 'warning' && (
      ['parse-failed', 'parse-exception', 'no-root'].includes(error.code)
      || (['unknown-component', 'missing-required', 'null-required'].includes(error.code) && error.statementId === 'root')
      || (error.code === 'runtime-error' && !error.statementId && !error.component)));
    if (fatal) failure('render-failed');
    else if (errors.some(error => ['runtime-error', 'render-error', 'unknown-function'].includes(error.code))) {
      status.textContent = current?.labels?.warning || 'Some values could not be calculated. Check the inputs.';
      requestHeight();
    }
  };
  const applyTheme = value => {
    document.documentElement.classList.toggle('dark', value.dark === true);
    document.documentElement.dataset.theme = value.dark === true ? 'dark' : 'light';
    document.documentElement.style.colorScheme = value.dark === true ? 'dark' : 'light';
    const map = { ink: ['--iui-ink'], muted: ['--iui-muted', '--iui-faint'], background: ['--iui-canvas'], surface: ['--iui-surface'], border: ['--iui-border', '--iui-border-strong'], accent: ['--iui-accent'], fontFamily: ['--iui-font'], fontSize: ['--iui-font-size'] };
    for (const [key, names] of Object.entries(map)) {
      const token = value.theme?.[key];
      for (const name of names) { if (typeof token === 'string' && token.length && token.length <= 256) document.documentElement.style.setProperty(name, token); else document.documentElement.style.removeProperty(name); }
    }
  };
  window.dshOpenUIUpdate = value => {
    if (!value || typeof value.response !== 'string' || encoder.encode(value.response).length > MAX_SOURCE_BYTES) { failure('source-invalid'); return; }
    const catalog = value.catalog || 'chat-v1';
    const library = catalog === 'chat-v1' ? api.openuiChatLibrary : catalog === 'intelligent-v1' ? api.intelligentLibrary : null;
    if (!library) { failure('catalog-unavailable'); return; }
    if (!current || current.response !== value.response || current.catalog !== catalog) {
      generation++; recovery++; clearTimeout(stateTimer); pendingState = null; lastState = '';
    }
    if (failed) { recovery++; failed = false; }
    const renderGeneration = generation;
    current = { response: value.response, catalog, isStreaming: value.isStreaming === true, labels: value.labels };
    gesture = null; clearTimeout(emptyTimer); applyTheme(value);
    rootNode.classList.toggle('iui-root', catalog === 'intelligent-v1');
    source.hidden = true;
    source.querySelector('summary').textContent = value.labels?.source || 'Answer source';
    source.querySelector('pre').textContent = value.response;
    status.textContent = current.isStreaming ? (value.labels?.loading || 'Preparing…') : '';
    try {
      root.render(api.React.createElement(Boundary, { key: recovery }, api.React.createElement(api.Renderer, {
        response: current.response, library, isStreaming: current.isStreaming, publishObservability: false,
        initialState: safeState(value.initialState) || {},
        onStateUpdate: state => { if (renderGeneration === generation) stateUpdate(state); },
        onAction: event => { if (renderGeneration === generation) action(event); },
        onError: errors => { if (renderGeneration === generation) onError(errors); },
      })));
      if (!current.isStreaming) emptyTimer = setTimeout(() => { if (!failed && !rootNode.childElementCount) failure('empty-answer'); }, 2000);
    } catch (error) { failure('render-failed'); }
    requestHeight();
  };
  window.addEventListener('message', event => {
    if (!native && event.source === window.parent && event.data?.channel === 'dsh-openui' && event.data.protocol === PROTOCOL && event.data.type === 'update') window.dshOpenUIUpdate(event.data.value);
  });
  emit({ type: 'ready' }); requestHeight();
})();
