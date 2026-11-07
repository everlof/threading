import Foundation

/// The portal's two static files. Pages name them with `?v=` and this hash of their content, so
/// a browser that cached the old ones fetches the new ones after an upgrade.
enum PortalAssets {
    static let version: String = {
        // FNV-1a: stable across launches, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (PortalStyle.css + PortalScript.js).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }()
}

/// Phone first: one column, 44-point touch targets, 16-pixel inputs so iOS Safari does not zoom,
/// and a conversation laid out as messages, the person's on the right.
enum PortalStyle {
    static let css = """
        :root{color-scheme:light dark;--bg:#f4f6f8;--card:#fff;--ink:#17212b;--quiet:#55636f;--line:#d5dde3;\
        --accent:#0b5c78;--accent-ink:#fff;--soft:#e4eef2;--mine:#dcebf1;--ok:#1d6b4c;--warn:#7a5310;--bad:#9b2c25}
        @media (prefers-color-scheme:dark){:root{--bg:#12171c;--card:#1b2229;--ink:#e6edf2;--quiet:#9aa8b4;\
        --line:#2e3943;--accent:#5bb6d6;--accent-ink:#0b1a20;--soft:#22303a;--mine:#1d3a47;--ok:#6fcf9f;--warn:#e3b45c;--bad:#f08a80}}
        *{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
        body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
        header{display:flex;gap:8px 16px;align-items:center;justify-content:space-between;max-width:760px;margin:0 auto;\
        padding:14px 16px}
        .brand{font-weight:700;letter-spacing:-.01em;color:inherit;text-decoration:none}
        .who{color:var(--quiet);font-size:.9rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
        main{max-width:760px;margin:0 auto;padding:0 16px 24px}
        footer{max-width:760px;margin:0 auto;padding:8px 16px 32px;color:var(--quiet);font-size:.85rem}
        .language{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px}
        h1{font-size:1.45rem;line-height:1.25;margin:.3em 0}h2{font-size:1.1rem;margin:1.2em 0 .5em}
        a{color:var(--accent)}p{margin:.5em 0}.quiet,.help,.meta{color:var(--quiet)}.help{font-size:.92rem}
        .pre,.prompt{white-space:pre-wrap;overflow-wrap:anywhere}.prompt{font-size:1.05rem}
        .eyebrow{color:var(--quiet);font-size:.85rem;margin:0}
        .card,.list li{background:var(--card);border:1px solid var(--line);border-radius:14px}
        .card{padding:16px 18px;margin-top:14px}.answer h2{margin-top:0}
        .crumbs{display:flex;justify-content:space-between;gap:12px;margin:4px 0 8px}
        .crumbs a{display:inline-flex;align-items:center;min-height:44px}
        .brief{border-top:1px solid var(--line);margin-top:14px;padding-top:4px}.brief ul{padding-left:18px}
        .list{list-style:none;padding:0;margin:0;display:grid;gap:10px}
        .list li{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;padding:0}
        .list a{text-decoration:none;color:inherit;display:grid;gap:2px;min-width:0;flex:1;padding:12px 0 12px 14px;min-height:44px}
        .list .badge{margin:12px 14px 0 0}.list .title{font-weight:600;overflow-wrap:anywhere}
        .preview{color:var(--ink);font-size:.92rem;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;\
        overflow:hidden;overflow-wrap:anywhere;margin-top:2px}
        .meta{font-size:.85rem}
        .badge{font-size:.78rem;font-weight:650;border-radius:999px;padding:2px 9px;background:var(--soft);white-space:nowrap}
        .badge.open{color:var(--warn)}.badge.answered{color:var(--ok)}.badge.declined,.badge.withdrawn{color:var(--quiet)}
        .badge.new{background:var(--accent);color:var(--accent-ink)}
        .field{display:block;border:0;margin:0 0 16px;padding:0;min-width:0}
        .field legend,.field .label{font-weight:600;display:block;margin-bottom:6px;padding:0}
        .choice{display:flex;gap:12px;align-items:flex-start;padding:11px 12px;border:1px solid var(--line);border-radius:10px;\
        margin-bottom:8px;cursor:pointer;min-height:44px}.choice.compact{margin:0;flex:1 1 7em}
        .inline{display:flex;flex-wrap:wrap;gap:8px}
        .choice input{margin-top:4px;width:20px;height:20px;flex:none;accent-color:var(--accent)}
        .choice:has(input:checked){border-color:var(--accent);background:var(--soft)}
        .option{display:block;font-weight:550}.consequence{display:block;color:var(--quiet);font-size:.9rem}
        input[type=text],textarea,select{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--line);\
        border-radius:10px;padding:10px 12px;width:100%}select{width:auto;padding:6px 10px;min-height:44px}
        textarea{resize:vertical;min-height:5.5em}
        .number{display:flex;gap:8px;align-items:center}.number input{max-width:12em}
        input:focus-visible,textarea:focus-visible,select:focus-visible,button:focus-visible,a:focus-visible,\
        summary:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
        button,.button{display:inline-flex;align-items:center;justify-content:center;font:inherit;font-weight:650;\
        color:var(--accent-ink);background:var(--accent);border:0;border-radius:10px;padding:10px 18px;min-height:44px;\
        cursor:pointer;text-decoration:none}
        button.secondary{background:var(--soft);color:var(--ink)}button:disabled{opacity:.6;cursor:default}
        .disclosure>summary{cursor:pointer;font-weight:600;min-height:28px;list-style-position:inside}
        .disclosure[open]>summary{margin-bottom:12px}.quiet-disclosure>summary{color:var(--quiet);font-weight:550}
        .disclosure textarea{margin:8px 0}
        .notice,.error{border-radius:12px;padding:10px 14px;margin:12px 0}.notice{background:var(--soft)}
        .error{border:1px solid var(--bad);color:var(--bad)}
        .fresh{position:sticky;top:0;z-index:1;margin:0;padding:10px 16px;text-align:center;background:var(--accent);\
        color:var(--accent-ink)}.fresh a{color:inherit;font-weight:700}
        .conversation{margin-top:18px}
        .chat{list-style:none;padding:0;margin:0;display:flex;flex-direction:column;gap:10px}
        .msg{max-width:88%;padding:10px 14px;border-radius:16px;scroll-margin-top:16px}
        .msg.agent{align-self:flex-start;background:var(--card);border:1px solid var(--line);border-bottom-left-radius:6px}
        .msg.person{align-self:flex-end;background:var(--mine);border-bottom-right-radius:6px}
        .msg.owner{border-color:var(--accent)}.msg.closing{border:1px dashed var(--quiet)}
        .msg .who{font-size:.8rem;color:var(--quiet);margin:0 0 2px}.msg .pre{margin:0}
        .msg .kind{font-weight:650;font-size:.9rem;margin:0 0 4px}
        .tag{font-size:.72rem;font-weight:650;border:1px solid var(--line);border-radius:6px;padding:0 5px;margin-left:2px}
        .answers{margin:0 0 4px}.answers div{margin:0 0 4px}.answers dt{font-size:.85rem;color:var(--quiet)}
        .answers dd{margin:0;font-weight:550;white-space:pre-wrap;overflow-wrap:anywhere}
        .composer textarea{min-height:4.5em}.composer .field{margin-bottom:8px}
        .onward{margin-top:18px}.onward .button{background:var(--soft);color:var(--ink)}
        @media (max-width:540px){main{padding:0 12px 20px}header{padding:12px}.card{padding:14px}\
        form:not(.language)>button,.onward .button,.notice .button{width:100%}h1{font-size:1.3rem}}
        @media print{header,footer,.crumbs,.disclosure,.composer,button,.button,.fresh{display:none}\
        body{background:#fff;color:#000}.card,.msg{border-color:#999}}
        """
}

/// Optional and inert without the network: shows times in the reader's zone, sends each form
/// once, and polls the page's `state` route. When the page is out of date it reloads, unless
/// the person has started typing or choosing, in which case it shows the server-rendered
/// banner instead. It never inserts markup and reads nothing but the fingerprint.
enum PortalScript {
    static let js = """
        (function(){
        "use strict";
        var lang=document.documentElement.lang||undefined;
        var times=document.querySelectorAll("time[datetime]");
        for(var i=0;i<times.length;i++){var d=new Date(times[i].getAttribute("datetime"));
        if(!isNaN(d.getTime())){try{times[i].textContent=d.toLocaleString(lang,{dateStyle:"medium",timeStyle:"short"});}catch(e){}}}
        var forms=document.querySelectorAll("form");
        for(var f=0;f<forms.length;f++){forms[f].addEventListener("submit",function(ev){
        var form=ev.currentTarget;if(form.dataset.sent){ev.preventDefault();return;}form.dataset.sent="1";
        setTimeout(function(){var b=form.querySelectorAll("button");for(var j=0;j<b.length;j++){b[j].disabled=true;}},0);});}
        var body=document.body,poll=body.getAttribute("data-poll");if(!poll){return;}
        var version=body.getAttribute("data-version"),anchor=body.getAttribute("data-anchor")||"";
        var fresh=document.getElementById("fresh"),base=4000,delay=base,timer=null,stopped=false;
        function changed(){var a=document.activeElement;
        if(a&&/^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName)&&a.type!=="hidden"){return true;}
        var t=document.querySelectorAll("textarea,input[type=text]");for(var k=0;k<t.length;k++){if(t[k].value!==t[k].defaultValue){return true;}}
        var c=document.querySelectorAll("input[type=radio],input[type=checkbox]");for(var m=0;m<c.length;m++){if(c[m].checked!==c[m].defaultChecked){return true;}}
        return false;}
        function schedule(){if(!stopped){clearTimeout(timer);timer=setTimeout(tick,delay);}}
        function tick(){if(document.hidden){return;}
        fetch(poll,{cache:"no-store",credentials:"same-origin",headers:{"Accept":"application/json"}}).then(function(r){
        if(r.status===401||r.status===404){stopped=true;return null;}
        if(!r.ok){delay=Math.min(delay*2,60000);return null;}delay=base;return r.json();
        }).then(function(j){if(!j||typeof j.v!=="string"||j.v===version){return;}
        if(changed()){if(fresh){fresh.hidden=false;}return;}
        stopped=true;history.replaceState(null,"",location.pathname+anchor);location.reload();
        }).catch(function(){delay=Math.min(delay*2,60000);}).then(schedule);}
        document.addEventListener("visibilitychange",function(){if(!document.hidden){delay=base;clearTimeout(timer);tick();}});
        schedule();
        })();
        """
}
