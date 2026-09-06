(() => {
  const send = (message) => window.webkit.messageHandlers.xterm.postMessage(message);
  let terminal;
  let lastSize = '';

  function reportError(stage, error) {
    const message = error instanceof Error ? error.message : String(error);
    send({ type: 'error', stage, message });
  }

  function resize() {
    if (!terminal) return;
    const element = document.getElementById('terminal');
    const width = Math.max(element.clientWidth - 8, 1);
    const height = Math.max(element.clientHeight - 8, 1);
    const columns = Math.max(2, Math.floor(width / 8.4));
    const rows = Math.max(1, Math.floor(height / 17));
    const size = `${columns}x${rows}`;
    if (size === lastSize) return;
    lastSize = size;
    terminal.resize(columns, rows);
    send({ type: 'resize', columns, rows });
  }

  window.XTerminal = {
    writeBase64(value) {
      terminal.write(XTermBridge.decodeBase64(value));
    },
  };

  try {
    terminal = new Terminal({
      allowProposedApi: false,
      convertEol: false,
      cursorBlink: true,
      fontFamily: 'Menlo, ui-monospace, monospace',
      fontSize: 14,
      scrollback: 10_000,
      theme: { background: '#000000', foreground: '#f0f0f0' },
    });
    terminal.open(document.getElementById('terminal'));
    terminal.onData((data) => send({ type: 'input', base64: XTermBridge.encodeInput(data) }));
    new ResizeObserver(resize).observe(document.getElementById('terminal'));
    resize();
    send({ type: 'ready', columns: terminal.cols, rows: terminal.rows });
  } catch (error) {
    reportError('initialization', error);
  }
})();
