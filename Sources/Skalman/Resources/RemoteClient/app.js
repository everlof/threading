// Skalman Remote — the single-page browser client.
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
      "app.title": "Skalman Remote",
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
      "update.host": "Skalman on the Mac is out of date — update it to connect.",
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
      "guest.browser": "browser",
      "guest.defaultName": "Browser guest",
      "app.code": "Code",
      "host.defaultName": "Skalman Mac",
      "age.now": "now"
    },
    sv: {
      "app.title": "Skalman Fjärråtkomst",
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
      "update.host": "Skalman på Mac-datorn är inaktuell — uppdatera appen för att ansluta.",
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
      "guest.browser": "webbläsare",
      "guest.defaultName": "Webbläsargäst",
      "app.code": "Kod",
      "host.defaultName": "Skalman på Mac",
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
  var tokenStorageKey = "skalman.capability";
  var membershipStorageKey = "skalman.membership";
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

  var deviceKey = "skalman.device";
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
      "X-Skalman-Device": deviceID,
      "X-Skalman-Protocol": String(PROTOCOL.version),
      "X-Skalman-Protocol-Min": String(PROTOCOL.minimum),
    };
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
        setStatus(t("invitation.invalid"));
        return;
      }
      if (!res.ok) {
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
        beginSessionList();
      });
    }).catch(function () {
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
        setStatus(t("mac.retrying"));
        scheduleSessionLoad(generation, 3000);
        return;
      }
      return res.json().then(function (body) {
        if (generation === sessionListGeneration) { renderSessions(body); }
      });
    }).catch(function () {
      if (generation !== sessionListGeneration) { return; }
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
        fontSize: 13,
        theme: xtermTheme(activeTerminalTheme),
      });
      term.open(els.terminal);
    }
    show("terminal");
  }

  function handleServerMessage(msg, openedSocket) {
    switch (msg.type) {
      case "hello":
        if (msg.theme) { hostTheme = msg.theme; }
        applyTheme(msg.theme || hostTheme, msg.terminalTheme || activeTerminalTheme);
        activateSurface(msg.surface);
        if (msg.cols && msg.rows && term) { term.resize(msg.cols, msg.rows); }
        if (msg.title) { els.title.textContent = msg.title; }
        setCapability(msg.capability, openedSocket);
        break;
      case "resize":
        if (msg.cols && msg.rows && term) { term.resize(msg.cols, msg.rows); }
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
    closeSocket();
    disposeTerminal();
    resetConversation();
    activeSurface = null;
    els.badge.hidden = true;
    applyTheme(hostTheme, null);
    beginSessionList();
  });

  window.addEventListener("pagehide", function () {
    cancelPoll();
    closeSocket();
    closeThemeEvents();
  });

  acceptConnection();
})();
