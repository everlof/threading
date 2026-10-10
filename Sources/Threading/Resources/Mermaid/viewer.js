/* Threading's offline, read-only diagram canvas. All controls and file authority are native. */
(() => {
  let scale = 1;
  let fitting = true;
  let width = 1;
  let height = 1;
  let inset = 0;
  let renderNumber = 0;
  let ticket = null;
  const faces = new Map();
  const canvas = document.getElementById('canvas');
  const diagram = document.getElementById('diagram');
  // Native keeps the latest viewport, so releasing this page while the pane is hidden loses nothing.
  // Sent as it happens: the engine already coalesces scroll events to one a frame, and a page in
  // an occluded window gets no animation frames to defer to.
  function reportViewport() {
    if (ticket === null) return;
    window.webkit?.messageHandlers?.threadingViewport?.postMessage({ ticket, fitting, scale, x: scrollX, y: scrollY });
  }
  function layout() {
    if (fitting) scale = Math.min(1, Math.max(0.1, (innerWidth - inset * 2) / width));
    const scaledWidth = width * scale;
    const scaledHeight = height * scale;
    diagram.style.width = `${scaledWidth}px`;
    diagram.style.height = `${scaledHeight}px`;
    const svg = diagram.querySelector('svg');
    if (svg) {
      svg.setAttribute('width', scaledWidth); svg.setAttribute('height', scaledHeight);
    }
    canvas.style.width = `${scaledWidth + inset * 2}px`;
    canvas.style.height = `${scaledHeight + inset * 2}px`;
    reportViewport();
  }
  // A process-registered theme face arrives as bytes; WebKit's content process cannot see it.
  async function adoptFace(face) {
    if (!face || faces.get(face.family)?.key === face.key) return;
    const binary = atob(face.data);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    const font = new FontFace(face.family, bytes);
    await font.load();
    const previous = faces.get(face.family);
    if (previous) document.fonts.delete(previous.font);
    document.fonts.add(font);
    faces.set(face.family, { key: face.key, font });
  }
  window.threadingZoom = (operation) => {
    fitting = operation === 'fit';
    if (!fitting) scale = Math.max(0.1, Math.min(4, scale * (operation === 'in' ? 1.25 : 0.8)));
    layout();
  };
  window.addEventListener('resize', layout);
  window.addEventListener('scroll', reportViewport, { passive: true });
  document.addEventListener('contextmenu', (event) => event.preventDefault());
  // `viewport` is 'fit' for a new document, 'preserve' for a repaint of the same reader, or the
  // { fitting, scale, x, y } native saved before it released the previous page.
  window.threadingRender = async (source, palette, limits, viewport, renderTicket) => {
    const started = performance.now();
    const scroll = [scrollX, scrollY];
    // An unreadable face falls back to the system family that follows it in `palette.font`.
    try { await adoptFace(palette.fontFace); } catch {}
    inset = palette.inset;
    canvas.style.padding = `${inset}px`;
    document.body.style.background = palette.ground;
    diagram.setAttribute('aria-label', palette.title);
    mermaid.initialize({
      startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
      maxTextSize: limits.bytes, maxEdges: limits.edges,
      // Neither front matter nor init directives may relax safety/work limits or replace host ink.
      // Mermaid applies this list at every depth, so the per-diagram font keys are locked too.
      secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges',
        'suppressErrorRendering', 'dompurifyConfig', 'theme', 'themeVariables', 'themeCSS',
        'fontFamily', 'fontSize', 'htmlLabels', 'flowchart',
        'actorFontFamily', 'boundaryFontFamily', 'componentFontFamily', 'containerFontFamily',
        'dbFontFamily', 'messageFontFamily', 'noteFontFamily', 'personFontFamily', 'queueFontFamily',
        'systemFontFamily', 'taskFontFamily', 'titleFontFamily', 'usecaseFontFamily'],
      theme: 'base', fontFamily: palette.font, fontSize: palette.fontSize, htmlLabels: true,
      themeVariables: {
        darkMode: palette.dark, fontSize: `${palette.fontSize}px`, background: palette.ground, primaryColor: palette.face,
        primaryTextColor: palette.ink, primaryBorderColor: palette.border,
        secondaryColor: palette.face, secondaryTextColor: palette.ink,
        tertiaryColor: palette.ground, tertiaryTextColor: palette.ink,
        lineColor: palette.ink, textColor: palette.ink, mainBkg: palette.face,
        nodeBorder: palette.border, clusterBkg: palette.ground, clusterBorder: palette.border,
        titleColor: palette.ink, edgeLabelBackground: palette.ground,
        actorBkg: palette.face, actorBorder: palette.border, actorTextColor: palette.ink,
        signalColor: palette.ink, signalTextColor: palette.ink, labelTextColor: palette.ink,
        labelBoxBkgColor: palette.face, labelBoxBorderColor: palette.border
      },
      flowchart: { useMaxWidth: false, htmlLabels: true },
      deterministicIds: true, deterministicIDSeed: 'threading-preview'
    });
    // Mermaid removes a prior SVG with the requested id before rendering. Keep the visible
    // diagram intact until its replacement is complete, including during live theme changes.
    const result = await mermaid.render(`threading-diagram-${++renderNumber}`, source);
    diagram.innerHTML = result.svg;
    // A preview never binds Mermaid click callbacks or navigates source-authored links.
    for (const link of diagram.querySelectorAll('a')) {
      link.removeAttribute('href'); link.removeAttribute('xlink:href');
      link.removeAttribute('tabindex');
    }
    const svg = diagram.querySelector('svg');
    const box = svg.viewBox.baseVal;
    width = Math.max(1, box.width); height = Math.max(1, box.height);
    svg.setAttribute('width', width); svg.setAttribute('height', height);
    svg.style.maxWidth = 'none';
    if (viewport === 'fit') {
      fitting = true;
    } else if (viewport && typeof viewport === 'object') {
      fitting = viewport.fitting;
      scale = Math.max(0.1, Math.min(4, viewport.scale));
    }
    ticket = renderTicket;
    layout();
    if (viewport === 'preserve') scrollTo(...scroll);
    else if (viewport && typeof viewport === 'object') scrollTo(viewport.x, viewport.y);
    reportViewport();
    return { width, height, nodes: diagram.querySelectorAll('.node').length, renderMilliseconds: performance.now() - started };
  };
})();
