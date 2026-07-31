// Threading Remote — the single-page browser client.
//
// The capability arrives in the fragment, so it is absent from request URLs and proxy logs.
// It is moved into tab-scoped storage and removed from the visible URL immediately: reloads
// still work, without leaving an interactive credential in browser history or the address bar.
// Terminal sessions carry raw PTY bytes; native sessions carry provider-neutral conversation
// snapshots. Dormant sessions are resumed explicitly before their socket is opened.

(function () {
  "use strict";

  var translations = {
    en: {
      "app.title": "Threading Remote",
      "nav.back": "Back to sessions",
      "status.connecting": "Connecting…",
      "composer.placeholder": "Add feedback…",
      "composer.message": "Message",
      "composer.send": "Send",
      "link.missingToken": "This link is missing its access token.",
      "invitation.accepting": "Accepting private invitation…",
      "invitation.invalid": "This invitation is invalid, expired, or has already been accepted.",
      "invitation.failed": "Could not accept this invitation.",
      "invitation.unreadable": "The Mac returned an unreadable membership.",
      "mac.retry": "Could not reach the Mac. Tap to retry.",
      "mac.retrying": "Could not reach the Mac. Retrying…",
      "update.host": "Threading on the Mac is out of date — update it to connect.",
      "update.page": "This page is out of date. Tap to reload.",
      "link.invalid": "This link is not valid, or has expired.",
      "device.waitingApproval": "Waiting for approval on the Mac…",
      "device.denied": "This device was denied access.",
      "sessions.empty": "No sessions yet. Start Claude Code or Codex on the Mac.",
      "sessions.connectedSecurely": "Connected securely",
      "sessions.heading": "Sessions",
      "sessions.otherProject": "Other",
      "session.defaultName": "Session",
      "session.disconnected": "Disconnected",
      "session.working": "Working",
      "session.needsAttention": "Needs attention",
      "session.connected": "Connected",
      "session.resuming": "Resuming this session on the Mac…",
      "session.resumeFailed": "The session could not be resumed.",
      "session.resumeTimedOut": "The Mac did not finish resuming this session.",
      "session.socketDisconnected": "Disconnected from the Mac.",
      "session.endedOnMac": "The session ended on the Mac.",
      "terminal.disconnected": "— disconnected —",
      "terminal.ended": "— session ended —",
      "badge.connecting": "Connecting…",
      "badge.disconnected": "Disconnected",
      "badge.ended": "Ended",
      "badge.interactive": "Interactive",
      "badge.viewOnly": "View only",
      "error.viewOnly": "This link is view only.",
      "error.inputTooLarge": "That input is too large to send in one action.",
      "error.remoteAction": "The remote action failed.",
      "conversation.tool": "Tool",
      "conversation.working": "Working…",
      "conversation.reasoning": "Reasoning",
      "code.defaultLanguage": "code",
      "code.copy": "Copy",
      "code.copied": "Copied",
      "code.selectToCopy": "Select to copy",
      "permission.title": "Allow {tool}?",
      "permission.tool": "tool",
      "permission.reviewOnMac": "Review this request on the Mac.",
      "permission.deny": "Deny",
      "permission.allow": "Allow",
      "diagnostics.share": "Share diagnostics for 30 min",
      "diagnostics.stop": "Stop diagnostics sharing",
      "diagnostics.sharingUntil": "Sharing until {time}",
      "diagnostics.failed": "The Mac could not accept diagnostics.",
      "diagnostics.privacy": "Connection events only — never messages, terminal output, paths, or credentials.",
      "guest.browser": "browser",
      "guest.defaultName": "Browser guest",
      "app.code": "Code",
      "host.defaultName": "Threading Mac",
      "age.now": "now"
    },
    sv: {
      "app.title": "Threading Fjärråtkomst",
      "nav.back": "Tillbaka till sessioner",
      "status.connecting": "Ansluter…",
      "composer.placeholder": "Lägg till feedback…",
      "composer.message": "Meddelande",
      "composer.send": "Skicka",
      "link.missingToken": "Länken saknar sin åtkomsttoken.",
      "invitation.accepting": "Godkänner privat inbjudan…",
      "invitation.invalid": "Inbjudan är ogiltig, har gått ut eller har redan godkänts.",
      "invitation.failed": "Det gick inte att godkänna inbjudan.",
      "invitation.unreadable": "Mac-datorn returnerade ett oläsbart medlemskap.",
      "mac.retry": "Det gick inte att nå Mac-datorn. Tryck för att försöka igen.",
      "mac.retrying": "Det gick inte att nå Mac-datorn. Försöker igen…",
      "update.host": "Threading på Mac-datorn är inaktuell — uppdatera appen för att ansluta.",
      "update.page": "Sidan är inaktuell. Tryck för att läsa in den igen.",
      "link.invalid": "Länken är ogiltig eller har gått ut.",
      "device.waitingApproval": "Väntar på godkännande på Mac-datorn…",
      "device.denied": "Den här enheten nekades åtkomst.",
      "sessions.empty": "Inga sessioner ännu. Starta Claude Code eller Codex på Mac-datorn.",
      "sessions.connectedSecurely": "Säkert ansluten",
      "sessions.heading": "Sessioner",
      "sessions.otherProject": "Övrigt",
      "session.defaultName": "Session",
      "session.disconnected": "Frånkopplad",
      "session.working": "Arbetar",
      "session.needsAttention": "Kräver uppmärksamhet",
      "session.connected": "Ansluten",
      "session.resuming": "Återupptar sessionen på Mac-datorn…",
      "session.resumeFailed": "Det gick inte att återuppta sessionen.",
      "session.resumeTimedOut": "Mac-datorn slutförde inte återupptagningen av sessionen.",
      "session.socketDisconnected": "Anslutningen till Mac-datorn bröts.",
      "session.endedOnMac": "Sessionen avslutades på Mac-datorn.",
      "terminal.disconnected": "— frånkopplad —",
      "terminal.ended": "— sessionen avslutades —",
      "badge.connecting": "Ansluter…",
      "badge.disconnected": "Frånkopplad",
      "badge.ended": "Avslutad",
      "badge.interactive": "Interaktiv",
      "badge.viewOnly": "Endast visning",
      "error.viewOnly": "Länken ger endast visningsåtkomst.",
      "error.inputTooLarge": "Indatan är för stor för att skickas i en åtgärd.",
      "error.remoteAction": "Fjärråtgärden misslyckades.",
      "conversation.tool": "Verktyg",
      "conversation.working": "Arbetar…",
      "conversation.reasoning": "Resonemang",
      "code.defaultLanguage": "kod",
      "code.copy": "Kopiera",
      "code.copied": "Kopierat",
      "code.selectToCopy": "Markera för att kopiera",
      "permission.title": "Tillåt {tool}?",
      "permission.tool": "verktyget",
      "permission.reviewOnMac": "Granska begäran på Mac-datorn.",
      "permission.deny": "Neka",
      "permission.allow": "Tillåt",
      "diagnostics.share": "Dela diagnostik i 30 min",
      "diagnostics.stop": "Sluta dela diagnostik",
      "diagnostics.sharingUntil": "Delar till {time}",
      "diagnostics.failed": "Mac-datorn kunde inte ta emot diagnostiken.",
      "diagnostics.privacy": "Endast anslutningshändelser — aldrig meddelanden, terminalutdata, sökvägar eller inloggningsuppgifter.",
      "guest.browser": "webbläsare",
      "guest.defaultName": "Webbläsargäst",
      "app.code": "Kod",
      "host.defaultName": "Threading på Mac",
      "age.now": "nu"
    }
  };

  function resolveLocale() {
    var languages = navigator.languages && navigator.languages.length
      ? navigator.languages : [navigator.language || "en"];
    for (var index = 0; index < languages.length; index += 1) {
      var language = String(languages[index]).toLowerCase().split("-")[0];
      if (translations[language]) { return language; }
    }
    return "en";
  }

  var locale = resolveLocale();

  function t(key, values) {
    var template = translations[locale][key] || translations.en[key] || key;
    if (!values) { return template; }
    return template.replace(/\{([a-zA-Z0-9_]+)\}/g, function (_, name) {
      return Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : _;
    });
  }

  function localizeDocument() {
    document.documentElement.lang = locale;
    document.querySelectorAll("[data-i18n]").forEach(function (element) {
      element.textContent = t(element.getAttribute("data-i18n"));
    });
    document.querySelectorAll("[data-i18n-placeholder]").forEach(function (element) {
      element.setAttribute("placeholder", t(element.getAttribute("data-i18n-placeholder")));
    });
    document.querySelectorAll("[data-i18n-aria-label]").forEach(function (element) {
      element.setAttribute("aria-label", t(element.getAttribute("data-i18n-aria-label")));
    });
  }

  localizeDocument();

  var PROTOCOL = { version: 1, minimum: 1 };
  var tokenStorageKey = "threading.capability";
  var membershipStorageKey = "threading.membership";
  var fragmentToken = location.hash.slice(1);
  var token = fragmentToken;
  var storedMembership = "";
  try {
    storedMembership = localStorage.getItem(membershipStorageKey) || "";
    if (fragmentToken) {
      sessionStorage.setItem(tokenStorageKey, fragmentToken);
    } else {
      token = sessionStorage.getItem(tokenStorageKey) || storedMembership;
    }
  } catch (error) {
    // Storage can be disabled. The in-memory fragment token still works for this page load.
  }
  if (fragmentToken) {
    history.replaceState(null, document.title, location.pathname + location.search);
  }

  var deviceKey = "threading.device";
  var deviceID = "";
  try {
    deviceID = localStorage.getItem(deviceKey) || "";
  } catch (error) {
    // A storage-blocked browser can still use this page; its identity lasts for the tab only.
  }
  if (!deviceID) {
    deviceID = (crypto.randomUUID && crypto.randomUUID()) ||
      String(Date.now()) + "-" + Math.random().toString(16).slice(2);
    try {
      localStorage.setItem(deviceKey, deviceID);
    } catch (error) {
      // Keep the generated in-memory id.
    }
  }

  // What the Mac's sharing pane calls this browser. Read off the user agent rather than asked
  // for: it is a label beside a Revoke button, not an identity — `deviceID` is what the Mac
  // binds anything to — and one the owner can recognise without being prompted for a name.
  // The Mac bounds and sanitises it on arrival like every other string a client sends.
  var deviceName = (function () {
    var agent = navigator.userAgent || "";
    var browser = /Edg\//.test(agent) ? "Edge"
      : /OPR\//.test(agent) ? "Opera"
      : /Firefox\//.test(agent) ? "Firefox"
      : /Chrome\//.test(agent) ? "Chrome"
      : /Safari\//.test(agent) ? "Safari"
      : null;
    var platform = /iPhone/.test(agent) ? "iPhone"
      : /iPad/.test(agent) ? "iPad"
      : /Android/.test(agent) ? "Android"
      : /Mac OS X/.test(agent) ? "Mac"
      : /Windows/.test(agent) ? "Windows"
      : /Linux/.test(agent) ? "Linux"
      : null;
    if (browser && platform) { return browser + " on " + platform; }
    return browser || platform || "Browser";
  })();

  var els = {
    status: document.getElementById("status"),
    sessions: document.getElementById("sessions"),
    terminal: document.getElementById("terminal"),
    conversation: document.getElementById("conversation"),
    conversationRows: document.getElementById("conversationRows"),
    composer: document.getElementById("composer"),
    prompt: document.getElementById("prompt"),
    send: document.getElementById("send"),
    title: document.getElementById("title"),
    badge: document.getElementById("badge"),
    back: document.getElementById("back"),
  };

  var socket = null;
  var themeSocket = null;
  var themeReconnectTimer = null;
  var term = null;
  var inputSubscription = null;
  var pollTimer = null;
  var sessionListGeneration = 0;
  var activeSurface = null;
  var activeCapability = "view";
  var conversationCanSend = false;
  var presenceTimer = null;
  var isReportingTyping = false;
  var hostTheme = null;
  var activeTerminalTheme = null;
  var leasedGrid = null;
  var fitTimer = null;
  var socketDiagnosticConnected = false;
  var diagnosticSharingUntil = 0;
  var diagnosticSharingStarting = false;
  var diagnosticStartingRecords = [];
  var diagnosticExpiryTimer = null;
  var diagnosticButton = null;
  var diagnosticStatus = null;
  var lastRefreshDiagnostic = null;
  var diagnosticMemoryRecords = [];

  // The Mac owns the character grid and pushes it here, so a browser narrower than that grid
  // paints past its own frame and leaves the rest behind a scrollbar. Two answers, because a
  // guest has two kinds of standing: one who may type asks for the grid it can actually show —
  // the same lease the phone takes, which the server refuses to anyone view-only — and one who
  // may only watch shrinks its own type until the Mac's grid fits. `min` matches the server's
  // range in `RemoteAccessServer.handleViewport`, so a request is never merely rejected.
  var FIT = {
    baseFontSize: 13,
    minFontSize: 6,
    minCols: 20,
    maxCols: 240,
    minRows: 4,
    maxRows: 160,
    debounceMS: 80,
  };

  function validHex(value) {
    return typeof value === "string" && /^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(value);
  }

  function setColorVariable(style, variable, value) {
    if (validHex(value)) { style.setProperty(variable, value); }
  }

  function glowShadow(glow) {
    if (!glow || !validHex(glow.color)) { return "none"; }
    var hex = glow.color.slice(1, 7);
    var red = parseInt(hex.slice(0, 2), 16);
    var green = parseInt(hex.slice(2, 4), 16);
    var blue = parseInt(hex.slice(4, 6), 16);
    var opacity = Math.max(0, Math.min(1, Number(glow.opacity) || 0));
    var radius = Math.max(0, Math.min(80, Number(glow.radius) || 0));
    return "0 0 " + radius + "px rgba(" + red + "," + green + "," + blue + "," + opacity + ")";
  }

  function xtermTheme(theme) {
    if (!theme) { return { background: "#000000" }; }
    var palette = Array.isArray(theme.ansi) ? theme.ansi : [];
    return {
      foreground: validHex(theme.foreground) ? theme.foreground : "#e6e8ec",
      background: validHex(theme.background) ? theme.background : "#000000",
      cursor: validHex(theme.cursor) ? theme.cursor : theme.foreground,
      selectionBackground: validHex(theme.selection) ? theme.selection : "#ffffff33",
      black: palette[0], red: palette[1], green: palette[2], yellow: palette[3],
      blue: palette[4], magenta: palette[5], cyan: palette[6], white: palette[7],
      brightBlack: palette[8], brightRed: palette[9], brightGreen: palette[10],
      brightYellow: palette[11], brightBlue: palette[12], brightMagenta: palette[13],
      brightCyan: palette[14], brightWhite: palette[15],
    };
  }

  function applyTheme(theme, terminalTheme) {
    var style = document.documentElement.style;
    if (theme && theme.colors) {
      var colors = theme.colors;
      setColorVariable(style, "--bg", colors.ground);
      setColorVariable(style, "--surface", colors.surface);
      setColorVariable(style, "--panel", colors.panel);
      setColorVariable(style, "--elevated", colors.elevated);
      setColorVariable(style, "--panel-hover", colors.control_hover);
      setColorVariable(style, "--control-resting", colors.control_resting);
      setColorVariable(style, "--text", colors.label);
      setColorVariable(style, "--muted", colors.secondary_label);
      setColorVariable(style, "--tertiary", colors.tertiary_label);
      setColorVariable(style, "--accent", colors.accent);
      setColorVariable(style, "--accent-muted", colors.accent_muted);
      setColorVariable(style, "--border", colors.border);
      setColorVariable(style, "--divider", colors.divider);
      setColorVariable(style, "--positive", colors.status_positive);
      setColorVariable(style, "--warning", colors.status_warning);
      setColorVariable(style, "--negative", colors.status_negative);
      setColorVariable(style, "--diff-added", colors.diff_added);
      setColorVariable(style, "--diff-removed", colors.diff_removed);
      document.documentElement.style.colorScheme = theme.mode === "light" ? "light" : "dark";

      if (theme.material) {
        style.setProperty("--panel-radius", Math.max(0, Number(theme.material.panelRadius) || 0) + "px");
        style.setProperty("--control-radius", Math.max(0, Number(theme.material.controlRadius) || 0) + "px");
        style.setProperty("--border-width", Math.max(0, Number(theme.material.borderWidth) || 0) + "px");
        style.setProperty("--panel-shadow", glowShadow(theme.material.glow));
      }
    }

    activeTerminalTheme = terminalTheme || null;
    var terminalColors = xtermTheme(activeTerminalTheme);
    setColorVariable(style, "--terminal-bg", terminalColors.background);
    if (term) { term.options.theme = terminalColors; }
  }

  function show(view) {
    els.status.hidden = view !== "status";
    els.sessions.hidden = view !== "sessions";
    els.terminal.hidden = view !== "terminal";
    els.conversation.hidden = view !== "conversation";
    els.back.hidden = view !== "terminal" && view !== "conversation";
  }

  function setStatus(text) {
    els.status.textContent = text;
    els.status.onclick = null;
    els.status.onkeydown = null;
    els.status.removeAttribute("tabindex");
    els.status.style.cursor = "";
    show("status");
  }

  function cancelPoll() {
    if (pollTimer !== null) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
  }

  function scheduleSessionLoad(generation, delay) {
    cancelPoll();
    pollTimer = setTimeout(function () { loadSessions(generation); }, delay);
  }

  function beginSessionList() {
    cancelPoll();
    sessionListGeneration += 1;
    connectThemeEvents();
    loadSessions(sessionListGeneration);
  }

  function authHeaders() {
    return {
      "Authorization": "Bearer " + token,
      "X-Threading-Device": deviceID,
      "X-Threading-Protocol": String(PROTOCOL.version),
      "X-Threading-Protocol-Min": String(PROTOCOL.minimum),
      "X-Threading-Client": "Threading-Web",
    };
  }

  // --- Privacy-bounded diagnostics --------------------------------------

  var DIAGNOSTICS = {
    storageKey: "threading.remote-diagnostics",
    retentionMS: 7 * 24 * 60 * 60 * 1000,
    maximumRecords: 500,
    maximumBatch: 250,
    sharingMS: 30 * 60 * 1000,
    events: {
      appLaunched: true,
      hostPairingStarted: true,
      hostPairingSucceeded: true,
      hostPairingFailed: true,
      hostRefreshSucceeded: true,
      hostRefreshFailed: true,
      socketConnecting: true,
      socketConnected: true,
      socketEnded: true,
      socketFailed: true,
      diagnosticSharingStarted: true,
      diagnosticSharingStopped: true,
    },
    fields: {
      kind: true,
      transport: true,
      result: true,
      code: true,
      status: true,
      protocolVersion: true,
      minimumProtocolVersion: true,
      capability: true,
      surface: true,
      reason: true,
    },
  };

  function safeDiagnosticValue(value) {
    var safe = String(value).replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
      .replace(/\s+/g, " ");
    while (new TextEncoder().encode(safe).length > 160) {
      safe = safe.slice(0, -1);
    }
    return safe;
  }

  function diagnosticRecords() {
    try {
      var decoded = JSON.parse(localStorage.getItem(DIAGNOSTICS.storageKey) || "[]");
      if (!Array.isArray(decoded)) { return []; }
      var cutoff = Date.now() - DIAGNOSTICS.retentionMS;
      diagnosticMemoryRecords = decoded.filter(function (record) {
        return record && DIAGNOSTICS.events[record.event] &&
          Date.parse(record.timestamp) >= cutoff;
      }).slice(-DIAGNOSTICS.maximumRecords);
      return diagnosticMemoryRecords;
    } catch (error) {
      return diagnosticMemoryRecords;
    }
  }

  function storeDiagnosticRecords(records) {
    diagnosticMemoryRecords = records.slice(-DIAGNOSTICS.maximumRecords);
    try {
      localStorage.setItem(
        DIAGNOSTICS.storageKey,
        JSON.stringify(diagnosticMemoryRecords)
      );
    } catch (error) {
      // A storage-blocked browser still keeps live diagnostics for this page load.
    }
  }

  function recordDiagnostic(event, level, fields, forward) {
    if (!DIAGNOSTICS.events[event]) { return null; }
    var safeFields = {};
    Object.keys(fields || {}).forEach(function (key) {
      if (DIAGNOSTICS.fields[key]) {
        safeFields[key] = safeDiagnosticValue(fields[key]);
      }
    });
    var record = {
      timestamp: new Date().toISOString(),
      source: "browserClient",
      level: level || "info",
      event: event,
      fields: safeFields,
    };
    var records = diagnosticRecords();
    records.push(record);
    storeDiagnosticRecords(records);

    if (forward !== false && token) {
      if (diagnosticSharingStarting) {
        diagnosticStartingRecords.push(record);
        diagnosticStartingRecords = diagnosticStartingRecords.slice(
          -DIAGNOSTICS.maximumRecords
        );
      } else if (diagnosticSharingUntil > Date.now()) {
        uploadDiagnosticRecords([record]).catch(function () {
          // The durable local copy remains available if the Mac became unreachable.
        });
      }
    }
    return record;
  }

  function uploadDiagnosticRecords(records) {
    var offset = 0;
    function sendNext() {
      if (offset >= records.length) { return Promise.resolve(); }
      var batch = records.slice(offset, offset + DIAGNOSTICS.maximumBatch);
      return fetch("/api/diagnostics", {
        method: "POST",
        headers: Object.assign({ "Content-Type": "application/json" }, authHeaders()),
        body: JSON.stringify({
          schemaVersion: 1,
          source: "browserClient",
          records: batch,
        }),
      }).then(function (response) {
        if (!response.ok) { throw new Error("diagnosticUpload"); }
        return response.json();
      }).then(function (body) {
        if (!body || body.acceptedRecords !== batch.length) {
          throw new Error("diagnosticUpload");
        }
        offset += batch.length;
        return sendNext();
      });
    }
    return sendNext();
  }

  function refreshDiagnosticControl() {
    if (!diagnosticButton || !diagnosticStatus) { return; }
    var sharing = diagnosticSharingUntil > Date.now();
    diagnosticButton.disabled = diagnosticSharingStarting;
    diagnosticButton.textContent = t(sharing ? "diagnostics.stop" : "diagnostics.share");
    diagnosticStatus.textContent = diagnosticSharingStarting
      ? t("status.connecting")
      : sharing
      ? t("diagnostics.sharingUntil", {
          time: new Intl.DateTimeFormat(locale, {
            hour: "numeric",
            minute: "2-digit",
          }).format(new Date(diagnosticSharingUntil)),
        })
      : t("diagnostics.privacy");
  }

  function stopDiagnosticSharing(reason) {
    if (diagnosticSharingUntil > Date.now()) {
      recordDiagnostic("diagnosticSharingStopped", "info", {
        reason: reason || "user",
      });
    }
    diagnosticSharingUntil = 0;
    if (diagnosticExpiryTimer !== null) {
      clearTimeout(diagnosticExpiryTimer);
      diagnosticExpiryTimer = null;
    }
    refreshDiagnosticControl();
  }

  function uploadStartingDiagnosticRecords() {
    if (diagnosticStartingRecords.length === 0) { return Promise.resolve(); }
    var records = diagnosticStartingRecords.splice(
      0,
      DIAGNOSTICS.maximumRecords
    );
    return uploadDiagnosticRecords(records).then(uploadStartingDiagnosticRecords);
  }

  function startDiagnosticSharing() {
    if (!diagnosticButton || diagnosticSharingStarting) { return; }
    diagnosticSharingStarting = true;
    diagnosticStartingRecords = [];
    refreshDiagnosticControl();
    recordDiagnostic("diagnosticSharingStarted", "info", { reason: "user" }, false);
    uploadDiagnosticRecords(diagnosticRecords())
      .then(uploadStartingDiagnosticRecords)
      .then(function () {
        diagnosticSharingStarting = false;
        diagnosticSharingUntil = Date.now() + DIAGNOSTICS.sharingMS;
        diagnosticExpiryTimer = setTimeout(function () {
          stopDiagnosticSharing("expired");
        }, DIAGNOSTICS.sharingMS);
        refreshDiagnosticControl();
      }).catch(function () {
        diagnosticSharingStarting = false;
        diagnosticStartingRecords = [];
        diagnosticSharingUntil = 0;
        recordDiagnostic(
          "diagnosticSharingStopped",
          "warning",
          { reason: "uploadFailed" },
          false
        );
        refreshDiagnosticControl();
        diagnosticStatus.textContent = t("diagnostics.failed");
      });
  }

  function addDiagnosticControl(container, me) {
    diagnosticButton = null;
    diagnosticStatus = null;
    if (!me.share || me.share.scope !== "all" || me.share.capability !== "interact") {
      return;
    }
    var controls = document.createElement("div");
    controls.className = "diagnostic-controls";
    diagnosticButton = document.createElement("button");
    diagnosticButton.type = "button";
    diagnosticButton.addEventListener("click", function () {
      if (diagnosticSharingUntil > Date.now()) {
        stopDiagnosticSharing("user");
      } else {
        startDiagnosticSharing();
      }
    });
    diagnosticStatus = document.createElement("span");
    controls.appendChild(diagnosticButton);
    controls.appendChild(diagnosticStatus);
    container.appendChild(controls);
    refreshDiagnosticControl();
  }

  function recordRefreshDiagnostic(result, level, fields) {
    if (lastRefreshDiagnostic === result) { return; }
    lastRefreshDiagnostic = result;
    recordDiagnostic(
      result === "success" ? "hostRefreshSucceeded" : "hostRefreshFailed",
      level,
      fields
    );
  }

  function reportTyping(typing) {
    if (presenceTimer !== null) {
      clearTimeout(presenceTimer);
      presenceTimer = null;
    }
    if (!socket || activeCapability !== "interact") {
      isReportingTyping = false;
      return;
    }
    if (typing) {
      if (!isReportingTyping) {
        isReportingTyping = true;
        socket.send(JSON.stringify({ type: "presence", state: "typing" }));
      }
      presenceTimer = setTimeout(function () { reportTyping(false); }, 2000);
    } else if (isReportingTyping) {
      isReportingTyping = false;
      socket.send(JSON.stringify({ type: "presence", state: "idle" }));
    }
  }

  function acceptConnection() {
    if (!token) {
      setStatus(t("link.missingToken"));
      return;
    }
    recordDiagnostic("hostPairingStarted");
    setStatus(t("invitation.accepting"));
    fetch("/api/invitations/accept", {
      method: "POST",
      headers: Object.assign({ "Content-Type": "application/json" }, authHeaders()),
      body: JSON.stringify({
        displayName: navigator.platform
          ? navigator.platform + " " + t("guest.browser")
          : t("guest.defaultName"),
      }),
    }).then(function (res) {
      if (res.status === 426) {
        return res.json().then(function (body) {
          showUpdateNeeded(body.update, body.message);
        });
      }
      if (res.status === 401) {
        recordDiagnostic("hostPairingFailed", "error", { code: "remote.http.401" });
        setStatus(t("invitation.invalid"));
        return;
      }
      if (!res.ok) {
        recordDiagnostic("hostPairingFailed", "error", {
          code: "remote.http." + String(res.status),
        });
        setStatus(t("invitation.failed"));
        return;
      }
      return res.json().then(function (body) {
        if (!body.accessToken) {
          setStatus(t("invitation.unreadable"));
          return;
        }
        token = body.accessToken;
        try {
          sessionStorage.setItem(tokenStorageKey, token);
          if (body.me && body.me.share && body.me.share.scope === "session") {
            storedMembership = token;
            localStorage.setItem(membershipStorageKey, token);
          }
        } catch (error) {
          // The accepted bearer remains valid for this page load.
        }
        recordDiagnostic("hostPairingSucceeded", "info", {
          capability: body.me && body.me.share ? body.me.share.capability : "unknown",
        });
        beginSessionList();
      });
    }).catch(function () {
      recordDiagnostic("hostPairingFailed", "error", { code: "network" });
      setStatus(t("mac.retry"));
      els.status.style.cursor = "pointer";
      els.status.setAttribute("tabindex", "0");
      els.status.onclick = acceptConnection;
      els.status.onkeydown = function (event) {
        if (event.key === "Enter" || event.key === " ") { acceptConnection(); }
      };
    });
  }

  function connectThemeEvents() {
    if (!token || themeSocket) { return; }
    if (themeReconnectTimer !== null) {
      clearTimeout(themeReconnectTimer);
      themeReconnectTimer = null;
    }
    var scheme = location.protocol === "https:" ? "wss:" : "ws:";
    var opened = new WebSocket(scheme + "//" + location.host + "/ws/events");
    themeSocket = opened;
    opened.onopen = function () {
      if (themeSocket !== opened) { return; }
      opened.send(JSON.stringify({
        type: "auth",
        token: token,
        device: deviceID,
        deviceName: deviceName,
        protocolVersion: PROTOCOL.version,
        protocolMinimum: PROTOCOL.minimum,
      }));
    };
    opened.onmessage = function (event) {
      if (themeSocket !== opened || typeof event.data !== "string") { return; }
      var message;
      try { message = JSON.parse(event.data); } catch (error) { return; }
      if (message.type === "appTheme" && message.theme) {
        hostTheme = message.theme;
        applyTheme(hostTheme, activeTerminalTheme);
      } else if (message.type === "sessionsChanged" && activeSurface === null) {
        scheduleSessionLoad(sessionListGeneration, 0);
      }
    };
    opened.onclose = function () {
      if (themeSocket !== opened) { return; }
      themeSocket = null;
      if (activeSurface === null) {
        themeReconnectTimer = setTimeout(connectThemeEvents, 2000);
      }
    };
  }

  function closeThemeEvents() {
    if (themeReconnectTimer !== null) {
      clearTimeout(themeReconnectTimer);
      themeReconnectTimer = null;
    }
    var closing = themeSocket;
    themeSocket = null;
    if (closing) { try { closing.close(); } catch (error) {} }
  }

  function showUpdateNeeded(update) {
    if (update === "host") {
      setStatus(t("update.host"));
    } else {
      setStatus(t("update.page"));
      els.status.style.cursor = "pointer";
      els.status.setAttribute("tabindex", "0");
      els.status.onclick = function () { location.reload(); };
      els.status.onkeydown = function (event) {
        if (event.key === "Enter" || event.key === " ") { location.reload(); }
      };
    }
  }

  // --- Session list and resume ------------------------------------------

  function loadSessions(generation) {
    if (generation !== sessionListGeneration) { return; }
    if (!token) { setStatus(t("link.missingToken")); return; }

    fetch("/api/me", { headers: authHeaders() }).then(function (res) {
      if (generation !== sessionListGeneration) { return; }
      if (res.status === 426) {
        return res.json().then(function (body) {
          if (generation === sessionListGeneration) {
            showUpdateNeeded(body.update);
          }
        });
      }
      if (res.status === 401) {
        recordRefreshDiagnostic("failure", "error", { code: "remote.http.401" });
        setStatus(t("link.invalid"));
        return;
      }
      if (res.status === 403) {
        return res.json().then(function (body) {
          if (generation !== sessionListGeneration) { return; }
          if (body.state === "pendingApproval") {
            setStatus(t("device.waitingApproval"));
            scheduleSessionLoad(generation, (body.retryAfter || 2) * 1000);
          } else {
            setStatus(t("device.denied"));
          }
        });
      }
      if (!res.ok) {
        recordRefreshDiagnostic("failure", "error", {
          code: "remote.http." + String(res.status),
        });
        setStatus(t("mac.retrying"));
        scheduleSessionLoad(generation, 3000);
        return;
      }
      return res.json().then(function (body) {
        if (generation === sessionListGeneration) {
          recordRefreshDiagnostic("success", "info", {
            protocolVersion: String(body.serverProtocol.version),
            minimumProtocolVersion: String(body.serverProtocol.minimumSupported),
          });
          renderSessions(body);
        }
      });
    }).catch(function () {
      if (generation !== sessionListGeneration) { return; }
      recordRefreshDiagnostic("failure", "error", { code: "network" });
      setStatus(t("mac.retrying"));
      scheduleSessionLoad(generation, 3000);
    });
  }

  function renderSessions(me) {
    hostTheme = me.theme || null;
    applyTheme(hostTheme, null);
    els.title.textContent = t("app.code");
    els.badge.hidden = true;
    els.sessions.innerHTML = "";

    if (!me.sessions || me.sessions.length === 0) {
      setStatus(t("sessions.empty"));
      return;
    }

    var device = document.createElement("li");
    device.className = "device";
    var deviceIcon = document.createElement("span");
    deviceIcon.className = "device-icon";
    deviceIcon.textContent = "⌘";
    var deviceCopy = document.createElement("span");
    deviceCopy.className = "device-copy";
    var deviceName = document.createElement("strong");
    deviceName.textContent = (me.host && me.host.name) || t("host.defaultName");
    var deviceStatus = document.createElement("span");
    deviceStatus.className = "device-status";
    deviceStatus.textContent = t("sessions.connectedSecurely");
    deviceCopy.appendChild(deviceName);
    deviceCopy.appendChild(deviceStatus);
    device.appendChild(deviceIcon);
    device.appendChild(deviceCopy);
    addDiagnosticControl(device, me);
    els.sessions.appendChild(device);

    var sessionHeading = document.createElement("li");
    sessionHeading.className = "section-heading";
    var sessionHeadingLabel = document.createElement("span");
    sessionHeadingLabel.textContent = t("sessions.heading");
    var sessionCount = document.createElement("span");
    sessionCount.textContent = String(me.sessions.length);
    sessionHeading.appendChild(sessionHeadingLabel);
    sessionHeading.appendChild(sessionCount);
    els.sessions.appendChild(sessionHeading);

    var groups = Object.create(null);
    me.sessions.forEach(function (session) {
      var project = session.projectName || t("sessions.otherProject");
      (groups[project] || (groups[project] = [])).push(session);
    });

    Object.keys(groups).sort().forEach(function (project) {
      var heading = document.createElement("li");
      heading.className = "project";
      heading.textContent = project;
      els.sessions.appendChild(heading);

      groups[project].forEach(function (session) {
        var li = document.createElement("li");
        var button = document.createElement("button");
        button.type = "button";
        button.className = "session" + (session.isAvailable ? "" : " dormant");

        var topLine = document.createElement("div");
        topLine.className = "session-top-line";
        var name = document.createElement("div");
        name.className = "name";
        name.textContent = session.title || t("session.defaultName");
        topLine.appendChild(name);
        if (session.lastActiveAt) {
          var age = document.createElement("time");
          age.textContent = compactAge(session.lastActiveAt);
          age.dateTime = new Date(session.lastActiveAt * 1000).toISOString();
          topLine.appendChild(age);
        }

        var meta = document.createElement("div");
        meta.className = "meta";
        var dot = document.createElement("span");
        dot.className = "dot " + (session.isAvailable ? (session.state || "idle") : "dormant");
        meta.appendChild(dot);
        meta.appendChild(document.createTextNode(
          (session.isAvailable ? stateLabel(session.state) : t("session.disconnected")) +
          " · " + agentLabel(session.agentKind)
        ));

        button.appendChild(topLine);
        button.appendChild(meta);
        button.addEventListener("click", function () { prepareSession(session); });
        li.appendChild(button);
        els.sessions.appendChild(li);
      });
    });
    show("sessions");
  }

  function stateLabel(state) {
    if (state === "working") { return t("session.working"); }
    if (state === "needsAttention") { return t("session.needsAttention"); }
    return t("session.connected");
  }

  function agentLabel(kind) {
    return String(kind || "").toLowerCase() === "claude" ? "Claude Code" : "Codex";
  }

  function compactAge(timestamp) {
    var seconds = Math.max(0, Date.now() / 1000 - timestamp);
    if (seconds < 60) { return t("age.now"); }
    var relative = new Intl.RelativeTimeFormat(locale, { numeric: "auto", style: "narrow" });
    if (seconds < 3600) { return relative.format(-Math.floor(seconds / 60), "minute"); }
    if (seconds < 86400) { return relative.format(-Math.floor(seconds / 3600), "hour"); }
    if (seconds < 604800) { return relative.format(-Math.floor(seconds / 86400), "day"); }
    return new Intl.DateTimeFormat(locale, { month: "short", day: "numeric" })
      .format(new Date(timestamp * 1000));
  }

  function prepareSession(session) {
    if (session.isAvailable) {
      openSession(session);
      return;
    }

    cancelPoll();
    var generation = ++sessionListGeneration;
    els.title.textContent = session.title || t("session.defaultName");
    setStatus(t("session.resuming"));
    fetch("/api/session/" + encodeURIComponent(session.id) + "/resume", {
      method: "POST",
      headers: authHeaders(),
    }).then(function (res) {
      if (generation !== sessionListGeneration) { return; }
      if (!res.ok) { throw new Error("resume"); }
      waitForSession(session.id, generation, 0);
    }).catch(function () {
      if (generation === sessionListGeneration) {
        setStatus(t("session.resumeFailed"));
      }
    });
  }

  function waitForSession(sessionID, generation, attempt) {
    if (generation !== sessionListGeneration) { return; }
    fetch("/api/me", { headers: authHeaders() }).then(function (res) {
      if (!res.ok) { throw new Error("poll"); }
      return res.json();
    }).then(function (me) {
      if (generation !== sessionListGeneration) { return; }
      hostTheme = me.theme || hostTheme;
      var session = (me.sessions || []).find(function (item) { return item.id === sessionID; });
      if (session && session.isAvailable) {
        openSession(session);
        return;
      }
      if (attempt >= 39) { throw new Error("timeout"); }
      pollTimer = setTimeout(function () {
        waitForSession(sessionID, generation, attempt + 1);
      }, 500);
    }).catch(function () {
      if (generation === sessionListGeneration) {
        setStatus(t("session.resumeTimedOut"));
      }
    });
  }

  // --- Live surface ------------------------------------------------------

  function openSession(session) {
    cancelPoll();
    sessionListGeneration += 1;
    closeSocket();
    closeThemeEvents();
    disposeTerminal();
    resetConversation();

    applyTheme(hostTheme, session.terminalTheme || null);
    els.title.textContent = session.title || t("session.defaultName");
    activateSurface(session.surface || "terminal");
    socketDiagnosticConnected = false;
    recordDiagnostic("socketConnecting", "info", {
      transport: "websocket",
      surface: session.surface || "terminal",
      protocolVersion: String(PROTOCOL.version),
      minimumProtocolVersion: String(PROTOCOL.minimum),
    });

    var scheme = location.protocol === "https:" ? "wss:" : "ws:";
    var openedSocket = new WebSocket(
      scheme + "//" + location.host + "/ws/session/" + encodeURIComponent(session.id)
    );
    socket = openedSocket;
    openedSocket.binaryType = "arraybuffer";
    setBadge(t("badge.connecting"), "connecting");

    openedSocket.onopen = function () {
      if (socket !== openedSocket) { return; }
      openedSocket.send(JSON.stringify({
        type: "auth",
        token: token,
        device: deviceID,
        deviceName: deviceName,
        protocolVersion: PROTOCOL.version,
        protocolMinimum: PROTOCOL.minimum,
      }));
    };

    openedSocket.onmessage = function (event) {
      if (socket !== openedSocket) { return; }
      if (event.data instanceof ArrayBuffer) {
        if (term) { term.write(new Uint8Array(event.data)); }
        return;
      }
      var msg;
      try { msg = JSON.parse(event.data); } catch (e) { return; }
      handleServerMessage(msg, openedSocket);
    };

    openedSocket.onclose = function () {
      if (socket !== openedSocket) { return; }
      socket = null;
      recordDiagnostic(
        socketDiagnosticConnected ? "socketEnded" : "socketFailed",
        socketDiagnosticConnected ? "info" : "error",
        {
          transport: "websocket",
          reason: socketDiagnosticConnected ? "connectionClosed" : "beforeHello",
        }
      );
      socketDiagnosticConnected = false;
      setBadge(t("badge.disconnected"), "disconnected");
      if (term) {
        term.write("\r\n\x1b[2m" + t("terminal.disconnected") + "\x1b[0m\r\n");
      } else {
        appendNotice(t("session.socketDisconnected"));
      }
      updateComposer();
    };
  }

  function activateSurface(surface) {
    activeSurface = surface === "conversation" ? "conversation" : "terminal";
    if (activeSurface === "conversation") {
      disposeTerminal();
      show("conversation");
      updateComposer();
      return;
    }

    if (!term) {
      els.terminal.innerHTML = "";
      term = new Terminal({
        convertEol: false,
        cursorBlink: true,
        fontFamily: "SF Mono, Menlo, Consolas, monospace",
        fontSize: FIT.baseFontSize,
        theme: xtermTheme(activeTerminalTheme),
      });
      term.open(els.terminal);
    }
    show("terminal");
    scheduleFit();
  }

  // --- Fitting the host's grid -------------------------------------------

  function clampNumber(value, low, high) {
    return Math.max(low, Math.min(high, value));
  }

  // The box the terminal may paint in, with `#terminal`'s own padding taken off. Read rather
  // than duplicated as a constant, so the CSS stays the one place the padding is decided.
  function terminalBox() {
    var style = window.getComputedStyle(els.terminal);
    return {
      width: els.terminal.clientWidth -
        parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
      height: els.terminal.clientHeight -
        parseFloat(style.paddingTop) - parseFloat(style.paddingBottom),
    };
  }

  // One character cell as xterm actually rendered it, normalised back to the base font size.
  // A view-only client is usually looking at shrunken type, and the grid it *would* ask for
  // has to be measured in the size it would ask at, not the size it settled for.
  function baseCellSize() {
    if (!term || !term.element || !term.cols || !term.rows) { return null; }
    var screen = term.element.querySelector(".xterm-screen");
    if (!screen) { return null; }
    var rendered = term.options.fontSize || FIT.baseFontSize;
    var scale = FIT.baseFontSize / rendered;
    var width = (screen.offsetWidth / term.cols) * scale;
    var height = (screen.offsetHeight / term.rows) * scale;
    if (!(width > 0) || !(height > 0)) { return null; }
    return { width: width, height: height };
  }

  // Asks the Mac to reflow the shared PTY to what this browser can show. The request is
  // deduplicated against the last one sent — not against the grid that came back — because the
  // Mac may answer with a different one, and comparing against the answer would re-ask forever.
  function requestViewportLease() {
    if (activeCapability !== "interact") { return; }
    if (!socket || socket.readyState !== WebSocket.OPEN) { return; }
    var box = terminalBox();
    var cell = baseCellSize();
    if (!cell || !(box.width > 0) || !(box.height > 0)) { return; }

    var grid = {
      cols: clampNumber(Math.floor(box.width / cell.width), FIT.minCols, FIT.maxCols),
      rows: clampNumber(Math.floor(box.height / cell.height), FIT.minRows, FIT.maxRows),
    };
    if (leasedGrid && leasedGrid.cols === grid.cols && leasedGrid.rows === grid.rows) { return; }
    leasedGrid = grid;
    socket.send(JSON.stringify({ type: "viewport", cols: grid.cols, rows: grid.rows }));
  }

  // The floor under both paths: whatever grid the Mac settled on, the type shrinks until the
  // whole of it is inside the frame. Height counts as much as width — the rows that fall off
  // the bottom are the live ones, the prompt among them, and a watcher who has to scroll to
  // reach the present is worse off than one reading small type. A grid that already fits is
  // restored to full size, which is what returns an interactive client to 13px once its lease
  // is honoured.
  function fitFontToGrid() {
    if (!term) { return; }
    var box = terminalBox();
    var cell = baseCellSize();
    if (!cell || !(box.width > 0) || !(box.height > 0)) { return; }

    var ratio = Math.min(
      box.width / (cell.width * term.cols),
      box.height / (cell.height * term.rows)
    );
    var size = ratio >= 1
      ? FIT.baseFontSize
      : Math.max(FIT.minFontSize, Math.floor(FIT.baseFontSize * ratio));
    if (term.options.fontSize !== size) { term.options.fontSize = size; }
  }

  function fitTerminal() {
    if (!term || activeSurface !== "terminal" || els.terminal.hidden) { return; }
    requestViewportLease();
    fitFontToGrid();
  }

  // Coalesced because a live window drag fires continuously, and because xterm has to have
  // laid the grid out before it can be measured — the terminal is opened while still hidden.
  function scheduleFit() {
    if (fitTimer !== null) { clearTimeout(fitTimer); }
    fitTimer = setTimeout(function () {
      fitTimer = null;
      fitTerminal();
    }, FIT.debounceMS);
  }

  function releaseViewportLease() {
    if (!leasedGrid) { return; }
    leasedGrid = null;
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: "viewportRelease" }));
    }
  }

  function handleServerMessage(msg, openedSocket) {
    switch (msg.type) {
      case "hello":
        socketDiagnosticConnected = true;
        recordDiagnostic("socketConnected", "info", {
          transport: "websocket",
          surface: msg.surface || "terminal",
          capability: msg.capability || "view",
        });
        if (msg.theme) { hostTheme = msg.theme; }
        applyTheme(msg.theme || hostTheme, msg.terminalTheme || activeTerminalTheme);
        activateSurface(msg.surface);
        if (msg.cols && msg.rows && term) { term.resize(msg.cols, msg.rows); }
        if (msg.title) { els.title.textContent = msg.title; }
        setCapability(msg.capability, openedSocket);
        scheduleFit();
        break;
      case "resize":
        if (msg.cols && msg.rows && term) { term.resize(msg.cols, msg.rows); }
        scheduleFit();
        break;
      case "title":
        if (msg.title) { els.title.textContent = msg.title; }
        break;
      case "theme":
        hostTheme = msg.theme || hostTheme;
        applyTheme(hostTheme, msg.terminalTheme || activeTerminalTheme);
        break;
      case "conversation":
        renderConversation(msg);
        break;
      case "error":
        if (msg.code === "forbidden") {
          appendNotice(t("error.viewOnly"));
        } else if (msg.code === "inputTooLarge" || msg.code === "promptTooLarge") {
          appendNotice(t("error.inputTooLarge"));
        } else {
          appendNotice(t("error.remoteAction"));
        }
        break;
      case "ended":
        recordDiagnostic("socketEnded", "info", {
          transport: "websocket",
          reason: msg.reason || "host",
        });
        socketDiagnosticConnected = false;
        closeSocket();
        if (msg.reason === "protocolMismatch") {
          disposeTerminal();
          showUpdateNeeded(msg.update);
        } else {
          setBadge(t("badge.ended"), "disconnected");
          if (term) {
            term.write("\r\n\x1b[2m" + t("terminal.ended") + "\x1b[0m\r\n");
          } else {
            appendNotice(t("session.endedOnMac"));
          }
        }
        updateComposer();
        break;
    }
  }

  function setBadge(text, className) {
    els.badge.hidden = false;
    els.badge.textContent = text;
    els.badge.className = className || "";
  }

  function setCapability(capability, openedSocket) {
    activeCapability = capability;
    if (inputSubscription) {
      inputSubscription.dispose();
      inputSubscription = null;
    }
    if (capability === "interact") {
      setBadge(t("badge.interactive"), "interact");
      if (term) {
        inputSubscription = term.onData(function (data) {
          if (socket === openedSocket && openedSocket.readyState === WebSocket.OPEN) {
            openedSocket.send(JSON.stringify({ type: "input", data: data }));
          }
        });
        term.focus();
      }
    } else {
      setBadge(t("badge.viewOnly"), "");
    }
    updateComposer();
  }

  // --- Conversation ------------------------------------------------------

  function resetConversation() {
    els.conversationRows.innerHTML = "";
    els.prompt.value = "";
    conversationCanSend = false;
    activeCapability = "view";
    updateComposer();
  }

  function renderConversation(snapshot) {
    var wasNearBottom = els.conversationRows.scrollHeight -
      els.conversationRows.scrollTop - els.conversationRows.clientHeight < 100;
    els.conversationRows.innerHTML = "";

    (snapshot.rows || []).forEach(function (row) {
      var node;
      if (row.kind === "user") {
        node = document.createElement("div");
        node.className = "conversation-row user";
        var bubble = document.createElement("div");
        bubble.className = "bubble";
        bubble.textContent = row.text || "";
        node.appendChild(bubble);
      } else if (row.kind === "tool") {
        node = document.createElement("details");
        node.className = "conversation-row tool";
        var summary = document.createElement("summary");
        var glyph = document.createElement("span");
        glyph.className = "tool-glyph";
        glyph.textContent = toolGlyph(row.toolName);
        var toolName = document.createElement("strong");
        toolName.textContent = row.toolName || t("conversation.tool");
        summary.appendChild(glyph);
        summary.appendChild(toolName);
        summary.appendChild(document.createTextNode(
          "  " + (row.summary || t("conversation.working"))
        ));
        node.appendChild(summary);
        if (row.result) {
          var result = document.createElement("pre");
          if (row.isError) { result.className = "error"; }
          result.textContent = row.result;
          node.appendChild(result);
        }
      } else if (row.kind === "thinking") {
        node = document.createElement("details");
        node.className = "conversation-row thinking";
        var thinkingSummary = document.createElement("summary");
        thinkingSummary.textContent = t("conversation.reasoning");
        var thinkingText = document.createElement("div");
        thinkingText.textContent = row.text || "";
        node.appendChild(thinkingSummary);
        node.appendChild(thinkingText);
      } else {
        node = document.createElement("div");
        node.className = "conversation-row " +
          (row.kind === "assistant" ? "assistant" : "notice") +
          (row.isError ? " error" : "");
        if (row.kind === "assistant") {
          renderAssistant(node, row.text || "");
        } else {
          node.textContent = row.text || "";
        }
      }
      els.conversationRows.appendChild(node);
    });

    if (snapshot.streamingText) {
      var streaming = document.createElement("div");
      streaming.className = "conversation-row assistant streaming";
      streaming.textContent = snapshot.streamingText;
      els.conversationRows.appendChild(streaming);
    }
    if (snapshot.permission) {
      renderPermission(snapshot.permission);
    }

    conversationCanSend = !!snapshot.canSend;
    updateComposer();
    if (wasNearBottom) {
      requestAnimationFrame(function () {
        els.conversationRows.scrollTop = els.conversationRows.scrollHeight;
      });
    }
  }

  function appendNotice(text) {
    if (activeSurface !== "conversation") { return; }
    var node = document.createElement("div");
    node.className = "conversation-row notice";
    node.textContent = text;
    els.conversationRows.appendChild(node);
    els.conversationRows.scrollTop = els.conversationRows.scrollHeight;
  }

  function toolGlyph(name) {
    switch (String(name || "").toLowerCase()) {
      case "bash": return "$";
      case "read": return "→";
      case "write":
      case "edit":
      case "multiedit": return "←";
      case "grep":
      case "glob": return "✱";
      case "websearch":
      case "webfetch": return "◈";
      default: return "·";
    }
  }

  function renderAssistant(container, source) {
    var lines = source.split("\n");
    var prose = [];
    var code = [];
    var language = "";
    var inFence = false;

    function appendProse() {
      var text = prose.join("\n").trim();
      prose = [];
      if (!text) { return; }
      var block = document.createElement("div");
      block.className = "assistant-prose";
      block.textContent = text;
      container.appendChild(block);
    }

    function appendCode() {
      var codeText = code.join("\n");
      var card = document.createElement("div");
      card.className = "code-card";
      var header = document.createElement("div");
      header.className = "code-header";
      var label = document.createElement("span");
      label.textContent = language || t("code.defaultLanguage");
      var copy = document.createElement("button");
      copy.type = "button";
      copy.textContent = t("code.copy");
      copy.addEventListener("click", function () {
        navigator.clipboard.writeText(codeText).then(function () {
          copy.textContent = t("code.copied");
          setTimeout(function () { copy.textContent = t("code.copy"); }, 1200);
        }).catch(function () {
          copy.textContent = t("code.selectToCopy");
        });
      });
      header.appendChild(label);
      header.appendChild(copy);
      var pre = document.createElement("pre");
      pre.textContent = codeText;
      card.appendChild(header);
      card.appendChild(pre);
      container.appendChild(card);
      code = [];
      language = "";
    }

    lines.forEach(function (line) {
      if (line.indexOf("```") === 0) {
        if (inFence) {
          appendCode();
        } else {
          appendProse();
          language = line.slice(3).trim();
        }
        inFence = !inFence;
      } else if (inFence) {
        code.push(line);
      } else {
        prose.push(line);
      }
    });

    if (inFence) {
      prose.push("```" + language);
      Array.prototype.push.apply(prose, code);
    }
    appendProse();
  }

  function renderPermission(permission) {
    var card = document.createElement("section");
    card.className = "permission-card";
    var title = document.createElement("strong");
    title.textContent = t("permission.title", {
      tool: permission.toolName || t("permission.tool"),
    });
    card.appendChild(title);

    if (permission.summary) {
      var summary = document.createElement("pre");
      summary.className = "permission-summary";
      summary.textContent = permission.summary;
      card.appendChild(summary);
    }

    if (permission.diff && permission.diff.length) {
      var diff = document.createElement("div");
      diff.className = "permission-diff";
      if (permission.filePath) {
        var path = document.createElement("div");
        path.className = "permission-path";
        path.textContent = permission.filePath;
        diff.appendChild(path);
      }
      permission.diff.forEach(function (line) {
        var row = document.createElement("div");
        row.className = "diff-line " + line.kind;
        var marker = line.kind === "addition" ? "+" : line.kind === "removal" ? "−" : " ";
        row.textContent = marker + " " + (line.text || " ");
        diff.appendChild(row);
      });
      card.appendChild(diff);
    }

    if (permission.canDecide === false) {
      var unavailable = document.createElement("p");
      unavailable.className = "permission-unavailable";
      unavailable.textContent = t("permission.reviewOnMac");
      card.appendChild(unavailable);
      els.conversationRows.appendChild(card);
      return;
    }

    var actions = document.createElement("div");
    actions.className = "permission-actions";
    var deny = document.createElement("button");
    deny.type = "button";
    deny.className = "deny";
    deny.textContent = t("permission.deny");
    var allow = document.createElement("button");
    allow.type = "button";
    allow.className = "allow";
    allow.textContent = t("permission.allow");
    function decide(value) {
      if (!socket || socket.readyState !== WebSocket.OPEN) { return; }
      allow.disabled = true;
      deny.disabled = true;
      socket.send(JSON.stringify({
        type: "permission",
        id: permission.id,
        decision: value,
      }));
    }
    deny.addEventListener("click", function () { decide("deny"); });
    allow.addEventListener("click", function () { decide("allow"); });
    actions.appendChild(deny);
    actions.appendChild(allow);
    card.appendChild(actions);
    els.conversationRows.appendChild(card);
  }

  function updateComposer() {
    var enabled = activeSurface === "conversation" &&
      activeCapability === "interact" && conversationCanSend &&
      socket && socket.readyState === WebSocket.OPEN;
    els.prompt.disabled = !enabled;
    els.send.disabled = !enabled || !els.prompt.value.trim();
  }

  els.prompt.addEventListener("input", function () {
    updateComposer();
    reportTyping(els.prompt.value.trim().length > 0);
  });
  els.composer.addEventListener("submit", function (event) {
    event.preventDefault();
    var text = els.prompt.value.trim();
    if (!text || els.send.disabled || !socket) { return; }
    reportTyping(false);
    socket.send(JSON.stringify({ type: "submit", text: text }));
    els.prompt.value = "";
    conversationCanSend = false;
    updateComposer();
  });

  // --- Cleanup -----------------------------------------------------------

  function closeSocket() {
    reportTyping(false);
    var closing = socket;
    socket = null;
    if (closing) { try { closing.close(); } catch (e) {} }
  }

  function disposeTerminal() {
    if (fitTimer !== null) {
      clearTimeout(fitTimer);
      fitTimer = null;
    }
    // Before the terminal goes, not after: a lease this page is no longer showing would
    // otherwise hold the Mac's grid at a size nobody is looking at until the socket closed.
    releaseViewportLease();
    if (inputSubscription) {
      inputSubscription.dispose();
      inputSubscription = null;
    }
    if (term) {
      term.dispose();
      term = null;
    }
  }

  els.back.addEventListener("click", function () {
    if (socketDiagnosticConnected) {
      recordDiagnostic("socketEnded", "info", {
        transport: "websocket",
        reason: "user",
      });
      socketDiagnosticConnected = false;
    }
    closeSocket();
    disposeTerminal();
    resetConversation();
    activeSurface = null;
    els.badge.hidden = true;
    applyTheme(hostTheme, null);
    beginSessionList();
  });

  window.addEventListener("resize", scheduleFit);

  window.addEventListener("pagehide", function () {
    cancelPoll();
    closeSocket();
    closeThemeEvents();
  });

  recordDiagnostic("appLaunched");
  acceptConnection();
})();
