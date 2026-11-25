/**
 * Seamstress Interactive macOS Desktop Playground
 * Drives the live hero sandbox using SeamstressCore (zero external dependencies).
 */
(function () {
  'use strict';

  const { LayoutTree, SeamGeometry, SpaceLayoutStore } = window.SeamstressCore;

  const workspaceEl = document.getElementById('desktop-workspace');
  const windowsLayerEl = document.getElementById('windows-layer');
  const emptySlotsLayerEl = document.getElementById('empty-slots-layer');
  const dropPreviewEl = document.getElementById('drop-preview');
  const dropPreviewBadgeEl = document.getElementById('drop-preview-badge');
  const seamOverlayEl = document.getElementById('seam-overlay');

  const snapToggleBtn = document.getElementById('snap-toggle-btn');
  const snapToggleStateEl = document.getElementById('snap-toggle-state');
  const shiftPillEl = document.getElementById('shift-pill');
  const statusReadoutEl = document.getElementById('status-readout');
  const statusTextEl = document.getElementById('status-text');
  const resetBtn = document.getElementById('reset-btn');
  const presetBtns = Array.from(document.querySelectorAll('[data-preset]'));
  const dockPills = Array.from(document.querySelectorAll('[data-dock-win]'));

  const menubarAppNameEl = document.getElementById('menubar-app-name');
  const menubarBtn = document.getElementById('menubar-seamstress-btn');
  const popoverEl = document.getElementById('menubar-popover');
  const popoverStatusEl = document.getElementById('popover-status');
  const popoverSwitchEl = document.getElementById('popover-enabled-switch');
  const minimapCanvasEl = document.getElementById('minimap-canvas');
  const minimapEqualizeBtn = document.getElementById('minimap-equalize');
  const minimapClearBtn = document.getElementById('minimap-clear');

  const WINDOWS_META = {
    1: { id: 1, name: 'Editor', short: 'Ed', minSize: { width: 185, height: 135 } },
    2: { id: 2, name: 'Terminal', short: 'sh', minSize: { width: 165, height: 125 } },
    3: { id: 3, name: 'Safari', short: 'Web', minSize: { width: 190, height: 135 } },
    4: { id: 4, name: 'Notes', short: 'Nt', minSize: { width: 155, height: 120 } },
  };

  const store = new SpaceLayoutStore();
  Object.values(WINDOWS_META).forEach((m) => store.setMinSize(m.id, m.minSize));

  let isEnabled = true;
  let snapLocked = false;
  let physicalOptionDown = false;
  let physicalCtrlCmdDown = false;
  let physicalShiftDown = false;

  let zCounter = 10;
  let focusedWindowID = 1;
  let activePreset = 'floating';

  // Window runtime state: id -> { el, badgeEl, frame, closed, zIndex }
  const windows = new Map();
  for (const id of [1, 2, 3, 4]) {
    const el = document.getElementById(`win-${id}`);
    windows.set(id, {
      id,
      el,
      badgeEl: el.querySelector('[data-badge]'),
      frame: { x: 40, y: 40, width: 360, height: 240 },
      closed: id === 4,
      zIndex: id,
    });
  }

  // Gesture checklist completion state
  const completedSteps = new Set();
  function markStep(stepKey) {
    if (completedSteps.has(stepKey)) return;
    completedSteps.add(stepKey);
    const el = document.querySelector(`[data-check="${stepKey}"]`);
    if (el) {
      el.classList.add('is-done');
      const icon = el.querySelector('.check-icon');
      if (icon) icon.textContent = '✓';
    }
  }

  function setStatus(text, tone = 'cyan') {
    statusTextEl.textContent = text;
    statusReadoutEl.classList.remove('tone-amber', 'tone-purple', 'tone-emerald');
    if (tone === 'amber') statusReadoutEl.classList.add('tone-amber');
    else if (tone === 'purple') statusReadoutEl.classList.add('tone-purple');
    else if (tone === 'emerald') statusReadoutEl.classList.add('tone-emerald');
  }

  function workspaceBounds() {
    return {
      x: 0,
      y: 0,
      width: Math.round(workspaceEl.clientWidth),
      height: Math.round(workspaceEl.clientHeight),
    };
  }

  function isSnapActive() {
    return snapLocked || physicalOptionDown || physicalCtrlCmdDown;
  }

  function updateModifierUI() {
    const active = isSnapActive();
    snapToggleBtn.classList.toggle('is-active', active);
    snapToggleBtn.setAttribute('aria-pressed', String(snapLocked));
    if (physicalOptionDown || physicalCtrlCmdDown) {
      snapToggleStateEl.textContent = 'HELD';
    } else if (snapLocked) {
      snapToggleStateEl.textContent = 'LOCKED';
    } else {
      snapToggleStateEl.textContent = 'OFF';
    }
    shiftPillEl.classList.toggle('is-active', physicalShiftDown);
  }

  function pointerInWorkspace(clientX, clientY) {
    const rect = workspaceEl.getBoundingClientRect();
    return {
      x: clientX - rect.left,
      y: clientY - rect.top,
    };
  }

  function applyWindowFrame(win, frame, animate = false) {
    win.frame = {
      x: Math.round(frame.x),
      y: Math.round(frame.y),
      width: Math.round(frame.width),
      height: Math.round(frame.height),
    };
    win.el.classList.toggle('is-animated', animate);
    win.el.style.left = `${win.frame.x}px`;
    win.el.style.top = `${win.frame.y}px`;
    win.el.style.width = `${win.frame.width}px`;
    win.el.style.height = `${win.frame.height}px`;
  }

  function syncWindowClassesAndBadges() {
    const tiledSet = new Set(store.tree.allWindowIDs);
    for (const [id, win] of windows) {
      const tiled = tiledSet.has(id);
      win.el.classList.toggle('is-tiled', tiled);
      win.el.classList.toggle('is-closed', win.closed);
      win.el.classList.toggle('is-focused', !win.closed && id === focusedWindowID);
      if (win.badgeEl) win.badgeEl.textContent = tiled ? 'Tiled' : 'Float';

      // Tiled windows sit below floating windows in Z-order
      const baseZ = tiled ? 5 : 15;
      win.el.style.zIndex = String(baseZ + win.zIndex);
    }

    // Update Dock pills
    for (const pill of dockPills) {
      const id = Number(pill.dataset.dockWin);
      const win = windows.get(id);
      const tiled = tiledSet.has(id);
      pill.classList.toggle('is-closed', win.closed);
      pill.classList.toggle('is-open', !win.closed);
      pill.classList.toggle('is-tiled', !win.closed && tiled);
    }

    const activeWin = windows.get(focusedWindowID);
    if (activeWin && !activeWin.closed) {
      menubarAppNameEl.textContent = WINDOWS_META[focusedWindowID].name;
    }

    renderEmptySlots();
    renderMinimapAndPopover();
  }

  function focusWindow(id) {
    const win = windows.get(id);
    if (!win || win.closed) return;
    focusedWindowID = id;
    zCounter += 1;
    win.zIndex = zCounter;
    syncWindowClassesAndBadges();
  }

  function renderEmptySlots() {
    const bounds = workspaceBounds();
    emptySlotsLayerEl.innerHTML = '';
    if (store.tree.isEmpty) return;

    const placements = store.tree.leafPlacements(bounds);
    for (const leaf of placements) {
      if (!leaf.isEmpty) continue;
      const box = document.createElement('div');
      box.className = 'empty-slot-box';
      box.style.left = `${leaf.frame.x}px`;
      box.style.top = `${leaf.frame.y}px`;
      box.style.width = `${leaf.frame.width}px`;
      box.style.height = `${leaf.frame.height}px`;
      box.innerHTML =
        '<div class="empty-slot-inner"><strong>Empty Slot</strong><span>⌥-drag here to fill · 2× click seam to collapse</span></div>';
      emptySlotsLayerEl.appendChild(box);
    }
  }

  function renderMinimapAndPopover() {
    const tiledCount = store.tree.allWindowIDs.length;
    popoverSwitchEl.classList.toggle('is-on', isEnabled);
    popoverSwitchEl.setAttribute('aria-checked', String(isEnabled));
    menubarBtn.classList.toggle('is-paused', !isEnabled);

    if (!isEnabled) {
      popoverStatusEl.textContent = 'Paused';
      popoverStatusEl.classList.add('is-paused');
    } else {
      popoverStatusEl.classList.remove('is-paused');
      popoverStatusEl.textContent =
        tiledCount === 0 ? 'Active · no tiled windows' : `Active · ${tiledCount} tiled`;
    }

    minimapEqualizeBtn.disabled = !store.tree.hasNonEqualSplits();
    minimapClearBtn.disabled = tiledCount === 0;

    const bounds = workspaceBounds();
    minimapCanvasEl.innerHTML = '';
    if (store.tree.isEmpty || bounds.width <= 1 || bounds.height <= 1) {
      minimapCanvasEl.innerHTML = '<div class="minimap-empty-state">No tiled windows yet</div>';
      return;
    }

    const mw = minimapCanvasEl.clientWidth || 254;
    const mh = minimapCanvasEl.clientHeight || 76;
    const sx = mw / bounds.width;
    const sy = mh / bounds.height;

    const placements = store.tree.leafPlacements(bounds);
    for (const leaf of placements) {
      const rx = Math.round(leaf.frame.x * sx) + 1;
      const ry = Math.round(leaf.frame.y * sy) + 1;
      const rw = Math.max(6, Math.round(leaf.frame.width * sx) - 2);
      const rh = Math.max(6, Math.round(leaf.frame.height * sy) - 2);

      const tile = document.createElement('div');
      tile.className = `minimap-tile ${leaf.isEmpty ? 'is-empty' : 'is-occupied'}`;
      tile.style.left = `${rx}px`;
      tile.style.top = `${ry}px`;
      tile.style.width = `${rw}px`;
      tile.style.height = `${rh}px`;

      if (!leaf.isEmpty && leaf.windowID) {
        const meta = WINDOWS_META[leaf.windowID];
        if (rw >= 24 && rh >= 16) tile.textContent = meta.short;
        tile.title = `Focus ${meta.name}`;
        tile.addEventListener('click', (e) => {
          e.stopPropagation();
          focusWindow(leaf.windowID);
          setStatus(`Focused ${meta.name} from minimap`);
        });
      }
      minimapCanvasEl.appendChild(tile);
    }
  }

  function applyTreeFrames(animate = true) {
    const bounds = workspaceBounds();
    const frames = store.tree.windowFrames(bounds);
    for (const [wid, rect] of frames) {
      const win = windows.get(wid);
      if (win && !win.closed) {
        applyWindowFrame(win, rect, animate);
      }
    }
    syncWindowClassesAndBadges();
  }

  // ============================================================
  // Z-Order Occlusion Check for Seams (floating windows cover seams)
  // ============================================================

  function isPointOccludedByFloatingWindow(point) {
    for (const [id, win] of windows) {
      if (win.closed || store.isTiled(id)) continue;
      const f = win.frame;
      if (
        point.x >= f.x &&
        point.x <= f.x + f.width &&
        point.y >= f.y &&
        point.y <= f.y + f.height
      ) {
        return true;
      }
    }
    return false;
  }

  // ============================================================
  // Drop Preview Overlay
  // ============================================================

  function showDropPreview(plan) {
    if (!plan) {
      hideDropPreview();
      return;
    }
    const inset = 4;
    const r = plan.previewRect;
    dropPreviewEl.style.left = `${r.x + inset}px`;
    dropPreviewEl.style.top = `${r.y + inset}px`;
    dropPreviewEl.style.width = `${Math.max(10, r.width - inset * 2)}px`;
    dropPreviewEl.style.height = `${Math.max(10, r.height - inset * 2)}px`;

    dropPreviewEl.classList.remove('kind-swap', 'kind-replace');
    if (plan.previewKind === 'swap') dropPreviewEl.classList.add('kind-swap');
    else if (plan.previewKind === 'replace') dropPreviewEl.classList.add('kind-replace');

    const badgeMap = {
      splitContainer: '⊞ Split All',
      swap: '⇄ Swap',
      replace: '↻ Replace',
    };
    const label = badgeMap[plan.previewKind];
    if (label && r.width >= 110 && r.height >= 56) {
      dropPreviewBadgeEl.textContent = label;
      dropPreviewBadgeEl.hidden = false;
    } else {
      dropPreviewBadgeEl.hidden = true;
    }

    dropPreviewEl.classList.add('is-visible');
  }

  function hideDropPreview() {
    dropPreviewEl.classList.remove('is-visible');
  }

  // ============================================================
  // Seam Highlight Overlay Rendering
  // ============================================================

  function clearSeamOverlay() {
    seamOverlayEl.innerHTML = '';
    workspaceEl.classList.remove('cursor-col', 'cursor-row', 'cursor-cross');
  }

  function renderSeamLineEl(visualRect, axis, opts) {
    const line = document.createElement('div');
    line.className = 'seam-line';
    if (opts.isDragging) line.classList.add('is-dragging');
    if (opts.isClamped) line.classList.add('is-clamped');
    line.style.left = `${visualRect.x}px`;
    line.style.top = `${visualRect.y}px`;
    line.style.width = `${visualRect.width}px`;
    line.style.height = `${visualRect.height}px`;
    seamOverlayEl.appendChild(line);

    if (opts.showGrip) {
      const grip = document.createElement('div');
      grip.className = 'seam-grip';
      if (opts.isSnapped && !opts.isClamped) grip.classList.add('is-snapped');
      if (opts.isClamped) grip.classList.add('is-clamped');
      if (axis === 'vertical') {
        const pillH = Math.min(42, Math.max(20, visualRect.height * 0.2));
        grip.style.left = `${visualRect.x - 2}px`;
        grip.style.top = `${visualRect.y + (visualRect.height - pillH) * 0.5}px`;
        grip.style.width = '6px';
        grip.style.height = `${pillH}px`;
      } else {
        const pillW = Math.min(42, Math.max(20, visualRect.width * 0.2));
        grip.style.left = `${visualRect.x + (visualRect.width - pillW) * 0.5}px`;
        grip.style.top = `${visualRect.y - 2}px`;
        grip.style.width = `${pillW}px`;
        grip.style.height = '6px';
      }
      seamOverlayEl.appendChild(grip);
    }
  }

  function renderSeamHover(hit) {
    seamOverlayEl.innerHTML = '';
    workspaceEl.classList.remove('cursor-col', 'cursor-row', 'cursor-cross');
    if (!hit) return;

    if (hit.kind === 'single') {
      renderSeamLineEl(hit.seam.visualRect, hit.seam.axis, {
        isDragging: false,
        isClamped: false,
        isSnapped: false,
        showGrip: true,
      });
      workspaceEl.classList.add(hit.seam.axis === 'vertical' ? 'cursor-col' : 'cursor-row');
    } else {
      const v = hit.verticals[0];
      const h = hit.horizontals[0];
      for (const vs of hit.verticals) {
        renderSeamLineEl(vs.visualRect, 'vertical', {
          isDragging: false,
          isClamped: false,
          isSnapped: false,
          showGrip: false,
        });
      }
      for (const hs of hit.horizontals) {
        renderSeamLineEl(hs.visualRect, 'horizontal', {
          isDragging: false,
          isClamped: false,
          isSnapped: false,
          showGrip: false,
        });
      }
      const knob = document.createElement('div');
      knob.className = 'seam-knob';
      knob.style.left = `${v.seamPosition}px`;
      knob.style.top = `${h.seamPosition}px`;
      seamOverlayEl.appendChild(knob);
      workspaceEl.classList.add('cursor-cross');
    }
  }

  function renderSeamHud(pointer, text, isClamped) {
    if (!text) return;
    const bounds = workspaceBounds();
    const hud = document.createElement('div');
    hud.className = `seam-hud${isClamped ? ' is-clamped' : ''}`;
    hud.textContent = text;
    const x = Math.min(Math.max(8, pointer.x), bounds.width - 100);
    const y = Math.min(Math.max(32, pointer.y), bounds.height - 10);
    hud.style.left = `${x}px`;
    hud.style.top = `${y}px`;
    seamOverlayEl.appendChild(hud);
  }

  // ============================================================
  // Drag Controllers (Window Drag + Seam Drag + Esc Undo)
  // ============================================================

  let windowDrag = null;
  let seamDrag = null;
  let lastSeamClick = { key: null, time: 0 };

  function describeSnapKind(snapKind, ratio) {
    if (snapKind) {
      if (snapKind.kind === 'alignedSeam') return 'Aligned';
      if (snapKind.kind === 'detent') {
        if (Math.abs(snapKind.value - 0.5) < 0.01) return '50% detent';
        if (Math.abs(snapKind.value - 1 / 3) < 0.01) return '⅓ detent';
        if (Math.abs(snapKind.value - 2 / 3) < 0.01) return '⅔ detent';
      }
    }
    return `${Math.round(ratio * 100)}%`;
  }

  function beginWindowDrag(win, e) {
    const pointer = pointerInWorkspace(e.clientX, e.clientY);
    focusWindow(win.id);

    const bounds = workspaceBounds();
    const wasTiled = store.isTiled(win.id);
    const preDragFrame = { ...win.frame };
    const preDragTree = store.tree.clone();
    const preDragSaved = new Map(store.savedFloatingFrames);

    windowDrag = {
      pointerId: e.pointerId,
      windowID: win.id,
      win,
      startPointer: pointer,
      offsetX: pointer.x - win.frame.x,
      offsetY: pointer.y - win.frame.y,
      startedAt: performance.now(),
      wasTiled,
      preDragFrame,
      preDragTree,
      preDragSaved,
      detachedDuringDrag: false,
      detachUndo: null,
      currentPlan: null,
      moved: false,
    };

    win.el.classList.remove('is-animated');
    win.el.classList.add('is-dragging');
    workspaceEl.setPointerCapture(e.pointerId);
    clearSeamOverlay();

    // If starting drag with snap active on a tiled window, keep tree intact and plan immediately
    if (isEnabled && isSnapActive()) {
      updateWindowDragPreview(pointer, bounds);
    }
  }

  function updateWindowDragPreview(pointer, bounds) {
    if (!windowDrag || !isEnabled) return;
    const plan = store.planDrop(pointer, windowDrag.windowID, bounds);
    windowDrag.currentPlan = plan;
    showDropPreview(plan);

    if (plan) {
      const actionLabels = {
        fillEmpty: 'Fill empty slot (100%)',
        splitEmpty: `Take ${plan.action.edge} half · leave opposite slot empty`,
        splitOccupied: `Split pane (${plan.action.edge})`,
        splitNode: `T-junction · Split All (${plan.action.edge})`,
        swapOrReplace:
          plan.previewKind === 'swap'
            ? `Swap with ${WINDOWS_META[plan.action.targetWindowID].name}`
            : `Replace ${WINDOWS_META[plan.action.targetWindowID].name} (floats displaced)`,
        keepInPlace: 'Keep in current slot',
        shrinkOwnSlot: `Shrink to ${plan.action.edge} half`,
      };
      const tone =
        plan.previewKind === 'swap' || plan.previewKind === 'replace' ? 'purple' : 'cyan';
      setStatus(actionLabels[plan.action.type] || 'Release to snap', tone);
    }
  }

  function onWindowDragMove(pointer) {
    const d = windowDrag;
    const bounds = workspaceBounds();
    if (!d.moved && Math.hypot(pointer.x - d.startPointer.x, pointer.y - d.startPointer.y) > 3) {
      d.moved = true;
    }
    if (!d.moved) return;

    const snapNow = isEnabled && isSnapActive();

    // Late-Option grace undo (0.45s): if user detached on normal drag and quickly presses Option
    if (
      snapNow &&
      d.detachedDuringDrag &&
      d.detachUndo &&
      performance.now() - d.startedAt <= 450
    ) {
      const frames = store.restoreDetachUndo(d.detachUndo, bounds);
      d.detachedDuringDrag = false;
      d.detachUndo = null;
      for (const [wid, rect] of frames) {
        if (wid !== d.windowID) {
          const other = windows.get(wid);
          if (other && !other.closed) applyWindowFrame(other, rect, true);
        }
      }
      syncWindowClassesAndBadges();
      setStatus('Late ⌥ grace undo · layout restored for re-tiling');
    }

    // Normal drag without Option on a tiled window -> detach & expand neighbors
    if (isEnabled && !snapNow && store.isTiled(d.windowID)) {
      const res = store.detachByUserDrag(d.windowID, d.win.frame, pointer, bounds);
      if (res) {
        d.detachedDuringDrag = true;
        d.detachUndo = res.undo;
        if (res.restoredFrame) {
          applyWindowFrame(d.win, res.restoredFrame, false);
          d.offsetX = pointer.x - res.restoredFrame.x;
          d.offsetY = pointer.y - res.restoredFrame.y;
        }
        for (const [wid, rect] of res.framesToApply) {
          const other = windows.get(wid);
          if (other && !other.closed) applyWindowFrame(other, rect, true);
        }
        syncWindowClassesAndBadges();
        markStep('swapOrDetach');
        setStatus(`Detached ${WINDOWS_META[d.windowID].name} · neighbors expanded`, 'emerald');
      }
    }

    // Move dragged window freely under cursor
    const nextX = Math.max(-d.win.frame.width + 60, Math.min(bounds.width - 60, pointer.x - d.offsetX));
    const nextY = Math.max(0, Math.min(bounds.height - 32, pointer.y - d.offsetY));
    applyWindowFrame(
      d.win,
      { x: nextX, y: nextY, width: d.win.frame.width, height: d.win.frame.height },
      false
    );

    if (snapNow) {
      updateWindowDragPreview(pointer, bounds);
    } else if (d.currentPlan) {
      d.currentPlan = null;
      hideDropPreview();
      setStatus('Snap cancelled · release to drop floating');
    }
  }

  function finishWindowDrag(cancelled = false) {
    if (!windowDrag) return;
    const d = windowDrag;
    windowDrag = null;
    const bounds = workspaceBounds();

    d.win.el.classList.remove('is-dragging');
    hideDropPreview();

    if (cancelled) {
      store.setTree(d.preDragTree);
      store.savedFloatingFrames = d.preDragSaved;
      applyWindowFrame(d.win, d.preDragFrame, true);
      applyTreeFrames(true);
      setStatus('Esc · drag cancelled & layout restored', 'amber');
      return;
    }

    if (isEnabled && isSnapActive() && d.currentPlan) {
      const plan = d.currentPlan;
      const result = store.commitDrop(plan, d.windowID, d.preDragFrame, bounds);
      for (const [wid, rect] of result.framesToApply) {
        const w = windows.get(wid);
        if (w && !w.closed) applyWindowFrame(w, rect, true);
      }
      for (const [wid, rect] of result.detachedWindows) {
        const w = windows.get(wid);
        if (w && !w.closed) {
          applyWindowFrame(w, rect, true);
          zCounter += 1;
          w.zIndex = zCounter;
        }
      }
      syncWindowClassesAndBadges();

      // Update guided checklist
      markStep('snap');
      if (
        plan.action.type === 'splitOccupied' ||
        plan.action.type === 'splitNode' ||
        plan.action.type === 'splitEmpty' ||
        plan.action.type === 'shrinkOwnSlot'
      ) {
        markStep('split');
      }
      if (plan.action.type === 'swapOrReplace') {
        markStep('swapOrDetach');
      }

      if (plan.action.type === 'splitNode') {
        setStatus('T-junction split committed across container', 'emerald');
      } else if (plan.previewKind === 'swap') {
        setStatus('Swapped tiled windows', 'purple');
      } else if (plan.previewKind === 'replace') {
        setStatus('Replaced tiled slot · previous window floated', 'purple');
      } else {
        setStatus(`Tiled ${WINDOWS_META[d.windowID].name}`, 'emerald');
      }
    } else if (d.wasTiled && store.isTiled(d.windowID)) {
      // Released Option-drag without valid drop zone (e.g. over menu bar) -> snap back to slot
      applyTreeFrames(true);
      setStatus('Snapped back to slot');
    } else {
      syncWindowClassesAndBadges();
    }
  }

  // Seam Dragging & Double-Click
  function seamHitIdentity(hit) {
    if (hit.kind === 'single') return `s:${hit.seam.splitID}`;
    return `i:${hit.verticals.map((s) => s.splitID).join(',')}+${hit.horizontals
      .map((s) => s.splitID)
      .join(',')}`;
  }

  function beginSeamDrag(hit, e) {
    const pointer = pointerInWorkspace(e.clientX, e.clientY);
    const now = performance.now();
    const key = seamHitIdentity(hit);

    // Double-click detection on a single seam -> collapse empty or reset 50/50
    if (hit.kind === 'single' && lastSeamClick.key === key && now - lastSeamClick.time < 340) {
      lastSeamClick = { key: null, time: 0 };
      const t = store.tree.clone();
      if (t.handleSeamDoubleClick(hit.seam.splitID)) {
        store.setTree(t);
        applyTreeFrames(true);
        clearSeamOverlay();
        markStep('seam');
        setStatus(
          hit.seam.firstIsEmpty || hit.seam.secondIsEmpty
            ? 'Double-click seam · collapsed empty slot'
            : 'Double-click seam · reset split to 50/50',
          'emerald'
        );
      }
      return;
    }
    lastSeamClick = { key, time: now };

    const allSeams = store.visibleSeams(workspaceBounds());
    const entries =
      hit.kind === 'single'
        ? [
            {
              seam: hit.seam,
              grabOffset:
                (hit.seam.axis === 'vertical' ? pointer.x : pointer.y) - hit.seam.seamPosition,
            },
          ]
        : [...hit.verticals, ...hit.horizontals].map((s) => ({
            seam: s,
            grabOffset: (s.axis === 'vertical' ? pointer.x : pointer.y) - s.seamPosition,
          }));

    seamDrag = {
      pointerId: e.pointerId,
      hit,
      entries,
      allSeams,
      preDragTree: store.tree.clone(),
      collapseSplitID: null,
      moved: false,
    };

    workspaceEl.setPointerCapture(e.pointerId);
    onSeamDragMove(pointer);
  }

  function onSeamDragMove(pointer) {
    const d = seamDrag;
    const bounds = workspaceBounds();
    d.moved = true;
    d.collapseSplitID = null;

    const disableSnapping = physicalShiftDown;
    const t = store.tree.clone();

    seamOverlayEl.innerHTML = '';

    if (d.hit.kind === 'single') {
      const entry = d.entries[0];
      const update = SeamGeometry.dragUpdate({
        pointer,
        seam: entry.seam,
        tree: t,
        minSizes: store.minSizes,
        allSeams: d.allSeams,
        disableSnapping,
        grabOffset: entry.grabOffset,
      });

      if (update.collapseTarget) {
        d.collapseSplitID = entry.seam.splitID;
        const box = document.createElement('div');
        box.className = 'seam-collapse-preview';
        const r = update.collapseTarget.expandedBounds;
        box.style.left = `${r.x + 4}px`;
        box.style.top = `${r.y + 4}px`;
        box.style.width = `${r.width - 8}px`;
        box.style.height = `${r.height - 8}px`;
        seamOverlayEl.appendChild(box);
        renderSeamHud(pointer, 'Release to collapse empty slot', false);
        setStatus('Release to collapse empty slot to 100%', 'cyan');
        return;
      }

      t.setRatio(entry.seam.splitID, update.ratio);
      store.tree = t;

      const frames = store.tree.windowFrames(bounds);
      for (const [wid, rect] of frames) {
        const w = windows.get(wid);
        if (w && !w.closed) applyWindowFrame(w, rect, false);
      }
      renderEmptySlots();
      renderMinimapAndPopover();

      renderSeamLineEl(update.visualRect, entry.seam.axis, {
        isDragging: true,
        isClamped: update.isClamped,
        isSnapped: Boolean(update.snapKind),
        showGrip: true,
      });

      const hudLabel = update.isClamped
        ? 'Min size limit'
        : describeSnapKind(update.snapKind, update.ratio);
      renderSeamHud(pointer, hudLabel, update.isClamped);
      setStatus(
        update.isClamped
          ? 'Clamped at window minimum size'
          : update.snapKind
          ? `Snapped · ${hudLabel} (hold ⇧ for free)`
          : `Resizing seam · ${Math.round(update.ratio * 100)}%`,
        update.isClamped ? 'amber' : 'cyan'
      );
      workspaceEl.classList.add(entry.seam.axis === 'vertical' ? 'cursor-col' : 'cursor-row');
    } else {
      // 2-axis intersection drag (┼ / ├)
      let anyClamped = false;
      let anySnapped = false;
      let primaryVUpdate = null;
      let primaryHUpdate = null;

      for (const entry of d.entries) {
        const update = SeamGeometry.dragUpdate({
          pointer,
          seam: entry.seam,
          tree: t,
          minSizes: store.minSizes,
          allSeams: d.allSeams,
          disableSnapping,
          grabOffset: entry.grabOffset,
        });
        t.setRatio(entry.seam.splitID, update.ratio);
        if (update.isClamped) anyClamped = true;
        if (update.snapKind) anySnapped = true;
        if (entry.seam.axis === 'vertical' && !primaryVUpdate) primaryVUpdate = update;
        if (entry.seam.axis === 'horizontal' && !primaryHUpdate) primaryHUpdate = update;
      }

      store.tree = t;
      const frames = store.tree.windowFrames(bounds);
      for (const [wid, rect] of frames) {
        const w = windows.get(wid);
        if (w && !w.closed) applyWindowFrame(w, rect, false);
      }
      renderEmptySlots();
      renderMinimapAndPopover();

      if (primaryVUpdate && primaryHUpdate) {
        const freshSeams = store.visibleSeams(bounds);
        const draggedIDs = new Set(d.entries.map((e) => e.seam.splitID));
        for (const s of freshSeams) {
          if (!draggedIDs.has(s.splitID)) continue;
          renderSeamLineEl(s.visualRect, s.axis, {
            isDragging: true,
            isClamped: anyClamped,
            isSnapped: anySnapped,
            showGrip: false,
          });
        }
        const knob = document.createElement('div');
        knob.className = 'seam-knob';
        if (anySnapped && !anyClamped) knob.classList.add('is-snapped');
        if (anyClamped) knob.classList.add('is-clamped');
        knob.style.left = `${primaryVUpdate.seamPosition}px`;
        knob.style.top = `${primaryHUpdate.seamPosition}px`;
        seamOverlayEl.appendChild(knob);

        const label = anyClamped
          ? 'Min size limit'
          : `${Math.round(primaryVUpdate.ratio * 100)}% × ${Math.round(
              primaryHUpdate.ratio * 100
            )}%`;
        renderSeamHud(pointer, label, anyClamped);
        setStatus(
          anyClamped
            ? '┼ Intersection clamped at window min size'
            : `2-axis ┼ resize · ${label}`,
          anyClamped ? 'amber' : 'cyan'
        );
      }
      workspaceEl.classList.add('cursor-cross');
    }
  }

  function finishSeamDrag(cancelled = false) {
    if (!seamDrag) return;
    const d = seamDrag;
    seamDrag = null;

    if (cancelled) {
      store.setTree(d.preDragTree);
      applyTreeFrames(true);
      clearSeamOverlay();
      setStatus('Esc · seam resize cancelled', 'amber');
      return;
    }

    if (d.collapseSplitID !== null) {
      const t = store.tree.clone();
      t.collapseEmptyChild(d.collapseSplitID);
      store.setTree(t);
      applyTreeFrames(true);
      clearSeamOverlay();
      markStep('seam');
      setStatus('Collapsed empty slot to 100%', 'emerald');
      return;
    }

    store.revision += 1;
    clearSeamOverlay();
    renderMinimapAndPopover();
    if (d.moved) {
      markStep('seam');
    }
  }

  // ============================================================
  // Pointer & Keyboard Wiring
  // ============================================================

  workspaceEl.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;

    // Close menu bar popover on workspace click
    if (!popoverEl.hidden) {
      popoverEl.hidden = true;
      menubarBtn.classList.remove('is-open');
      menubarBtn.setAttribute('aria-expanded', 'false');
    }

    // Close button click
    const closeBtn = e.target.closest('[data-close-win]');
    if (closeBtn) {
      e.stopPropagation();
      const wid = Number(closeBtn.dataset.closeWin);
      closeMockWindow(wid);
      return;
    }

    const pointer = pointerInWorkspace(e.clientX, e.clientY);

    // 1. Check flush seams first (unless occluded by a floating window)
    if (isEnabled && !isPointOccludedByFloatingWindow(pointer)) {
      const seams = store.visibleSeams(workspaceBounds());
      const hit = SeamGeometry.hitTestTarget(pointer, seams);
      if (hit) {
        e.preventDefault();
        beginSeamDrag(hit, e);
        return;
      }
    }

    // 2. Check window focus & drag (titlebar OR anywhere when Ctrl+Cmd is held)
    const winEl = e.target.closest('.mock-window');
    if (winEl) {
      const wid = Number(winEl.dataset.winId);
      const win = windows.get(wid);
      if (!win || win.closed) return;
      focusWindow(wid);

      const onTitlebar = Boolean(e.target.closest('[data-drag-handle]'));
      if (onTitlebar || physicalCtrlCmdDown || isSnapActive()) {
        e.preventDefault();
        beginWindowDrag(win, e);
      }
    }
  });

  workspaceEl.addEventListener('pointermove', (e) => {
    const pointer = pointerInWorkspace(e.clientX, e.clientY);

    if (seamDrag && e.pointerId === seamDrag.pointerId) {
      onSeamDragMove(pointer);
      return;
    }

    if (windowDrag && e.pointerId === windowDrag.pointerId) {
      onWindowDragMove(pointer);
      return;
    }

    // Passive seam hover highlight
    if (!isEnabled || isPointOccludedByFloatingWindow(pointer)) {
      clearSeamOverlay();
      return;
    }
    const seams = store.visibleSeams(workspaceBounds());
    const hit = SeamGeometry.hitTestTarget(pointer, seams);
    renderSeamHover(hit);
  });

  workspaceEl.addEventListener('pointerup', (e) => {
    if (seamDrag && e.pointerId === seamDrag.pointerId) {
      finishSeamDrag(false);
    } else if (windowDrag && e.pointerId === windowDrag.pointerId) {
      finishWindowDrag(false);
    }
  });

  workspaceEl.addEventListener('pointercancel', () => {
    if (seamDrag) finishSeamDrag(true);
    if (windowDrag) finishWindowDrag(true);
  });

  workspaceEl.addEventListener('pointerleave', () => {
    if (!seamDrag && !windowDrag) clearSeamOverlay();
  });

  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (windowDrag) {
        e.preventDefault();
        finishWindowDrag(true);
        return;
      }
      if (seamDrag) {
        e.preventDefault();
        finishSeamDrag(true);
        return;
      }
      if (!popoverEl.hidden) {
        popoverEl.hidden = true;
        menubarBtn.classList.remove('is-open');
      }
    }

    let changed = false;
    if (e.key === 'Alt' && !physicalOptionDown) {
      physicalOptionDown = true;
      changed = true;
    }
    if ((e.ctrlKey && e.metaKey) !== physicalCtrlCmdDown) {
      physicalCtrlCmdDown = e.ctrlKey && e.metaKey;
      changed = true;
    }
    if (e.key === 'Shift' && !physicalShiftDown) {
      physicalShiftDown = true;
      changed = true;
    }

    if (changed) {
      updateModifierUI();
      if (windowDrag && isEnabled) {
        const bounds = workspaceBounds();
        if (isSnapActive()) {
          if (
            windowDrag.detachedDuringDrag &&
            windowDrag.detachUndo &&
            performance.now() - windowDrag.startedAt <= 450
          ) {
            const frames = store.restoreDetachUndo(windowDrag.detachUndo, bounds);
            windowDrag.detachedDuringDrag = false;
            windowDrag.detachUndo = null;
            for (const [wid, rect] of frames) {
              if (wid !== windowDrag.windowID) {
                const other = windows.get(wid);
                if (other && !other.closed) applyWindowFrame(other, rect, true);
              }
            }
            syncWindowClassesAndBadges();
          }
          updateWindowDragPreview(
            {
              x: windowDrag.win.frame.x + windowDrag.offsetX,
              y: windowDrag.win.frame.y + windowDrag.offsetY,
            },
            bounds
          );
        } else {
          windowDrag.currentPlan = null;
          hideDropPreview();
        }
      }
    }
  });

  window.addEventListener('keyup', (e) => {
    let changed = false;
    if (e.key === 'Alt' && physicalOptionDown) {
      physicalOptionDown = false;
      changed = true;
    }
    if ((e.ctrlKey && e.metaKey) !== physicalCtrlCmdDown) {
      physicalCtrlCmdDown = e.ctrlKey && e.metaKey;
      changed = true;
    }
    if (e.key === 'Shift' && physicalShiftDown) {
      physicalShiftDown = false;
      changed = true;
    }

    if (changed) {
      updateModifierUI();
      if (windowDrag && !isSnapActive()) {
        windowDrag.currentPlan = null;
        hideDropPreview();
        setStatus('Released ⌥ · drop to float');
      }
    }
  });

  window.addEventListener('blur', () => {
    physicalOptionDown = false;
    physicalCtrlCmdDown = false;
    physicalShiftDown = false;
    updateModifierUI();
  });

  // ============================================================
  // Close & Quit-History Relaunch
  // ============================================================

  function closeMockWindow(wid) {
    const win = windows.get(wid);
    if (!win || win.closed) return;
    const bounds = workspaceBounds();
    const wasTiled = store.isTiled(wid);

    win.closed = true;
    if (wasTiled) {
      const frames = store.closeWindow(wid, bounds);
      if (frames) {
        for (const [id, rect] of frames) {
          const other = windows.get(id);
          if (other && !other.closed) applyWindowFrame(other, rect, true);
        }
      }
      setStatus(
        `Closed ${WINDOWS_META[wid].name} · split collapsed (reopen from dock to restore)`,
        'emerald'
      );
    } else {
      setStatus(`Closed ${WINDOWS_META[wid].name}`);
    }
    syncWindowClassesAndBadges();
  }

  function openOrFocusWindow(wid) {
    const win = windows.get(wid);
    if (!win) return;
    if (!win.closed) {
      focusWindow(wid);
      return;
    }

    const bounds = workspaceBounds();
    win.closed = false;

    const restoredFrames = store.relaunchWindow(wid, bounds);
    if (restoredFrames) {
      for (const [id, rect] of restoredFrames) {
        const w = windows.get(id);
        if (w && !w.closed) applyWindowFrame(w, rect, true);
      }
      focusWindow(wid);
      setStatus(`Relaunched ${WINDOWS_META[wid].name} · restored exact pre-quit slot!`, 'emerald');
    } else {
      const fw = Math.min(360, Math.round(bounds.width * 0.42));
      const fh = Math.min(250, Math.round(bounds.height * 0.48));
      applyWindowFrame(
        win,
        {
          x: Math.round((bounds.width - fw) * 0.52),
          y: Math.round((bounds.height - fh) * 0.44),
          width: fw,
          height: fh,
        },
        false
      );
      focusWindow(wid);
      setStatus(`Opened ${WINDOWS_META[wid].name} floating`);
    }
    syncWindowClassesAndBadges();
  }

  // ============================================================
  // Toolbar, Menu Bar Popover & Presets
  // ============================================================

  snapToggleBtn.addEventListener('click', () => {
    snapLocked = !snapLocked;
    updateModifierUI();
    setStatus(
      snapLocked
        ? 'Snap Mode locked ON · drag any window to preview & tile'
        : 'Snap Mode OFF · hold ⌥ while dragging to tile'
    );
  });

  menubarBtn.addEventListener('click', (e) => {
    if (e.altKey) {
      toggleEnabled();
      return;
    }
    const willOpen = popoverEl.hidden;
    popoverEl.hidden = !willOpen;
    menubarBtn.classList.toggle('is-open', willOpen);
    menubarBtn.setAttribute('aria-expanded', String(willOpen));
    if (willOpen) renderMinimapAndPopover();
  });

  menubarBtn.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    toggleEnabled();
  });

  popoverSwitchEl.addEventListener('click', () => toggleEnabled());

  function toggleEnabled() {
    isEnabled = !isEnabled;
    if (!isEnabled) clearSeamOverlay();
    renderMinimapAndPopover();
    setStatus(
      isEnabled ? 'Seamstress resumed' : 'Seamstress paused (⌥-click menu bar icon to resume)',
      isEnabled ? 'cyan' : 'amber'
    );
  }

  minimapEqualizeBtn.addEventListener('click', () => {
    const t = store.tree.clone();
    if (t.equalizeSplits()) {
      store.setTree(t);
      applyTreeFrames(true);
      setStatus('Equalized all splits to 50/50', 'emerald');
    }
  });

  minimapClearBtn.addEventListener('click', () => {
    const bounds = workspaceBounds();
    const tiledIDs = store.tree.allWindowIDs;
    store.clear();
    tiledIDs.forEach((wid, idx) => {
      const win = windows.get(wid);
      if (!win || win.closed) return;
      const saved = store.savedFloatingFrames.get(wid);
      store.savedFloatingFrames.delete(wid);
      if (saved) {
        applyWindowFrame(win, saved, true);
      } else {
        const fw = Math.min(390, Math.round(bounds.width * 0.44));
        const fh = Math.min(260, Math.round(bounds.height * 0.5));
        applyWindowFrame(
          win,
          { x: 40 + idx * 46, y: 36 + idx * 34, width: fw, height: fh },
          true
        );
      }
    });
    clearSeamOverlay();
    syncWindowClassesAndBadges();
    setStatus('Cleared Space layout · windows returned to floating');
  });

  for (const pill of dockPills) {
    pill.addEventListener('click', () => {
      openOrFocusWindow(Number(pill.dataset.dockWin));
    });
  }

  function loadPreset(presetName, animate = true) {
    activePreset = presetName;
    for (const btn of presetBtns) {
      btn.classList.toggle('is-selected', btn.dataset.preset === presetName);
    }

    const b = workspaceBounds();
    store.clear();
    store.savedFloatingFrames.clear();
    store.quitSnapshots.clear();
    clearSeamOverlay();

    const w1 = windows.get(1);
    const w2 = windows.get(2);
    const w3 = windows.get(3);
    const w4 = windows.get(4);

    // Compute clean proportional default floating frames
    const f1 = {
      x: Math.round(b.width * 0.05),
      y: Math.round(b.height * 0.09),
      width: Math.round(Math.min(440, b.width * 0.44)),
      height: Math.round(Math.min(290, b.height * 0.56)),
    };
    const f2 = {
      x: Math.round(b.width * 0.48),
      y: Math.round(b.height * 0.14),
      width: Math.round(Math.min(380, b.width * 0.39)),
      height: Math.round(Math.min(245, b.height * 0.48)),
    };
    const f3 = {
      x: Math.round(b.width * 0.25),
      y: Math.round(b.height * 0.36),
      width: Math.round(Math.min(410, b.width * 0.42)),
      height: Math.round(Math.min(265, b.height * 0.52)),
    };
    const f4 = {
      x: Math.round(b.width * 0.54),
      y: Math.round(b.height * 0.4),
      width: Math.round(Math.min(330, b.width * 0.34)),
      height: Math.round(Math.min(230, b.height * 0.44)),
    };

    if (presetName === 'floating') {
      w1.closed = false;
      w2.closed = false;
      w3.closed = false;
      w4.closed = true;
      applyWindowFrame(w1, f1, animate);
      applyWindowFrame(w2, f2, animate);
      applyWindowFrame(w3, f3, animate);
      applyWindowFrame(w4, f4, false);
      w1.zIndex = 1;
      w2.zIndex = 2;
      w3.zIndex = 3;
      focusedWindowID = 3;
      syncWindowClassesAndBadges();
      setStatus('Hold ⌥ and drag a window—or toggle Snap Mode');
    } else if (presetName === 'three-pane') {
      w1.closed = false;
      w2.closed = false;
      w3.closed = false;
      w4.closed = true;
      store.savedFloatingFrames.set(1, f1);
      store.savedFloatingFrames.set(2, f2);
      store.savedFloatingFrames.set(3, f3);

      const t = new LayoutTree();
      t.fillEmpty(1, 1);
      t.splitOccupied(1, 'right', 0.52, 2);
      const leaf2 = t.leafID(2);
      t.splitOccupied(leaf2, 'bottom', 0.5, 3);
      store.setTree(t);

      focusedWindowID = 1;
      applyTreeFrames(animate);
      setStatus('3-Pane split · hover the seams or ├ junction to resize');
    } else if (presetName === 'grid-2x2') {
      w1.closed = false;
      w2.closed = false;
      w3.closed = false;
      w4.closed = false;
      store.savedFloatingFrames.set(1, f1);
      store.savedFloatingFrames.set(2, f2);
      store.savedFloatingFrames.set(3, f3);
      store.savedFloatingFrames.set(4, f4);

      const t = new LayoutTree();
      t.fillEmpty(1, 1);
      t.splitOccupied(1, 'right', 0.5, 2);
      t.splitOccupied(t.leafID(1), 'bottom', 0.5, 3);
      t.splitOccupied(t.leafID(2), 'bottom', 0.5, 4);
      store.setTree(t);

      focusedWindowID = 1;
      applyTreeFrames(animate);
      setStatus('2×2 Grid · grab the center ┼ knob to resize all 4 panes at once');
    }
  }

  for (const btn of presetBtns) {
    btn.addEventListener('click', () => loadPreset(btn.dataset.preset, true));
  }

  resetBtn.addEventListener('click', () => {
    loadPreset('floating', true);
    setStatus('Playground reset to floating windows');
  });

  // Keep tiled windows flush on viewport resize
  let resizeRaf = null;
  window.addEventListener('resize', () => {
    if (resizeRaf) cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => {
      if (!store.tree.isEmpty) {
        applyTreeFrames(false);
      } else {
        // Keep floating windows within resized viewport
        const b = workspaceBounds();
        for (const win of windows.values()) {
          if (win.closed) continue;
          const clampedX = Math.max(8, Math.min(win.frame.x, Math.max(8, b.width - win.frame.width - 8)));
          const clampedY = Math.max(8, Math.min(win.frame.y, Math.max(8, b.height - win.frame.height - 8)));
          applyWindowFrame(
            win,
            {
              x: clampedX,
              y: clampedY,
              width: Math.min(win.frame.width, b.width - 16),
              height: Math.min(win.frame.height, b.height - 16),
            },
            false
          );
        }
      }
    });
  });

  // Initialize on load
  loadPreset('floating', false);
})();
