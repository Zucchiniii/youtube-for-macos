import Foundation

/// The JavaScript injected into youtube.com.
///
/// Two things matter here. First, skipping runs inside the page: the segment
/// list and preferences are pushed in once per video, so no message crosses into
/// Swift on the hot path. Second, the page is expensive enough at 4K that this
/// script must stay nearly free — so it is event driven. Skips ride YouTube's
/// own `timeupdate`, DOM cleanup runs from a throttled MutationObserver, and
/// nothing polls `querySelectorAll` on a timer.
enum PageScript {

    static let source = """
    (function () {
      if (window.__ytplus) { return; }

      var post = function (payload) {
        try { window.webkit.messageHandlers.ytplus.postMessage(payload); } catch (e) {}
      };

      // ---- Stop ads being scheduled at all --------------------------------
      //
      // Blocking ad requests at the network layer is not enough: the player
      // still reserves the ad slot from its player response and then sits on a
      // black screen buffering a video that will never arrive, for about as
      // long as the ad would have run. So the ad placements are removed from
      // the response before YouTube's own code ever reads them.
      //
      // Only a handful of top-level keys are touched, and the JSON hook checks
      // them with `in` rather than walking the object, so it costs nothing on
      // the thousands of unrelated parses the page does.
      var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots',
                     'adBreakHeartbeatParams', 'adParams', 'adPlacementRenderer'];

      function stripAdFields(obj) {
        if (!obj || typeof obj !== 'object') { return obj; }
        for (var i = 0; i < AD_KEYS.length; i++) {
          if (AD_KEYS[i] in obj) {
            try { delete obj[AD_KEYS[i]]; } catch (e) {}
          }
        }
        if (obj.playerResponse) { stripAdFields(obj.playerResponse); }
        if (obj.response) { stripAdFields(obj.response); }

        // The walk below is only worth doing on feed-shaped payloads. The page
        // parses JSON constantly, and most of it has no item lists at all.
        if (obj.contents || obj.continuationContents || obj.onResponseReceivedActions ||
            obj.onResponseReceivedEndpoints || obj.onResponseReceivedCommands) {
          pruneAdItems(obj);
        }
        return obj;
      }

      // Feed ads have to go before the grid is built, not after.
      //
      // Hiding an ad in the DOM leaves the cell YouTube already allotted to it,
      // and a rich-grid row keeps a fixed number of cells — so a hidden ad shows
      // as blank space to the right and the row never refills. Dropping the item
      // from the response means the row is laid out without it in the first place.
      //
      // Items are matched on the shape of their renderer key rather than an
      // exact list, since YouTube renames these regularly.
      var AD_ITEM_KEY = /(adSlot|displayAd|inFeedAd|promotedSparkles|promotedVideo|compactPromotedVideo|statementBanner|bannerPromo|adsEngagementPanel|adLayout)/i;
      var LIST_KEYS = ['contents', 'items', 'continuationItems'];

      function itemRendererKeys(item) {
        var keys = Object.keys(item);
        var nested = item.richItemRenderer || item.richSectionRenderer;
        if (nested && nested.content) { keys = keys.concat(Object.keys(nested.content)); }
        return keys;
      }

      function isAdItem(item) {
        if (!item || typeof item !== 'object') { return false; }
        var keys = itemRendererKeys(item);
        for (var i = 0; i < keys.length; i++) {
          if (AD_ITEM_KEY.test(keys[i])) { return true; }
        }
        return false;
      }

      function pruneAdItems(node, depth) {
        depth = depth || 0;
        if (!node || typeof node !== 'object' || depth > 8) { return; }

        for (var i = 0; i < LIST_KEYS.length; i++) {
          var list = node[LIST_KEYS[i]];
          if (!Array.isArray(list) || !list.length) { continue; }
          var kept = [];
          for (var j = 0; j < list.length; j++) {
            if (!isAdItem(list[j])) { kept.push(list[j]); }
          }
          if (kept.length !== list.length) {
            try { node[LIST_KEYS[i]] = kept; } catch (e) {}
          }
        }

        for (var key in node) {
          var value = node[key];
          if (value && typeof value === 'object') { pruneAdItems(value, depth + 1); }
        }
      }

      function installAdStripper() {
        var nativeParse = JSON.parse;
        JSON.parse = function (text, reviver) {
          var value = nativeParse.call(this, text, reviver);
          return options.blockAds ? stripAdFields(value) : value;
        };

        if (window.Response && window.Response.prototype &&
            window.Response.prototype.json) {
          var nativeJSON = window.Response.prototype.json;
          window.Response.prototype.json = function () {
            var self = this;
            return nativeJSON.apply(self, arguments).then(function (value) {
              return options.blockAds ? stripAdFields(value) : value;
            });
          };
        }

        // The first video and the first feed on a cold load arrive as object
        // literals in the HTML rather than through JSON.parse.
        ['ytInitialPlayerResponse', 'ytInitialData'].forEach(function (name) {
          try {
            var initial;
            Object.defineProperty(window, name, {
              configurable: true,
              get: function () { return initial; },
              set: function (value) {
                initial = options.blockAds ? stripAdFields(value) : value;
              }
            });
          } catch (e) {}
        });
      }



      var segments = [];
      var options = {
        enabled: true, showNotice: true, noticeSeconds: 5, allowUnskip: true,
        showBar: true, showPanel: true, blockAds: true, hideShorts: false,
        quality: 'best'
      };
      installAdStripper();

      // Command-arrow is back/forward, except while typing — so focus changes
      // on inputs are reported to the app.
      function isEditable(node) {
        if (!node) { return false; }
        var name = node.nodeName;
        return name === 'INPUT' || name === 'TEXTAREA' || node.isContentEditable === true;
      }
      document.addEventListener('focusin', function (e) {
        post({ type: 'focus', editing: isEditable(e.target) });
      }, true);
      document.addEventListener('focusout', function () {
        post({ type: 'focus', editing: false });
      }, true);

      var suppressed = {};
      var currentVideo = null;
      var segmentsLoaded = false;
      var panelInserts = 0;
      var panelEl = null;
      var panelError = '';
      var sweepStep = 'none';
      var sweepError = '';
      var noticeTimer = null;

      function player() { return document.getElementById('movie_player'); }
      function media() {
        return document.querySelector('video.html5-main-video') || document.querySelector('video');
      }

      function humanDuration(seconds) {
        var total = Math.round(seconds);
        if (total < 60) { return total + 's'; }
        var m = Math.floor(total / 60), s = total % 60;
        if (m < 60) { return m + 'm ' + s + 's'; }
        return Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
      }

      function timecode(seconds) {
        var total = Math.max(0, Math.round(seconds));
        var h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
        var mm = (h > 0 && m < 10 ? '0' : '') + m;
        return (h > 0 ? h + ':' : '') + mm + ':' + (s < 10 ? '0' : '') + s;
      }

      // ---- Styling ---------------------------------------------------------
      var style = document.createElement('style');
      style.textContent = [
        '.ytplus-card{position:absolute;right:16px;bottom:76px;z-index:2000;display:flex;',
        'align-items:center;gap:10px;padding:10px 12px;border-radius:12px;',
        'background:rgba(28,28,30,.92);backdrop-filter:blur(20px);color:#fff;',
        'font:500 13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;',
        'box-shadow:0 8px 28px rgba(0,0,0,.5);animation:ytplus-pop .18s ease-out;}',
        '@keyframes ytplus-pop{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}',
        '.ytplus-dot{width:9px;height:9px;border-radius:50%;flex:0 0 auto;}',
        '.ytplus-sub{opacity:.6;font-weight:400;font-size:11px;}',
        '.ytplus-card button{all:unset;cursor:pointer;padding:5px 9px;border-radius:7px;',
        'background:rgba(255,255,255,.14);font-size:12px;font-weight:600;transition:background .12s;}',
        '.ytplus-card button:hover{background:rgba(255,255,255,.28);}',
        '.ytplus-skip{border:1.5px solid var(--ytplus-colour,#0d6)!important;',
        'background:rgba(255,255,255,.1)!important;}',
        '.ytplus-mark{position:absolute;top:0;height:100%;z-index:40;pointer-events:none;opacity:.9;}',
        '.ytplus-panel{margin:0 0 16px;padding:12px 14px;border-radius:12px;',
        'background:var(--yt-spec-badge-chip-background,rgba(255,255,255,.08));',
        'font-family:"Roboto","Arial",sans-serif;color:var(--yt-spec-text-primary,#fff);}',
        '.ytplus-panel h3{margin:0;font-size:14px;font-weight:600;display:flex;align-items:center;gap:8px;}',
        '.ytplus-panel .ytplus-count{opacity:.6;font-weight:400;font-size:12px;}',
        '.ytplus-row{display:flex;align-items:center;gap:10px;padding:6px 0;font-size:13px;}',
        '.ytplus-row .ytplus-time{opacity:.7;font-variant-numeric:tabular-nums;}',
        '.ytplus-row .ytplus-action{margin-left:auto;opacity:.55;font-size:12px;}',
        '.ytplus-row a{color:var(--yt-spec-call-to-action,#3ea6ff);cursor:pointer;font-size:12px;}',
        '.ytplus-empty{opacity:.6;font-size:12px;padding-top:6px;}'
      ].join('');
      (document.head || document.documentElement).appendChild(style);

      // ---- Which video are we on? -----------------------------------------
      function videoIdFromLocation() {
        var match = location.href.match(/[?&]v=([\\w-]{11})/);
        if (match) { return match[1]; }
        var shorts = location.pathname.match(/^\\/shorts\\/([\\w-]{11})/);
        return shorts ? shorts[1] : null;
      }

      function checkVideoChanged() {
        var id = videoIdFromLocation();
        if (id === currentVideo) { return; }
        currentVideo = id;
        qualityAppliedFor = null;
        segments = [];
        segmentsLoaded = false;
        suppressed = {};
        removeCard();
        clearMarks();
        panelEl = null;
        renderPanel();
        post({ type: 'video', id: id, title: document.title });
      }

      // YouTube is a single-page app; these are the events it fires on navigation.
      ['yt-navigate-finish', 'yt-page-data-updated', 'popstate'].forEach(function (name) {
        window.addEventListener(name, checkVideoChanged, true);
      });

      // ---- Marks on YouTube's own scrub bar --------------------------------
      function clearMarks() {
        var old = document.querySelectorAll('.ytplus-mark');
        for (var i = 0; i < old.length; i++) { old[i].remove(); }
      }

      function drawMarks() {
        var bar = document.querySelector('.ytp-progress-bar');
        var v = media();
        if (!bar || !v || !isFinite(v.duration) || v.duration <= 0) { return; }
        if (!options.showBar || !options.enabled) { clearMarks(); return; }

        var signature = segments.length + ':' + Math.round(v.duration);
        if (bar.getAttribute('data-ytplus') === signature) { return; }
        bar.setAttribute('data-ytplus', signature);
        clearMarks();

        for (var i = 0; i < segments.length; i++) {
          var s = segments[i];
          if (s.full || s.action === 'ignore') { continue; }
          var mark = document.createElement('div');
          mark.className = 'ytplus-mark';
          mark.style.left = (Math.max(0, Math.min(1, s.start / v.duration)) * 100) + '%';
          mark.style.width = s.poi ? '0.4%'
            : Math.max(0.25, ((s.end - s.start) / v.duration) * 100) + '%';
          mark.style.background = s.colour;
          bar.appendChild(mark);
        }
      }

      // ---- Cards over the video -------------------------------------------
      function removeCard() {
        var existing = document.querySelector('.ytplus-card');
        if (existing) { existing.remove(); }
        if (noticeTimer) { clearTimeout(noticeTimer); noticeTimer = null; }
      }

      function makeCard(segment) {
        var host = player();
        if (!host) { return null; }
        removeCard();
        var card = document.createElement('div');
        card.className = 'ytplus-card';
        var dot = document.createElement('span');
        dot.className = 'ytplus-dot';
        dot.style.background = segment.colour;
        card.appendChild(dot);
        host.appendChild(card);
        return card;
      }

      function showNotice(segment, restoreTime, saved) {
        if (!options.showNotice) { return; }
        var card = makeCard(segment);
        if (!card) { return; }

        var text = document.createElement('span');
        text.appendChild(document.createTextNode('Skipped ' + segment.label.toLowerCase()));
        text.appendChild(document.createElement('br'));
        var savedLine = document.createElement('span');
        savedLine.className = 'ytplus-sub';
        savedLine.textContent = 'Saved ' + humanDuration(saved);
        text.appendChild(savedLine);
        card.appendChild(text);

        if (options.allowUnskip) {
          var undo = document.createElement('button');
          undo.textContent = 'Unskip';
          undo.onclick = function () {
            suppressed[segment.uuid] = true;
            var v = media();
            if (v) { v.currentTime = restoreTime; }
            post({ type: 'unskipped', saved: saved });
            removeCard();
          };
          card.appendChild(undo);
        }

        var up = document.createElement('button');
        up.textContent = '👍';
        up.title = 'This segment is correct';
        up.onclick = function () { post({ type: 'vote', uuid: segment.uuid, up: true }); removeCard(); };
        card.appendChild(up);

        var down = document.createElement('button');
        down.textContent = '👎';
        down.title = 'This segment is wrong';
        down.onclick = function () { post({ type: 'vote', uuid: segment.uuid, up: false }); removeCard(); };
        card.appendChild(down);

        noticeTimer = setTimeout(removeCard, Math.max(1, options.noticeSeconds) * 1000);
      }

      var manualShownFor = null;

      function showSkipButton(segment) {
        if (manualShownFor === segment.uuid) { return; }
        manualShownFor = segment.uuid;
        var card = makeCard(segment);
        if (!card) { return; }
        card.style.setProperty('--ytplus-colour', segment.colour);

        var button = document.createElement('button');
        button.className = 'ytplus-skip';
        button.textContent = 'Skip ' + segment.label.toLowerCase();
        button.onclick = function () {
          var v = media();
          if (!v) { return; }
          var saved = Math.max(0, segment.end - v.currentTime);
          v.currentTime = segment.end + 0.05;
          post({ type: 'skipped', uuid: segment.uuid, saved: saved });
          removeCard();
        };
        card.appendChild(button);
      }

      // ---- Segment list under the video ------------------------------------
      //
      // It sits between the description and the comments. insertBefore throws
      // unless the reference node is a direct child, so each candidate is paired
      // with its own real parent rather than assuming a fixed nesting depth.
      function panelAnchor() {
        var comments = document.querySelector('#comments');
        if (comments && comments.parentNode) {
          return { parent: comments.parentNode, before: comments };
        }
        var metadata = document.querySelector('ytd-watch-metadata');
        if (metadata && metadata.parentNode) {
          return { parent: metadata.parentNode, before: metadata.nextSibling };
        }
        var below = document.querySelector('#below');
        if (below && below.parentNode) {
          return { parent: below.parentNode, before: below };
        }
        return null;
      }

      function renderPanel() {
        var existing = document.querySelector('.ytplus-panel');
        if (existing) { existing.remove(); }
        panelEl = null;
        if (!options.showPanel || !options.enabled || !currentVideo) { return; }

        var spot = panelAnchor();
        if (!spot) { return; }

        var panel = document.createElement('div');
        panel.className = 'ytplus-panel';

        var heading = document.createElement('h3');
        heading.appendChild(document.createTextNode('⏭ SponsorBlock'));
        var count = document.createElement('span');
        count.className = 'ytplus-count';
        count.textContent = segments.length === 1 ? '1 segment'
                                                  : segments.length + ' segments';
        heading.appendChild(count);
        panel.appendChild(heading);

        if (!segments.length) {
          var empty = document.createElement('div');
          empty.className = 'ytplus-empty';
          empty.textContent = segmentsLoaded
            ? 'No segments submitted for this video.'
            : 'Checking SponsorBlock…';
          panel.appendChild(empty);
        }

        for (var i = 0; i < segments.length; i++) {
          (function (s) {
            var row = document.createElement('div');
            row.className = 'ytplus-row';

            var dot = document.createElement('span');
            dot.className = 'ytplus-dot';
            dot.style.background = s.colour;
            row.appendChild(dot);

            var label = document.createElement('span');
            label.textContent = s.label;
            row.appendChild(label);

            var time = document.createElement('span');
            time.className = 'ytplus-time';
            time.textContent = s.full ? 'whole video'
              : timecode(s.start) + ' – ' + timecode(s.end);
            row.appendChild(time);

            var action = document.createElement('span');
            action.className = 'ytplus-action';
            action.textContent = s.actionLabel;
            row.appendChild(action);

            if (!s.full) {
              var jump = document.createElement('a');
              jump.textContent = 'Jump';
              jump.onclick = function () {
                var v = media();
                if (v) { v.currentTime = s.start; }
              };
              row.appendChild(jump);
            }
            panel.appendChild(row);
          })(segments[i]);
        }

        try {
          spot.parent.insertBefore(panel, spot.before);
          panelEl = panel;
          panelInserts++;
        } catch (e) {
          panelError = String(e).slice(0, 60);
        }
      }

      // ---- Skipping, driven by the player's own clock ----------------------
      var mutedBySegment = false;

      function onTimeUpdate() {
        var v = media();
        if (!v) { return; }
        var p = player();
        var showingAd = !!(p && p.classList && p.classList.contains('ad-showing'));

        var report = { type: 'state', playing: !v.paused && !v.ended,
                       time: v.currentTime || 0, ad: showingAd };
        if (window.__ytplusDebug) {
          report.diag = {
                 panel: !!document.querySelector('.ytplus-panel'),
                 below: !!document.querySelector('#below'),
                 segs: segments.length,
                 loaded: segmentsLoaded,
                 showPanel: !!options.showPanel,
                 inserts: panelInserts,
                 panelError: panelError,
                 step: sweepStep,
                 sweepError: sweepError,
                 enabled: !!options.enabled,
            video: currentVideo,
            ad: showingAd,
            adJumps: adJumps,
            rate: v.playbackRate
          };
        }
        post(report);

        if (showingAd || !options.enabled) { return; }

        var time = v.currentTime;
        var active = null;
        for (var i = 0; i < segments.length; i++) {
          var s = segments[i];
          if (s.full || s.poi || suppressed[s.uuid] || s.action === 'ignore' ||
              s.action === 'showOnly') { continue; }
          if (time >= s.start && time < s.end) { active = s; break; }
        }

        if (!active) {
          if (mutedBySegment) { mutedBySegment = false; v.muted = false; }
          if (manualShownFor) { manualShownFor = null; removeCard(); }
          return;
        }

        if (active.action === 'skip') {
          var saved = Math.max(0, active.end - time);
          v.currentTime = active.end + 0.05;
          post({ type: 'skipped', uuid: active.uuid, saved: saved });
          showNotice(active, time, saved);
        } else if (active.action === 'mute') {
          if (!mutedBySegment) { mutedBySegment = true; v.muted = true; }
        } else if (active.action === 'manual') {
          showSkipButton(active);
        }
      }

      // Attaches to whichever <video> the page currently has.
      var wiredVideo = null;
      function wireVideo() {
        var v = media();
        if (!v || v === wiredVideo) { return; }
        wiredVideo = v;
        v.addEventListener('timeupdate', onTimeUpdate);
        v.addEventListener('loadedmetadata', function () {
          var bar = document.querySelector('.ytp-progress-bar');
          if (bar) { bar.removeAttribute('data-ytplus'); }
          drawMarks();
        });
      }

      // ---- Quality ---------------------------------------------------------
      //
      // getAvailableQualityLevels() returns the rungs this video actually has,
      // highest first. Asking for one it does not offer is ignored, so the
      // request falls back to the best on offer.
      //
      // Note that YouTube's "1080p Premium" (enhanced bitrate) is not a rung a
      // client can select: it is a paid entitlement the server grants, and it
      // simply is not present here for accounts without it.
      var qualityAppliedFor = null;

      function applyQuality() {
        if (options.quality === 'auto') { return; }
        if (qualityAppliedFor === currentVideo) { return; }

        var p = player();
        if (!p || !p.getAvailableQualityLevels || !p.setPlaybackQualityRange) { return; }
        var levels = p.getAvailableQualityLevels();
        if (!levels || !levels.length) { return; }

        var target = options.quality === 'best' ? levels[0]
                   : (levels.indexOf(options.quality) !== -1 ? options.quality : levels[0]);
        try {
          p.setPlaybackQualityRange(target, target);
          qualityAppliedFor = currentVideo;
        } catch (e) {}
      }

      // ---- Ads -------------------------------------------------------------
      var adSelectors = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, ' +
                        '.ytp-skip-ad-button, .ytp-ad-overlay-close-button';
      var lastAdJump = 0;
      var adJumps = 0;
      var adAttempts = 0;
      var adActive = false;
      var userMuted = false;
      var userRate = 1;

      function handleAds() {
        if (!options.blockAds) { return; }

        var button = document.querySelector(adSelectors);
        if (button && button.offsetParent !== null) {
          try { button.click(); } catch (e) {}
        }

        var p = player();
        var v = media();
        var showingAd = !!(p && p.classList && p.classList.contains('ad-showing'));

        if (!showingAd) {
          // Ad over: put playback back the way the user had it.
          if (adActive && v) {
            try { v.muted = userMuted; v.playbackRate = userRate; } catch (e) {}
          }
          adActive = false;
          lastAdJump = 0;
          return;
        }

        if (!adActive) {
          adActive = true;
          adAttempts = 0;
          userMuted = v ? v.muted : false;
          userRate = (v && v.playbackRate && v.playbackRate <= 4) ? v.playbackRate : 1;
        }
        if (!v) { return; }

        // Two ways out, because YouTube defends against each one differently.
        // Seeking to the end is instant when it is allowed; when the player
        // clamps it back, running the ad at 16× clears it in about a second.
        // Both are cheap, and the throttle keeps currentTime writes from making
        // the player re-buffer.
        try { v.muted = true; } catch (e) {}
        if (v.playbackRate < 16) {
          try { v.playbackRate = 16; } catch (e) {}
        }

        // Give up after a few attempts. If YouTube is clamping the seek there
        // is nothing further to gain, and retrying twice a second just makes
        // the player re-buffer.
        var now = Date.now();
        if (adAttempts < 6 && isFinite(v.duration) && v.duration > 0 &&
            v.currentTime < v.duration - 0.4 && now - lastAdJump > 1500) {
          lastAdJump = now;
          adAttempts++;
          adJumps++;
          try { v.currentTime = v.duration; } catch (e) {}
        }
      }

      // ---- Premium upsells and other overlays ------------------------------
      var promoRenderers = [
        'yt-mealbar-promo-renderer', 'ytd-mealbar-promo-renderer',
        'yt-upsell-dialog-renderer', 'ytd-enforcement-message-view-model'
      ].join(', ');

      var premiumWords = ['premium', 'ad-free', 'ad free', 'utan reklam', 'reklamfri',
                          'try it free', 'month free', 'ad blocker', 'annonsblock'];

      function looksLikePremium(node) {
        var text = (node.innerText || '').toLowerCase();
        if (!text) { return false; }
        for (var i = 0; i < premiumWords.length; i++) {
          if (text.indexOf(premiumWords[i]) !== -1) { return true; }
        }
        return false;
      }

      function pressDismiss(scope) {
        var buttons = scope.querySelectorAll('#dismiss-button, button, tp-yt-paper-button, yt-button-shape');
        for (var i = 0; i < buttons.length; i++) {
          var label = (buttons[i].innerText || buttons[i].getAttribute('aria-label') || '').toLowerCase();
          if (label.indexOf('no thanks') !== -1 || label.indexOf('dismiss') !== -1 ||
              label.indexOf('not now') !== -1 || label.indexOf('nej tack') !== -1 ||
              label.indexOf('close') !== -1) {
            try { buttons[i].click(); return true; } catch (e) {}
          }
        }
        return false;
      }

      function dismissPromos() {
        var known = document.querySelectorAll(promoRenderers);
        for (var i = 0; i < known.length; i++) {
          pressDismiss(known[i]);
          known[i].remove();
        }

        // Modal dialogs are only touched when they are actually a Premium
        // pitch, so playlist, sign-in and settings dialogs are left alone.
        var dialogs = document.querySelectorAll('tp-yt-paper-dialog, yt-confirm-dialog-renderer');
        var removed = false;
        for (var j = 0; j < dialogs.length; j++) {
          if (!looksLikePremium(dialogs[j])) { continue; }
          pressDismiss(dialogs[j]);
          dialogs[j].remove();
          removed = true;
        }
        if (removed) {
          var backdrops = document.querySelectorAll('tp-yt-iron-overlay-backdrop');
          for (var k = 0; k < backdrops.length; k++) { backdrops[k].remove(); }
          document.body.style.overflow = '';
        }

        if (!options.blockAds) { return; }

        // Removing the ad itself leaves its grid cell or shelf behind as a blank
        // gap, so the wrapper YouTube laid out for it goes too.
        var wrappers = 'ytd-rich-item-renderer, ytd-rich-section-renderer, ' +
                       'ytd-item-section-renderer, ytd-compact-video-renderer, ' +
                       '#player-ads, ytd-merch-shelf-renderer';
        var junk = document.querySelectorAll(
          '.ytp-ad-overlay-slot, .ytp-ad-overlay-container, #player-ads, ' +
          'ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ' +
          'ytd-display-ad-renderer, ytd-companion-slot-renderer, ' +
          'ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer, ' +
          'ytd-statement-banner-renderer, ytd-brand-video-shelf-renderer');
        var removed = 0;
        for (var n = 0; n < junk.length; n++) {
          var host = junk[n].closest(wrappers);
          (host || junk[n]).remove();
          removed++;
        }

        // A rich-grid row keeps a fixed cell count, so pulling a cell out leaves
        // a hole. The grid re-chunks its rows on resize, which closes it.
        if (removed) {
          try { window.dispatchEvent(new Event('resize')); } catch (e) {}
        }
      }

      // ---- Static CSS for things we always hide ----------------------------
      var hideStyle = document.createElement('style');
      function refreshHideStyle() {
        var rules = [
          'yt-mealbar-promo-renderer, ytd-mealbar-promo-renderer, yt-upsell-dialog-renderer',
          '{display:none!important}',
          'ytd-guide-entry-renderer:has(a[href*="/premium"]),',
          'ytd-mini-guide-entry-renderer:has(a[href*="/premium"]),',
          'ytd-button-renderer:has(a[href*="/premium"]){display:none!important}'
        ];
        if (options.hideShorts) {
          rules.push('ytd-reel-shelf-renderer, ytd-rich-shelf-renderer[is-shorts],');
          rules.push('ytd-guide-entry-renderer:has(a[title="Shorts"]),');
          rules.push('ytd-mini-guide-entry-renderer:has(a[title="Shorts"]){display:none!important}');
        }
        if (options.blockAds) {
          rules.push('#player-ads, #masthead-ad, ytd-ad-slot-renderer,');
          rules.push('ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer,');
          rules.push('ytd-companion-slot-renderer, .ytp-ad-overlay-slot,');
          rules.push('ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer,');
          rules.push('ytd-statement-banner-renderer{display:none!important}');
          // Collapse the container an ad was laid out in, not just the ad.
          rules.push('ytd-rich-item-renderer:has(ytd-ad-slot-renderer),');
          rules.push('ytd-rich-item-renderer:has(ytd-display-ad-renderer),');
          rules.push('ytd-rich-item-renderer:has(ytd-in-feed-ad-layout-renderer),');
          rules.push('ytd-rich-section-renderer:has(ytd-statement-banner-renderer),');
          rules.push('ytd-item-section-renderer:has(ytd-ad-slot-renderer),');
          rules.push('ytd-compact-video-renderer:has(ytd-ad-slot-renderer),');
          rules.push('ytd-rich-item-renderer:empty, ytd-rich-section-renderer:empty');
          rules.push('{display:none!important}');
        }
        hideStyle.textContent = rules.join(' ');
        if (!hideStyle.parentNode) {
          (document.head || document.documentElement).appendChild(hideStyle);
        }
      }

      // ---- One throttled observer instead of a polling loop ----------------
      var pending = false;
      function scheduleSweep() {
        if (pending) { return; }
        pending = true;
        setTimeout(function () {
          pending = false;
          sweepStep = 'start';
          try {
            checkVideoChanged(); sweepStep = 'video';
            wireVideo(); sweepStep = 'wire';
            handleAds(); sweepStep = 'ads';
            applyQuality(); sweepStep = 'quality';
            dismissPromos(); sweepStep = 'promos';
            drawMarks(); sweepStep = 'marks';
          } catch (e) {
            sweepError = sweepStep + ': ' + String(e).slice(0, 70);
          }
          // YouTube rebuilds #below as it navigates, which takes the panel
          // with it, so put it back whenever it has gone missing.
          try {
            if (currentVideo && options.showPanel && options.enabled) {
              if (panelEl && !panelEl.isConnected) {
                // YouTube detached it during a re-render. Putting the existing
                // node back costs far less than rebuilding the whole list, and
                // this happens roughly once a second while watching.
                var spot = panelAnchor();
                if (spot) { spot.parent.insertBefore(panelEl, spot.before); }
              } else if (!panelEl) {
                renderPanel();
              }
              sweepStep = 'panel';
            }
          } catch (e) {
            sweepError = 'panel: ' + String(e).slice(0, 70);
          }
        }, 300);
      }

      new MutationObserver(scheduleSweep)
        .observe(document.documentElement, { childList: true, subtree: true });

      setInterval(scheduleSweep, 1000);

      // ---- Swift entry points ---------------------------------------------
      window.__ytplus = {
        setSegments: function (list) {
          segments = list || [];
          segmentsLoaded = true;
          suppressed = {};
          manualShownFor = null;
          var bar = document.querySelector('.ytp-progress-bar');
          if (bar) { bar.removeAttribute('data-ytplus'); }
          drawMarks();
          renderPanel();
        },
        setOptions: function (next) {
          var previousQuality = options.quality;
          for (var key in next) { options[key] = next[key]; }
          if (options.quality !== previousQuality) { qualityAppliedFor = null; }
          refreshHideStyle();
          var bar = document.querySelector('.ytp-progress-bar');
          if (bar) { bar.removeAttribute('data-ytplus'); }
          drawMarks();
          renderPanel();
        },
        seek: function (seconds) {
          var v = media();
          if (v) { v.currentTime = seconds; }
        },
        togglePlay: function () {
          var p = player();
          var v = media();
          if (!v) { return; }
          if (v.paused) { p && p.playVideo ? p.playVideo() : v.play(); }
          else { p && p.pauseVideo ? p.pauseVideo() : v.pause(); }
        }
      };

      refreshHideStyle();
      scheduleSweep();
    })();
    """
}
