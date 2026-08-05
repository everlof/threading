import Foundation

// MARK: - Style

extension CompareExportPage {

    /// The exported page's stylesheet.
    ///
    /// Written to be read on someone else's machine, so it commits to nothing the app knows:
    /// system fonts, both colour schemes through `prefers-color-scheme`, and a layout that holds
    /// down to a phone. The comparison's own rules — one shared scale, captions in bands beside
    /// the pixels, the accent-inked seam that *is* the control — are the surface's, restated in
    /// the one language a browser has.
    enum Style {
        static let sheet = """
            :root {
              color-scheme: light dark;
              --ground: #ffffff;
              --surface: #f5f5f7;
              --border: #d9d9de;
              --text: #17171a;
              --muted: #6c6c74;
              --accent: #2f6df6;
              --check-a: #ffffff;
              --check-b: #e8e8ec;
              --added-ink: #1a7f37;
              --removed-ink: #cf222e;
              --added-fill: rgba(26, 127, 55, 0.14);
              --removed-fill: rgba(207, 34, 46, 0.14);
              --radius: 10px;
              --gap: 16px;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --ground: #131316;
                --surface: #1d1d21;
                --border: #34343b;
                --text: #ececf0;
                --muted: #9a9aa4;
                --accent: #6f9bff;
                --check-a: #2a2a30;
                --check-b: #232329;
                --added-ink: #56d364;
                --removed-ink: #ff7b72;
                --added-fill: rgba(86, 211, 100, 0.14);
                --removed-fill: rgba(255, 123, 114, 0.14);
              }
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 32px clamp(16px, 5vw, 48px) 48px;
              background: var(--ground);
              color: var(--text);
              font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
              -webkit-text-size-adjust: 100%;
            }
            .head h1 {
              margin: 0 0 4px;
              font-size: 20px;
              font-weight: 600;
              line-height: 1.3;
              overflow-wrap: anywhere;
            }
            .head h1 .arrow { color: var(--muted); }
            .meta, .hint, .foot { margin: 0; color: var(--muted); font-size: 12px; }
            .foot { margin-top: 32px; }
            .note { margin: 32px 0; color: var(--muted); }

            /* Modes — the chip's five answers, as a row of one-tap choices. */
            .modes { display: flex; flex-wrap: wrap; gap: 6px; margin: 24px 0 4px; }
            .mode {
              appearance: none;
              border: 1px solid var(--border);
              border-radius: 999px;
              background: var(--surface);
              color: var(--text);
              padding: 5px 12px;
              font: inherit;
              font-size: 12px;
              cursor: pointer;
            }
            .mode:hover { border-color: var(--muted); }
            .mode[aria-pressed="true"] {
              background: var(--accent);
              border-color: var(--accent);
              color: #ffffff;
            }

            /* Captions sit in bands outside the images, never over them: printed on the
               picture they hide the pixels the comparison exists to show. */
            .stage { --fraction: 0.5; }
            .captions {
              display: flex;
              gap: 8px;
              margin: 10px 0;
              min-height: 1.2em;
              color: var(--muted);
              font-size: 12px;
            }
            .captions span {
              flex: 1 1 0;
              min-width: 0;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .captions .join { display: none; flex: 0 0 auto; }
            .captions.top .old { text-align: left; }
            .captions.top .new { text-align: right; color: var(--text); }
            .captions.bottom { display: none; }

            .canvas { position: relative; isolation: isolate; display: flex; gap: var(--gap); }
            .frame {
              position: relative;
              flex: 1 1 0;
              min-width: 0;
              aspect-ratio: var(--union-width) / var(--union-height);
              border: 1px solid var(--border);
              border-radius: var(--radius);
              overflow: hidden;
              background-color: var(--check-a);
              background-image:
                linear-gradient(45deg, var(--check-b) 25%, transparent 25%),
                linear-gradient(-45deg, var(--check-b) 25%, transparent 25%),
                linear-gradient(45deg, transparent 75%, var(--check-b) 75%),
                linear-gradient(-45deg, transparent 75%, var(--check-b) 75%);
              background-size: 16px 16px;
              background-position: 0 0, 0 8px, 8px -8px, -8px 0;
            }
            .frame img {
              position: absolute;
              left: 50%;
              top: 50%;
              transform: translate(-50%, -50%);
              width: var(--image-width);
              height: var(--image-height);
            }

            /* Every mode but side by side stacks the new side exactly on the old one. */
            html:not([data-mode="sideBySide"]) .canvas:not(.single) { display: block; }
            html:not([data-mode="sideBySide"]) .canvas:not(.single) .frame.new {
              position: absolute;
              inset: 0;
            }

            html[data-mode="wipeHorizontal"] .canvas { cursor: ew-resize; }
            html[data-mode="wipeHorizontal"] .frame.new {
              clip-path: inset(0 0 0 calc(var(--fraction) * 100%));
            }
            html[data-mode="wipeVertical"] .canvas { cursor: ns-resize; }
            html[data-mode="wipeVertical"] .frame.new {
              clip-path: inset(calc(var(--fraction) * 100%) 0 0 0);
            }
            html[data-mode="wipeVertical"] .captions.top .new { display: none; }
            html[data-mode="wipeVertical"] .captions.top .old { text-align: center; }
            html[data-mode="wipeVertical"] .captions.bottom { display: flex; }
            html[data-mode="wipeVertical"] .captions.bottom .old { display: none; }
            html[data-mode="wipeVertical"] .captions.bottom .new { text-align: center; }

            /* Fade is the onion skin held at the middle, so the overlay carries no ground of
               its own — a checkerboard at half opacity would tint the crossfade. */
            html[data-mode="fade"] .canvas { cursor: ew-resize; }
            html[data-mode="fade"] .canvas:not(.single) .frame.new {
              background: none;
              opacity: var(--fraction);
            }

            /* Difference answers "did anything change at all": identical pixels cancel to no
               ink, which only reads against black. */
            html[data-mode="difference"] .frame {
              background-image: none;
              background-color: #000000;
            }
            html[data-mode="difference"] .canvas:not(.single) .frame.new { background: none; }
            html[data-mode="difference"] .frame.new img { mix-blend-mode: difference; }
            html[data-mode="difference"] .captions.top { justify-content: center; }
            html[data-mode="difference"] .captions.top span { flex: 0 0 auto; }
            html[data-mode="difference"] .captions.top .join { display: inline; }

            html[data-mode="sideBySide"] .captions.top .old,
            html[data-mode="sideBySide"] .captions.top .new { text-align: center; }

            /* The two static modes have no position to scrub. The seam already hides there
               rather than sitting dead; the line telling the reader to drag it has to go with
               it, or the page offers a gesture nothing responds to. */
            html[data-mode="difference"] .hint,
            html[data-mode="sideBySide"] .hint { display: none; }

            /* The seam is the control, which is why it takes the accent. */
            .seam { display: none; position: absolute; pointer-events: none; }
            .seam .handle {
              position: absolute;
              left: 50%;
              top: 50%;
              width: 24px;
              height: 24px;
              margin: 0;
              border-radius: 50%;
              background: var(--accent);
              transform: translate(-50%, -50%);
              box-shadow: 0 1px 4px rgba(0, 0, 0, 0.35);
            }
            html[data-mode="wipeHorizontal"] .seam {
              display: block;
              top: 0;
              bottom: 0;
              left: calc(var(--fraction) * 100%);
              width: 2px;
              margin-left: -1px;
              background: var(--accent);
            }
            html[data-mode="wipeVertical"] .seam {
              display: block;
              left: 0;
              right: 0;
              top: calc(var(--fraction) * 100%);
              height: 2px;
              margin-top: -1px;
              background: var(--accent);
            }

            /* Text comparisons: the same unified hunks the app draws. */
            .diff { margin-top: 24px; }
            .file {
              margin-bottom: 16px;
              border: 1px solid var(--border);
              border-radius: var(--radius);
              overflow: hidden;
            }
            .file-head {
              display: flex;
              justify-content: space-between;
              gap: 12px;
              padding: 8px 12px;
              background: var(--surface);
              border-bottom: 1px solid var(--border);
              font-size: 12px;
            }
            .file-head .path { font-weight: 600; overflow-wrap: anywhere; }
            .file-head .plus { color: var(--added-ink); }
            .file-head .minus { color: var(--removed-ink); }
            .hunk + .hunk { border-top: 1px solid var(--border); }
            .hunk-head {
              padding: 6px 12px;
              background: var(--surface);
              color: var(--muted);
              font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
              overflow-wrap: anywhere;
            }
            .diff table {
              width: 100%;
              border-collapse: collapse;
              font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            .diff td { padding: 0 6px; vertical-align: top; }
            .diff .num {
              width: 1%;
              text-align: right;
              white-space: nowrap;
              color: var(--muted);
              user-select: none;
              -webkit-user-select: none;
            }
            .diff .sign {
              width: 1%;
              text-align: center;
              color: var(--muted);
              user-select: none;
              -webkit-user-select: none;
            }
            .diff .code { white-space: pre-wrap; overflow-wrap: anywhere; }
            .diff tr.added { background: var(--added-fill); }
            .diff tr.added .sign { color: var(--added-ink); }
            .diff tr.removed { background: var(--removed-fill); }
            .diff tr.removed .sign { color: var(--removed-ink); }
            .truncated { margin: 0; padding: 6px 12px; color: var(--muted); font-size: 12px; }

            @media (max-width: 520px) {
              html[data-mode="sideBySide"] .canvas { flex-direction: column; }
            }
            """
    }

    // MARK: - Script

    /// The page's behaviour: the mode buttons, the scrub, and the keys.
    ///
    /// Deliberately one closure of plain ES5-era JavaScript — no build step, no framework, and
    /// nothing that needs a module loader — because the file has to run from a `file://` URL in
    /// whatever browser the recipient happens to have.
    enum Script {
        static let source = """
            (function () {
              var root = document.documentElement;
              var stage = document.querySelector('.stage');
              var canvas = stage ? stage.querySelector('.canvas') : null;
              var buttons = Array.prototype.slice.call(document.querySelectorAll('.mode'));
              // The two static modes have no position to scrub, so the seam and the keys go
              // quiet there rather than moving something invisible.
              var scrubbable = { wipeHorizontal: true, wipeVertical: true, fade: true };
              var fraction = 0.5;

              function clamp(value) { return Math.min(1, Math.max(0, value)); }

              function apply() {
                if (stage) { stage.style.setProperty('--fraction', fraction); }
              }

              function mode() { return root.getAttribute('data-mode'); }

              function setMode(next) {
                root.setAttribute('data-mode', next);
                buttons.forEach(function (button) {
                  button.setAttribute(
                    'aria-pressed', String(button.getAttribute('data-mode') === next)
                  );
                });
              }

              buttons.forEach(function (button) {
                button.addEventListener('click', function () {
                  setMode(button.getAttribute('data-mode'));
                });
              });

              function scrub(event) {
                if (!canvas || !scrubbable[mode()]) { return; }
                var rect = canvas.getBoundingClientRect();
                if (!rect.width || !rect.height) { return; }
                fraction = mode() === 'wipeVertical'
                  ? clamp((event.clientY - rect.top) / rect.height)
                  : clamp((event.clientX - rect.left) / rect.width);
                apply();
              }

              if (canvas) {
                canvas.addEventListener('pointerdown', function (event) {
                  if (!scrubbable[mode()]) { return; }
                  if (canvas.setPointerCapture) { canvas.setPointerCapture(event.pointerId); }
                  scrub(event);
                  event.preventDefault();
                });
                canvas.addEventListener('pointermove', function (event) {
                  if (event.buttons === 0) { return; }
                  scrub(event);
                });
              }

              document.addEventListener('keydown', function (event) {
                if (!scrubbable[mode()]) { return; }
                var step = event.shiftKey ? 0.1 : 0.02;
                if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
                  fraction = clamp(fraction - step);
                } else if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
                  fraction = clamp(fraction + step);
                } else if (event.key === ' ') {
                  fraction = 0.5;
                } else {
                  return;
                }
                event.preventDefault();
                apply();
              });

              apply();
            })();
            """
    }
}
