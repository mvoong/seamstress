/**
 * SeamstressCore — Faithful client-side JavaScript port of Sources/SeamstressCore
 * (Geometry.swift, LayoutTree.swift, DropPlanner.swift, SeamGeometry.swift, SpaceLayoutStore.swift)
 * Zero dependencies; works offline via file:// and on any static host.
 */
(function (root) {
  'use strict';

  const DEFAULT_MIN_LEAF_DIMENSION = 110;
  const MIN_EMPTY_SLOT_DIMENSION = 42;
  const COLLAPSE_THRESHOLD = 0.9;
  const HIT_THICKNESS = 10;
  const VISUAL_THICKNESS = 2;
  const SNAP_TOLERANCE_PX = 7;

  const EMPTY_EDGE_FRACTION = 0.22;
  const MAX_EMPTY_EDGE_PX = 150;
  const THIRD_EDGE_FRACTION = 0.06;
  const MAX_THIRD_EDGE_PX = 38;
  const OCCUPIED_CENTER_FRACTION = 0.36;
  const T_JUNCTION_HALF_SPAN = 44;
  const T_JUNCTION_MAX_DEPTH = 64;
  const T_JUNCTION_THIRD_MAX_DEPTH = 24;

  function clamp(v, lo, hi) {
    return Math.min(Math.max(v, lo), hi);
  }

  function rectContains(r, p) {
    return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;
  }

  function rectInset(r, dx, dy) {
    return {
      x: r.x + dx,
      y: r.y + dy,
      width: r.width - dx * 2,
      height: r.height - dy * 2,
    };
  }

  function rectStart(r, axis) {
    return axis === 'vertical' ? r.x : r.y;
  }

  function rectSpan(r, axis) {
    return axis === 'vertical' ? r.width : r.height;
  }

  function pointCoord(p, axis) {
    return axis === 'vertical' ? p.x : p.y;
  }

  function sizeSpan(s, axis) {
    return axis === 'vertical' ? s.width : s.height;
  }

  function edgeAxis(edge) {
    return edge === 'left' || edge === 'right' ? 'vertical' : 'horizontal';
  }

  function edgeIsFirstChild(edge) {
    return edge === 'left' || edge === 'top';
  }

  function splitFlush(rect, axis, ratio) {
    const clamped = clamp(ratio, 0.01, 0.99);
    if (axis === 'vertical') {
      const firstWidth = Math.round(rect.width * clamped);
      const secondWidth = Math.max(0, rect.width - firstWidth);
      const seamX = rect.x + firstWidth;
      return {
        first: { x: rect.x, y: rect.y, width: firstWidth, height: rect.height },
        second: { x: seamX, y: rect.y, width: secondWidth, height: rect.height },
        seamPosition: seamX,
      };
    } else {
      const firstHeight = Math.round(rect.height * clamped);
      const secondHeight = Math.max(0, rect.height - firstHeight);
      const seamY = rect.y + firstHeight;
      return {
        first: { x: rect.x, y: rect.y, width: rect.width, height: firstHeight },
        second: { x: rect.x, y: seamY, width: rect.width, height: secondHeight },
        seamPosition: seamY,
      };
    }
  }

  function restoredUnderCursor(savedSize, currentFrame, cursor) {
    const relX =
      currentFrame.width > 1
        ? clamp((cursor.x - currentFrame.x) / currentFrame.width, 0.1, 0.9)
        : 0.5;
    const offsetY = clamp(cursor.y - currentFrame.y, 8, Math.min(savedSize.height - 8, 32));
    return {
      x: Math.round(cursor.x - savedSize.width * relX),
      y: Math.round(cursor.y - offsetY),
      width: savedSize.width,
      height: savedSize.height,
    };
  }

  // MARK: - Node helpers

  function isCompletelyEmpty(node) {
    if (node.type === 'empty') return true;
    if (node.type === 'window') return false;
    return isCompletelyEmpty(node.first) && isCompletelyEmpty(node.second);
  }

  function collectWindowIDs(node, out) {
    if (node.type === 'empty') return;
    if (node.type === 'window') {
      out.push(node.windowID);
      return;
    }
    collectWindowIDs(node.first, out);
    collectWindowIDs(node.second, out);
  }

  function cloneNode(node) {
    if (node.type === 'empty') return { type: 'empty', id: node.id };
    if (node.type === 'window') return { type: 'window', id: node.id, windowID: node.windowID };
    return {
      type: 'split',
      id: node.id,
      axis: node.axis,
      ratio: node.ratio,
      first: cloneNode(node.first),
      second: cloneNode(node.second),
    };
  }

  function makeSplit(id, edge, ratio, incoming, existing) {
    const clampedRatio = clamp(ratio, 0.05, 0.95);
    const axis = edgeAxis(edge);
    if (edgeIsFirstChild(edge)) {
      return { type: 'split', id, axis, ratio: clampedRatio, first: incoming, second: existing };
    }
    return { type: 'split', id, axis, ratio: clampedRatio, first: existing, second: incoming };
  }

  function mapNode(node, transform) {
    if (node.type === 'empty' || node.type === 'window') {
      return transform(node);
    }
    const newFirst = mapNode(node.first, transform);
    const newSecond = mapNode(node.second, transform);
    return transform({
      type: 'split',
      id: node.id,
      axis: node.axis,
      ratio: node.ratio,
      first: newFirst,
      second: newSecond,
    });
  }

  function collapseDoubleEmpty(node) {
    if (node.type === 'empty' || node.type === 'window') return node;
    const cFirst = collapseDoubleEmpty(node.first);
    const cSecond = collapseDoubleEmpty(node.second);
    if (isCompletelyEmpty(cFirst) && isCompletelyEmpty(cSecond)) {
      return { type: 'empty', id: node.id };
    }
    return {
      type: 'split',
      id: node.id,
      axis: node.axis,
      ratio: node.ratio,
      first: cFirst,
      second: cSecond,
    };
  }

  // MARK: - LayoutTree

  class LayoutTree {
    constructor(rootNode, nextID) {
      this.root = rootNode || { type: 'empty', id: 1 };
      this.nextID = nextID || 2;
    }

    clone() {
      return new LayoutTree(cloneNode(this.root), this.nextID);
    }

    allocID() {
      const id = this.nextID;
      this.nextID += 1;
      return id;
    }

    get isEmpty() {
      return isCompletelyEmpty(this.root);
    }

    get allWindowIDs() {
      const ids = [];
      collectWindowIDs(this.root, ids);
      return ids;
    }

    contains(windowID) {
      return this.leafID(windowID) !== null;
    }

    leafID(windowID) {
      const find = (node) => {
        if (node.type === 'empty') return null;
        if (node.type === 'window') return node.windowID === windowID ? node.id : null;
        return find(node.first) ?? find(node.second);
      };
      return find(this.root);
    }

    nodeWithID(targetID) {
      const find = (node) => {
        if (node.id === targetID) return node;
        if (node.type !== 'split') return null;
        return find(node.first) ?? find(node.second);
      };
      return find(this.root);
    }

    areDirectSiblings(a, b) {
      if (a === b) return false;
      const check = (node) => {
        if (node.type !== 'split') return false;
        if (
          (node.first.id === a && node.second.id === b) ||
          (node.first.id === b && node.second.id === a)
        ) {
          return true;
        }
        return check(node.first) || check(node.second);
      };
      return check(this.root);
    }

    leafPlacements(bounds) {
      const result = [];
      const walk = (node, b) => {
        if (node.type === 'empty') {
          result.push({ leafID: node.id, windowID: null, isEmpty: true, frame: b });
        } else if (node.type === 'window') {
          result.push({ leafID: node.id, windowID: node.windowID, isEmpty: false, frame: b });
        } else {
          const { first, second } = splitFlush(b, node.axis, node.ratio);
          walk(node.first, first);
          walk(node.second, second);
        }
      };
      walk(this.root, bounds);
      return result;
    }

    windowFrames(bounds) {
      const map = new Map();
      const walk = (node, b) => {
        if (node.type === 'empty') return;
        if (node.type === 'window') {
          map.set(node.windowID, b);
          return;
        }
        const { first, second } = splitFlush(b, node.axis, node.ratio);
        walk(node.first, first);
        walk(node.second, second);
      };
      walk(this.root, bounds);
      return map;
    }

    leafAt(point, bounds) {
      if (!rectContains(bounds, point)) return null;
      const find = (node, b) => {
        if (node.type === 'empty') {
          return { leafID: node.id, windowID: null, isEmpty: true, frame: b };
        }
        if (node.type === 'window') {
          return { leafID: node.id, windowID: node.windowID, isEmpty: false, frame: b };
        }
        const { first, second, seamPosition } = splitFlush(b, node.axis, node.ratio);
        if (pointCoord(point, node.axis) < seamPosition) {
          return find(node.first, first);
        }
        return find(node.second, second);
      };
      return find(this.root, bounds);
    }

    fillEmpty(leafID, windowID) {
      let applied = false;
      this.root = mapNode(this.root, (node) => {
        if (node.type === 'empty' && node.id === leafID) {
          applied = true;
          return { type: 'window', id: node.id, windowID };
        }
        return node;
      });
      return applied;
    }

    splitEmpty(leafID, edge, ratio, windowID) {
      let applied = false;
      const splitID = this.allocID();
      const winLeafID = this.allocID();
      const emptyLeafID = this.allocID();
      this.root = mapNode(this.root, (node) => {
        if (node.type === 'empty' && node.id === leafID) {
          applied = true;
          return makeSplit(
            splitID,
            edge,
            ratio,
            { type: 'window', id: winLeafID, windowID },
            { type: 'empty', id: emptyLeafID }
          );
        }
        return node;
      });
      return applied;
    }

    splitNode(nodeID, edge, ratio, incomingWindowID) {
      let applied = false;
      const splitID = this.allocID();
      const newLeafID = this.allocID();
      this.root = mapNode(this.root, (node) => {
        if (node.id === nodeID) {
          applied = true;
          return makeSplit(
            splitID,
            edge,
            ratio,
            { type: 'window', id: newLeafID, windowID: incomingWindowID },
            node
          );
        }
        return node;
      });
      return applied;
    }

    splitOccupied(leafID, edge, ratio, incomingWindowID) {
      let applied = false;
      const splitID = this.allocID();
      const newLeafID = this.allocID();
      this.root = mapNode(this.root, (node) => {
        if (node.type === 'window' && node.id === leafID) {
          applied = true;
          return makeSplit(
            splitID,
            edge,
            ratio,
            { type: 'window', id: newLeafID, windowID: incomingWindowID },
            { type: 'window', id: node.id, windowID: node.windowID }
          );
        }
        return node;
      });
      return applied;
    }

    shrinkToEdge(leafID, edge, ratio) {
      let applied = false;
      const splitID = this.allocID();
      const emptyLeafID = this.allocID();
      this.root = mapNode(this.root, (node) => {
        if (node.type === 'window' && node.id === leafID) {
          applied = true;
          return makeSplit(
            splitID,
            edge,
            ratio,
            { type: 'window', id: node.id, windowID: node.windowID },
            { type: 'empty', id: emptyLeafID }
          );
        }
        return node;
      });
      return applied;
    }

    swapWindows(a, b) {
      if (a === b || !this.contains(a) || !this.contains(b)) return false;
      this.root = mapNode(this.root, (node) => {
        if (node.type !== 'window') return node;
        if (node.windowID === a) return { type: 'window', id: node.id, windowID: b };
        if (node.windowID === b) return { type: 'window', id: node.id, windowID: a };
        return node;
      });
      return true;
    }

    replaceWindow(leafID, incoming) {
      let displaced = null;
      this.root = mapNode(this.root, (node) => {
        if (node.type === 'window' && node.id === leafID) {
          displaced = node.windowID;
          return { type: 'window', id: node.id, windowID: incoming };
        }
        return node;
      });
      return displaced;
    }

    removeLeaf(leafID) {
      let removed = false;
      const replaced = mapNode(this.root, (node) => {
        if (node.type === 'window' && node.id === leafID) {
          removed = true;
          return { type: 'empty', id: node.id };
        }
        return node;
      });
      if (!removed) return false;
      this.root = collapseDoubleEmpty(replaced);
      return true;
    }

    removeWindow(windowID) {
      const id = this.leafID(windowID);
      return id === null ? false : this.removeLeaf(id);
    }

    removeLeafAndCollapse(leafID) {
      let removed = false;
      const prune = (node) => {
        if (node.type === 'empty') return node;
        if (node.type === 'window') {
          if (node.id === leafID) {
            removed = true;
            return null;
          }
          return node;
        }
        const newFirst = prune(node.first);
        const newSecond = prune(node.second);
        if (!newFirst && !newSecond) return null;
        if (newFirst && !newSecond) return isCompletelyEmpty(newFirst) ? null : newFirst;
        if (!newFirst && newSecond) return isCompletelyEmpty(newSecond) ? null : newSecond;
        return {
          type: 'split',
          id: node.id,
          axis: node.axis,
          ratio: node.ratio,
          first: newFirst,
          second: newSecond,
        };
      };
      const collapsed = prune(this.root);
      if (!removed) return false;
      if (collapsed) {
        this.root = collapseDoubleEmpty(collapsed);
      } else {
        this.root = { type: 'empty', id: this.allocID() };
      }
      return true;
    }

    removeWindowAndCollapse(windowID) {
      const id = this.leafID(windowID);
      return id === null ? false : this.removeLeafAndCollapse(id);
    }

    setRatio(splitID, ratio) {
      const clamped = clamp(ratio, 0.05, 0.95);
      let updated = false;
      this.root = mapNode(this.root, (node) => {
        if (node.type === 'split' && node.id === splitID) {
          updated = true;
          return { ...node, ratio: clamped };
        }
        return node;
      });
      return updated;
    }

    collapseEmptyChild(splitID) {
      let collapsed = false;
      this.root = mapNode(this.root, (node) => {
        if (node.type !== 'split' || node.id !== splitID) return node;
        if (isCompletelyEmpty(node.first) && !isCompletelyEmpty(node.second)) {
          collapsed = true;
          return node.second;
        }
        if (isCompletelyEmpty(node.second) && !isCompletelyEmpty(node.first)) {
          collapsed = true;
          return node.first;
        }
        return node;
      });
      if (collapsed) {
        this.root = collapseDoubleEmpty(this.root);
      }
      return collapsed;
    }

    handleSeamDoubleClick(splitID) {
      if (this.collapseEmptyChild(splitID)) return true;
      return this.setRatio(splitID, 0.5);
    }

    equalizeSplits() {
      let changed = false;
      this.root = mapNode(this.root, (node) => {
        if (node.type !== 'split') return node;
        if (Math.abs(node.ratio - 0.5) > 0.001) changed = true;
        return { ...node, ratio: 0.5 };
      });
      return changed;
    }

    hasNonEqualSplits() {
      let found = false;
      const walk = (node) => {
        if (node.type !== 'split') return;
        if (Math.abs(node.ratio - 0.5) > 0.005) found = true;
        walk(node.first);
        walk(node.second);
      };
      walk(this.root);
      return found;
    }
  }

  // MARK: - SeamGeometry

  const SeamGeometry = {
    hitThickness: HIT_THICKNESS,
    visualThickness: VISUAL_THICKNESS,
    defaultMinLeafDimension: DEFAULT_MIN_LEAF_DIMENSION,
    minEmptySlotDimension: MIN_EMPTY_SLOT_DIMENSION,
    collapseThreshold: COLLAPSE_THRESHOLD,
    snapTolerancePoints: SNAP_TOLERANCE_PX,

    visualRect(axis, parentBounds, seamPosition) {
      const halfVis = VISUAL_THICKNESS * 0.5;
      if (axis === 'vertical') {
        return {
          x: seamPosition - halfVis,
          y: parentBounds.y,
          width: VISUAL_THICKNESS,
          height: parentBounds.height,
        };
      }
      return {
        x: parentBounds.x,
        y: seamPosition - halfVis,
        width: parentBounds.width,
        height: VISUAL_THICKNESS,
      };
    },

    seams(tree, bounds) {
      const result = [];
      const collect = (node, b, depth) => {
        if (node.type !== 'split') return;
        const { first, second, seamPosition } = splitFlush(b, node.axis, node.ratio);
        const halfHit = HIT_THICKNESS * 0.5;
        const halfVis = VISUAL_THICKNESS * 0.5;

        const hitRect =
          node.axis === 'vertical'
            ? { x: seamPosition - halfHit, y: b.y, width: HIT_THICKNESS, height: b.height }
            : { x: b.x, y: seamPosition - halfHit, width: b.width, height: HIT_THICKNESS };
        const visualRect =
          node.axis === 'vertical'
            ? { x: seamPosition - halfVis, y: b.y, width: VISUAL_THICKNESS, height: b.height }
            : { x: b.x, y: seamPosition - halfVis, width: b.width, height: VISUAL_THICKNESS };

        const winList = [];
        collectWindowIDs(node.first, winList);
        collectWindowIDs(node.second, winList);

        result.push({
          splitID: node.id,
          axis: node.axis,
          parentBounds: b,
          ratio: node.ratio,
          seamPosition,
          hitRect,
          visualRect,
          firstIsEmpty: isCompletelyEmpty(node.first),
          secondIsEmpty: isCompletelyEmpty(node.second),
          participatingWindowIDs: new Set(winList),
          depth,
        });

        collect(node.first, first, depth + 1);
        collect(node.second, second, depth + 1);
      };
      collect(tree.root, bounds, 0);
      return result;
    },

    hitTestTarget(point, seams) {
      const hitVerticals = [];
      const hitHorizontals = [];

      for (const seam of seams) {
        const expanded = rectInset(seam.hitRect, -HIT_THICKNESS * 0.5, -HIT_THICKNESS * 0.5);
        if (!rectContains(expanded, point)) continue;
        const dist = Math.abs(pointCoord(point, seam.axis) - seam.seamPosition);
        if (dist > HIT_THICKNESS * 0.5) continue;
        if (seam.axis === 'vertical') hitVerticals.push({ seam, dist });
        else hitHorizontals.push({ seam, dist });
      }

      const sortFn = (a, b) =>
        a.dist !== b.dist ? a.dist - b.dist : a.seam.depth - b.seam.depth;
      hitVerticals.sort(sortFn);
      hitHorizontals.sort(sortFn);

      if (hitVerticals.length > 0 && hitHorizontals.length > 0) {
        return {
          kind: 'intersection',
          verticals: hitVerticals.map((h) => h.seam),
          horizontals: hitHorizontals.map((h) => h.seam),
        };
      }
      if (hitVerticals.length > 0 && rectContains(hitVerticals[0].seam.hitRect, point)) {
        return { kind: 'single', seam: hitVerticals[0].seam };
      }
      if (hitHorizontals.length > 0 && rectContains(hitHorizontals[0].seam.hitRect, point)) {
        return { kind: 'single', seam: hitHorizontals[0].seam };
      }
      return null;
    },

    minimumExtent(node, axis, minSizes) {
      if (node.type === 'empty') return 0;
      if (node.type === 'window') {
        const s = minSizes.get(node.windowID);
        if (s) return Math.max(sizeSpan(s, axis), DEFAULT_MIN_LEAF_DIMENSION);
        return DEFAULT_MIN_LEAF_DIMENSION;
      }
      const firstMin = SeamGeometry.minimumExtent(node.first, axis, minSizes);
      const secondMin = SeamGeometry.minimumExtent(node.second, axis, minSizes);
      return node.axis === axis ? firstMin + secondMin : Math.max(firstMin, secondMin);
    },

    dragUpdate({
      pointer,
      seam,
      tree,
      minSizes,
      allSeams = [],
      disableSnapping = false,
      grabOffset = 0,
    }) {
      const parentStart = rectStart(seam.parentBounds, seam.axis);
      const parentLength = rectSpan(seam.parentBounds, seam.axis);
      const cursorCoord = pointCoord(pointer, seam.axis);

      if (parentLength <= 1) {
        return {
          ratio: seam.ratio,
          seamPosition: seam.seamPosition,
          visualRect: seam.visualRect,
          collapseTarget: null,
          isClamped: false,
          snapKind: null,
        };
      }

      const adjustedCoord = cursorCoord - grabOffset;
      const rawRatio = (adjustedCoord - parentStart) / parentLength;

      if (seam.firstIsEmpty && rawRatio <= 1 - COLLAPSE_THRESHOLD) {
        return {
          ratio: seam.ratio,
          seamPosition: parentStart,
          visualRect: SeamGeometry.visualRect(seam.axis, seam.parentBounds, parentStart),
          collapseTarget: { kind: 'collapseFirst', expandedBounds: seam.parentBounds },
          isClamped: false,
          snapKind: null,
        };
      }
      if (seam.secondIsEmpty && rawRatio >= COLLAPSE_THRESHOLD) {
        const endPos = parentStart + parentLength;
        return {
          ratio: seam.ratio,
          seamPosition: endPos,
          visualRect: SeamGeometry.visualRect(seam.axis, seam.parentBounds, endPos),
          collapseTarget: { kind: 'collapseSecond', expandedBounds: seam.parentBounds },
          isClamped: false,
          snapKind: null,
        };
      }

      let desiredRatio = rawRatio;
      let snapKind = null;

      if (!disableSnapping) {
        const parentEnd = parentStart + parentLength;
        let bestAligned = null;
        for (const other of allSeams) {
          if (
            other.axis !== seam.axis ||
            other.splitID === seam.splitID ||
            other.seamPosition <= parentStart ||
            other.seamPosition >= parentEnd
          ) {
            continue;
          }
          const dist = Math.abs(other.seamPosition - adjustedCoord);
          if (dist <= SNAP_TOLERANCE_PX) {
            if (!bestAligned || dist < bestAligned.dist) {
              bestAligned = { position: other.seamPosition, dist };
            }
          }
        }

        if (bestAligned) {
          desiredRatio = (bestAligned.position - parentStart) / parentLength;
          snapKind = { kind: 'alignedSeam', position: bestAligned.position };
        } else {
          const detents = [0.5, 1 / 3, 2 / 3];
          for (const d of detents) {
            const detentPos = parentStart + d * parentLength;
            if (Math.abs(detentPos - adjustedCoord) <= SNAP_TOLERANCE_PX) {
              desiredRatio = d;
              snapKind = { kind: 'detent', value: d };
              break;
            }
          }
        }
      }

      let minRatio = 0.08;
      let maxRatio = 0.92;
      const splitNode = tree.nodeWithID(seam.splitID);
      if (splitNode && splitNode.type === 'split') {
        const firstMinPx = isCompletelyEmpty(splitNode.first)
          ? MIN_EMPTY_SLOT_DIMENSION
          : SeamGeometry.minimumExtent(splitNode.first, seam.axis, minSizes);
        const secondMinPx = isCompletelyEmpty(splitNode.second)
          ? MIN_EMPTY_SLOT_DIMENSION
          : SeamGeometry.minimumExtent(splitNode.second, seam.axis, minSizes);

        const computedMin = firstMinPx / parentLength;
        const computedMax = 1 - secondMinPx / parentLength;

        if (computedMin <= computedMax) {
          minRatio = Math.max(0.05, computedMin);
          maxRatio = Math.min(0.95, computedMax);
        } else if (isCompletelyEmpty(splitNode.second) && !isCompletelyEmpty(splitNode.first)) {
          minRatio = Math.min(seam.ratio, 0.95);
          maxRatio = 0.95;
        } else if (isCompletelyEmpty(splitNode.first) && !isCompletelyEmpty(splitNode.second)) {
          minRatio = 0.05;
          maxRatio = Math.max(seam.ratio, 0.05);
        } else {
          minRatio = seam.ratio;
          maxRatio = seam.ratio;
        }
      }

      const clampedRatio = clamp(desiredRatio, minRatio, maxRatio);
      const isClamped = Math.abs(clampedRatio - desiredRatio) > 0.002;
      if (isClamped && snapKind) {
        if (snapKind.kind === 'detent' && Math.abs(clampedRatio - snapKind.value) > 0.002) {
          snapKind = null;
        } else if (snapKind.kind === 'alignedSeam') {
          const snapRatio = (snapKind.position - parentStart) / parentLength;
          if (Math.abs(clampedRatio - snapRatio) > 0.002) snapKind = null;
        }
      }

      const { seamPosition } = splitFlush(seam.parentBounds, seam.axis, clampedRatio);
      return {
        ratio: clampedRatio,
        seamPosition,
        visualRect: SeamGeometry.visualRect(seam.axis, seam.parentBounds, seamPosition),
        collapseTarget: null,
        isClamped,
        snapKind,
      };
    },
  };

  // MARK: - DropPlanner

  function feasibleSplitRatio(parentLength, firstMinPx, secondMinPx, preferredRatio = 0.5) {
    if (parentLength <= 1) return null;
    if (firstMinPx + secondMinPx > parentLength + 0.5) return null;
    const minRatio = Math.max(0.05, firstMinPx / parentLength);
    const maxRatio = Math.min(0.95, 1 - secondMinPx / parentLength);
    if (minRatio > maxRatio) return null;
    return clamp(preferredRatio, minRatio, maxRatio);
  }

  function distanceFromEdge(edge, point, rect) {
    if (edge === 'left') return point.x - rect.x;
    if (edge === 'right') return rect.x + rect.width - point.x;
    if (edge === 'top') return point.y - rect.y;
    return rect.y + rect.height - point.y;
  }

  function preferredSplitRatio(edge, pointer, cell) {
    const span = rectSpan(cell, edgeAxis(edge));
    const thirdBand = Math.min(span * THIRD_EDGE_FRACTION, MAX_THIRD_EDGE_PX);
    if (thirdBand > 0 && distanceFromEdge(edge, pointer, cell) <= thirdBand) {
      return edgeIsFirstChild(edge) ? 1 / 3 : 2 / 3;
    }
    return 0.5;
  }

  function splitRectOf(cell, edge, ratio = 0.5) {
    const { first, second } = splitFlush(cell, edgeAxis(edge), ratio);
    return edgeIsFirstChild(edge) ? first : second;
  }

  function edgeBandCandidates(point, rect, fraction, maxPixels) {
    const bandX = Math.min(rect.width * fraction, maxPixels);
    const bandY = Math.min(rect.height * fraction, maxPixels);
    const dLeft = point.x - rect.x;
    const dRight = rect.x + rect.width - point.x;
    const dTop = point.y - rect.y;
    const dBottom = rect.y + rect.height - point.y;

    const candidates = [];
    if (dLeft <= bandX && bandX > 0) candidates.push(['left', dLeft / bandX]);
    if (dRight <= bandX && bandX > 0) candidates.push(['right', dRight / bandX]);
    if (dTop <= bandY && bandY > 0) candidates.push(['top', dTop / bandY]);
    if (dBottom <= bandY && bandY > 0) candidates.push(['bottom', dBottom / bandY]);
    candidates.sort((a, b) => a[1] - b[1]);
    return candidates.map((c) => c[0]);
  }

  function nearestEdge(point, rect) {
    const nx = (point.x - rect.x) / rect.width;
    const ny = (point.y - rect.y) / rect.height;
    const distances = [
      ['left', nx],
      ['right', 1 - nx],
      ['top', ny],
      ['bottom', 1 - ny],
    ];
    distances.sort((a, b) => a[1] - b[1]);
    return distances[0][0];
  }

  function nodeBoundsOf(targetID, node, bounds) {
    if (node.id === targetID) return bounds;
    if (node.type !== 'split') return null;
    const { first, second } = splitFlush(bounds, node.axis, node.ratio);
    return nodeBoundsOf(targetID, node.first, first) || nodeBoundsOf(targetID, node.second, second);
  }

  function simulatedPreviewRect(tree, draggedWindowID, screenBounds, fallback, applyFn) {
    const oldLeafID = tree.leafID(draggedWindowID);
    if (oldLeafID === null) return fallback;
    const sim = tree.clone();
    if (!applyFn(sim)) return fallback;
    sim.removeLeafAndCollapse(oldLeafID);
    return sim.windowFrames(screenBounds).get(draggedWindowID) || fallback;
  }

  function tJunctionHit(pointer, rootNode, bounds) {
    let best = null;
    const collect = (node, b, depth) => {
      if (node.type !== 'split') return;
      if (!rectContains(b, pointer)) return;
      const { first, second, seamPosition } = splitFlush(b, node.axis, node.ratio);

      if (!isCompletelyEmpty(node.first) && !isCompletelyEmpty(node.second)) {
        let zones = [];
        if (node.axis === 'vertical') {
          const halfSpan = Math.min(
            T_JUNCTION_HALF_SPAN,
            Math.min(first.width, second.width) * 0.45
          );
          const depthPx = Math.min(T_JUNCTION_MAX_DEPTH, b.height * 0.18);
          const thirdDepth = Math.min(T_JUNCTION_THIRD_MAX_DEPTH, depthPx * 0.4);
          zones = [
            {
              edge: 'top',
              rect: { x: seamPosition - halfSpan, y: b.y, width: halfSpan * 2, height: depthPx },
              anchor: { x: seamPosition, y: b.y },
              thirdDepth,
            },
            {
              edge: 'bottom',
              rect: {
                x: seamPosition - halfSpan,
                y: b.y + b.height - depthPx,
                width: halfSpan * 2,
                height: depthPx,
              },
              anchor: { x: seamPosition, y: b.y + b.height },
              thirdDepth,
            },
          ];
        } else {
          const halfSpan = Math.min(
            T_JUNCTION_HALF_SPAN,
            Math.min(first.height, second.height) * 0.45
          );
          const depthPx = Math.min(T_JUNCTION_MAX_DEPTH, b.width * 0.18);
          const thirdDepth = Math.min(T_JUNCTION_THIRD_MAX_DEPTH, depthPx * 0.4);
          zones = [
            {
              edge: 'left',
              rect: { x: b.x, y: seamPosition - halfSpan, width: depthPx, height: halfSpan * 2 },
              anchor: { x: b.x, y: seamPosition },
              thirdDepth,
            },
            {
              edge: 'right',
              rect: {
                x: b.x + b.width - depthPx,
                y: seamPosition - halfSpan,
                width: depthPx,
                height: halfSpan * 2,
              },
              anchor: { x: b.x + b.width, y: seamPosition },
              thirdDepth,
            },
          ];
        }

        for (const z of zones) {
          if (!rectContains(z.rect, pointer)) continue;
          const dist = Math.hypot(pointer.x - z.anchor.x, pointer.y - z.anchor.y);
          const edgeDist = distanceFromEdge(z.edge, pointer, b);
          const candidate = {
            nodeID: node.id,
            edge: z.edge,
            containerBounds: b,
            distance: dist,
            depth,
            isThird: z.thirdDepth > 0 && edgeDist <= z.thirdDepth,
          };
          if (!best) {
            best = candidate;
          } else if (
            dist < best.distance - 1 ||
            (Math.abs(dist - best.distance) <= 1 && depth > best.depth)
          ) {
            best = candidate;
          }
        }
      }

      collect(node.first, first, depth + 1);
      collect(node.second, second, depth + 1);
    };
    collect(rootNode, bounds, 0);
    return best;
  }

  function tJunctionSplitRatio(tHit, draggedWindowID, tree, screenBounds, minSizes) {
    let effectiveBounds = tHit.containerBounds;
    let existingNode = tree.nodeWithID(tHit.nodeID);
    const oldLeafID = tree.leafID(draggedWindowID);

    if (oldLeafID !== null) {
      let promotedSiblingID = null;
      const targetNode = tree.nodeWithID(tHit.nodeID);
      if (targetNode && targetNode.type === 'split') {
        if (targetNode.first.id === oldLeafID) promotedSiblingID = targetNode.second.id;
        else if (targetNode.second.id === oldLeafID) promotedSiblingID = targetNode.first.id;
      }

      const collapsed = tree.clone();
      collapsed.removeLeafAndCollapse(oldLeafID);
      const surviving = collapsed.nodeWithID(tHit.nodeID);
      if (surviving) {
        existingNode = surviving;
        effectiveBounds =
          nodeBoundsOf(tHit.nodeID, collapsed.root, screenBounds) || tHit.containerBounds;
      } else if (promotedSiblingID !== null && collapsed.nodeWithID(promotedSiblingID)) {
        existingNode = collapsed.nodeWithID(promotedSiblingID);
        effectiveBounds =
          nodeBoundsOf(promotedSiblingID, collapsed.root, screenBounds) || tHit.containerBounds;
      } else {
        existingNode = null;
      }
    }

    const axis = edgeAxis(tHit.edge);
    const draggedMin = SeamGeometry.minimumExtent(
      { type: 'window', id: 0, windowID: draggedWindowID },
      axis,
      minSizes
    );
    const containerMin = existingNode
      ? SeamGeometry.minimumExtent(existingNode, axis, minSizes)
      : DEFAULT_MIN_LEAF_DIMENSION;
    const length = rectSpan(effectiveBounds, axis);
    const firstMin = edgeIsFirstChild(tHit.edge) ? draggedMin : containerMin;
    const secondMin = edgeIsFirstChild(tHit.edge) ? containerMin : draggedMin;
    const preferred = tHit.isThird ? (edgeIsFirstChild(tHit.edge) ? 1 / 3 : 2 / 3) : 0.5;
    return feasibleSplitRatio(length, firstMin, secondMin, preferred);
  }

  const DropPlanner = {
    plan({ pointer, draggedWindowID, tree, screenBounds, isDraggedWindowTiled, minSizes }) {
      if (!rectContains(screenBounds, pointer)) return null;

      const draggedMinForAxis = (axis) =>
        SeamGeometry.minimumExtent(
          { type: 'window', id: 0, windowID: draggedWindowID },
          axis,
          minSizes
        );

      // 1. T-junction split container
      const tHit = tJunctionHit(pointer, tree.root, screenBounds);
      if (tHit) {
        const ratio = tJunctionSplitRatio(tHit, draggedWindowID, tree, screenBounds, minSizes);
        if (ratio !== null) {
          const fallbackPreview = splitRectOf(tHit.containerBounds, tHit.edge, ratio);
          const preview = simulatedPreviewRect(
            tree,
            draggedWindowID,
            screenBounds,
            fallbackPreview,
            (sim) => sim.splitNode(tHit.nodeID, tHit.edge, ratio, draggedWindowID)
          );
          return {
            action: { type: 'splitNode', nodeID: tHit.nodeID, edge: tHit.edge },
            previewRect: preview,
            previewKind: 'splitContainer',
            splitRatio: ratio,
          };
        }
      }

      const leaf = tree.leafAt(pointer, screenBounds);
      if (!leaf) return null;
      const cell = leaf.frame;
      if (cell.width <= 1 || cell.height <= 1) return null;

      // Case 1: Empty slot
      if (leaf.isEmpty) {
        const oldLeafID = tree.leafID(draggedWindowID);
        let effectiveCellForCollapse = cell;
        if (oldLeafID !== null) {
          const sim = tree.clone();
          if (sim.fillEmpty(leaf.leafID, draggedWindowID)) {
            sim.removeLeafAndCollapse(oldLeafID);
            effectiveCellForCollapse = sim.windowFrames(screenBounds).get(draggedWindowID) || cell;
          }
        }

        const candidates = edgeBandCandidates(pointer, cell, EMPTY_EDGE_FRACTION, MAX_EMPTY_EDGE_PX);
        for (const edge of candidates) {
          const axis = edgeAxis(edge);
          const winMin = draggedMinForAxis(axis);
          const emptyMin = DEFAULT_MIN_LEAF_DIMENSION;
          const parentLength = rectSpan(effectiveCellForCollapse, axis);
          const firstMin = edgeIsFirstChild(edge) ? winMin : emptyMin;
          const secondMin = edgeIsFirstChild(edge) ? emptyMin : winMin;
          const preferred = preferredSplitRatio(edge, pointer, cell);
          const ratio = feasibleSplitRatio(parentLength, firstMin, secondMin, preferred);
          if (ratio !== null) {
            const fallbackPreview = splitRectOf(effectiveCellForCollapse, edge, ratio);
            const preview = simulatedPreviewRect(
              tree,
              draggedWindowID,
              screenBounds,
              fallbackPreview,
              (sim) => sim.splitEmpty(leaf.leafID, edge, ratio, draggedWindowID)
            );
            return {
              action: { type: 'splitEmpty', leafID: leaf.leafID, edge },
              previewRect: preview,
              previewKind: 'split',
              splitRatio: ratio,
            };
          }
        }

        const collapsesOldOnFill =
          oldLeafID !== null ? !tree.areDirectSiblings(oldLeafID, leaf.leafID) : false;
        return {
          action: { type: 'fillEmpty', leafID: leaf.leafID },
          previewRect: collapsesOldOnFill ? effectiveCellForCollapse : cell,
          previewKind: 'fill',
          splitRatio: 0.5,
        };
      }

      const occupant = leaf.windowID;

      // Case 2: Own slot
      if (occupant === draggedWindowID) {
        const candidates = edgeBandCandidates(pointer, cell, EMPTY_EDGE_FRACTION, MAX_EMPTY_EDGE_PX);
        for (const edge of candidates) {
          const axis = edgeAxis(edge);
          const winMin = draggedMinForAxis(axis);
          const emptyMin = DEFAULT_MIN_LEAF_DIMENSION;
          const parentLength = rectSpan(cell, axis);
          const firstMin = edgeIsFirstChild(edge) ? winMin : emptyMin;
          const secondMin = edgeIsFirstChild(edge) ? emptyMin : winMin;
          const preferred = preferredSplitRatio(edge, pointer, cell);
          const ratio = feasibleSplitRatio(parentLength, firstMin, secondMin, preferred);
          if (ratio !== null) {
            return {
              action: { type: 'shrinkOwnSlot', leafID: leaf.leafID, edge },
              previewRect: splitRectOf(cell, edge, ratio),
              previewKind: 'split',
              splitRatio: ratio,
            };
          }
        }
        return {
          action: { type: 'keepInPlace', leafID: leaf.leafID },
          previewRect: cell,
          previewKind: 'fill',
          splitRatio: 0.5,
        };
      }

      // Case 3: Occupied slot belonging to another window
      const centerInsetX = cell.width * (1 - OCCUPIED_CENTER_FRACTION) * 0.5;
      const centerInsetY = cell.height * (1 - OCCUPIED_CENTER_FRACTION) * 0.5;
      const centerRect = rectInset(cell, centerInsetX, centerInsetY);
      const isTiled =
        typeof isDraggedWindowTiled === 'boolean'
          ? isDraggedWindowTiled
          : tree.contains(draggedWindowID);

      if (rectContains(centerRect, pointer)) {
        return {
          action: { type: 'swapOrReplace', leafID: leaf.leafID, targetWindowID: occupant },
          previewRect: cell,
          previewKind: isTiled ? 'swap' : 'replace',
          splitRatio: 0.5,
        };
      }

      let effectiveCell = cell;
      const oldLeafID = tree.leafID(draggedWindowID);
      if (oldLeafID !== null) {
        const collapsed = tree.clone();
        collapsed.removeLeafAndCollapse(oldLeafID);
        effectiveCell = collapsed.windowFrames(screenBounds).get(occupant) || cell;
      }

      const ratioForOccupiedEdge = (edge) => {
        const axis = edgeAxis(edge);
        const draggedMin = draggedMinForAxis(axis);
        const occupantMin = SeamGeometry.minimumExtent(
          { type: 'window', id: 0, windowID: occupant },
          axis,
          minSizes
        );
        const effectiveLength = rectSpan(effectiveCell, axis);
        const firstMin = edgeIsFirstChild(edge) ? draggedMin : occupantMin;
        const secondMin = edgeIsFirstChild(edge) ? occupantMin : draggedMin;
        const preferred = preferredSplitRatio(edge, pointer, cell);
        return feasibleSplitRatio(effectiveLength, firstMin, secondMin, preferred);
      };

      const canSplitV = ratioForOccupiedEdge('left') !== null;
      const canSplitH = ratioForOccupiedEdge('top') !== null;

      let chosenEdge = null;
      if (canSplitV && canSplitH) {
        chosenEdge = nearestEdge(pointer, cell);
      } else if (canSplitH) {
        if (pointer.y < centerRect.y) chosenEdge = 'top';
        else if (pointer.y > centerRect.y + centerRect.height) chosenEdge = 'bottom';
      } else if (canSplitV) {
        if (pointer.x < centerRect.x) chosenEdge = 'left';
        else if (pointer.x > centerRect.x + centerRect.width) chosenEdge = 'right';
      }

      const ratio = chosenEdge ? ratioForOccupiedEdge(chosenEdge) : null;
      if (!chosenEdge || ratio === null) {
        return {
          action: { type: 'swapOrReplace', leafID: leaf.leafID, targetWindowID: occupant },
          previewRect: cell,
          previewKind: isTiled ? 'swap' : 'replace',
          splitRatio: 0.5,
        };
      }

      const fallbackPreview = splitRectOf(effectiveCell, chosenEdge, ratio);
      const preview = simulatedPreviewRect(
        tree,
        draggedWindowID,
        screenBounds,
        fallbackPreview,
        (sim) => sim.splitOccupied(leaf.leafID, chosenEdge, ratio, draggedWindowID)
      );
      return {
        action: { type: 'splitOccupied', leafID: leaf.leafID, edge: chosenEdge },
        previewRect: preview,
        previewKind: 'split',
        splitRatio: ratio,
      };
    },
  };

  // MARK: - SpaceLayoutStore (single-space playground store with quit/relaunch history)

  class SpaceLayoutStore {
    constructor() {
      this.tree = new LayoutTree();
      this.revision = 0;
      this.savedFloatingFrames = new Map();
      this.minSizes = new Map();
      this.quitSnapshots = new Map(); // windowID -> { treeBefore, revisionAfter, savedFloatingFrame }
    }

    isTiled(windowID) {
      return this.tree.contains(windowID);
    }

    setMinSize(windowID, size) {
      this.minSizes.set(windowID, size);
    }

    setTree(newTree) {
      this.tree = newTree;
      this.revision += 1;
    }

    clear() {
      this.tree = new LayoutTree();
      this.revision += 1;
    }

    visibleSeams(bounds) {
      if (this.tree.isEmpty) return [];
      return SeamGeometry.seams(this.tree, bounds);
    }

    planDrop(pointer, draggedWindowID, screenBounds) {
      return DropPlanner.plan({
        pointer,
        draggedWindowID,
        tree: this.tree,
        screenBounds,
        isDraggedWindowTiled: this.isTiled(draggedWindowID),
        minSizes: this.minSizes,
      });
    }

    commitDrop(plan, draggedWindowID, preDragFrame, screenBounds) {
      const wasTiled = this.isTiled(draggedWindowID);
      if (!wasTiled && !this.savedFloatingFrames.has(draggedWindowID)) {
        this.savedFloatingFrames.set(draggedWindowID, { ...preDragFrame });
      }

      const detached = new Map();
      const t = this.tree.clone();
      const oldLeafID = wasTiled ? t.leafID(draggedWindowID) : null;
      const act = plan.action;

      if (act.type === 'keepInPlace') {
        // nothing to mutate
      } else if (act.type === 'shrinkOwnSlot') {
        t.shrinkToEdge(act.leafID, act.edge, plan.splitRatio);
      } else if (act.type === 'fillEmpty') {
        const preserveSibling =
          oldLeafID !== null ? t.areDirectSiblings(oldLeafID, act.leafID) : false;
        t.fillEmpty(act.leafID, draggedWindowID);
        if (oldLeafID !== null) {
          if (preserveSibling) t.removeLeaf(oldLeafID);
          else t.removeLeafAndCollapse(oldLeafID);
        }
      } else if (act.type === 'splitEmpty') {
        t.splitEmpty(act.leafID, act.edge, plan.splitRatio, draggedWindowID);
        if (oldLeafID !== null) t.removeLeafAndCollapse(oldLeafID);
      } else if (act.type === 'splitOccupied') {
        t.splitOccupied(act.leafID, act.edge, plan.splitRatio, draggedWindowID);
        if (oldLeafID !== null) t.removeLeafAndCollapse(oldLeafID);
      } else if (act.type === 'splitNode') {
        t.splitNode(act.nodeID, act.edge, plan.splitRatio, draggedWindowID);
        if (oldLeafID !== null) t.removeLeafAndCollapse(oldLeafID);
      } else if (act.type === 'swapOrReplace') {
        if (wasTiled) {
          t.swapWindows(draggedWindowID, act.targetWindowID);
        } else {
          const displaced = t.replaceWindow(act.leafID, draggedWindowID);
          if (displaced !== null) {
            const restored = this.savedFloatingFrames.get(displaced);
            this.savedFloatingFrames.delete(displaced);
            if (restored) {
              detached.set(displaced, { ...restored });
            } else {
              const fw = Math.round(Math.min(440, screenBounds.width * 0.55));
              const fh = Math.round(Math.min(310, screenBounds.height * 0.62));
              detached.set(displaced, {
                x: Math.round(screenBounds.x + (screenBounds.width - fw) * 0.5),
                y: Math.round(screenBounds.y + (screenBounds.height - fh) * 0.5),
                width: fw,
                height: fh,
              });
            }
          }
        }
      }

      this.setTree(t);
      return {
        framesToApply: this.tree.windowFrames(screenBounds),
        detachedWindows: detached,
      };
    }

    detachByUserDrag(windowID, currentFrame, cursor, screenBounds) {
      if (!this.isTiled(windowID)) return null;
      const previousTree = this.tree.clone();
      const savedFrame = this.savedFloatingFrames.get(windowID) || null;
      this.savedFloatingFrames.delete(windowID);

      const t = this.tree.clone();
      t.removeWindowAndCollapse(windowID);
      this.setTree(t);

      let restoredFrame = null;
      if (savedFrame) {
        restoredFrame = restoredUnderCursor(
          { width: savedFrame.width, height: savedFrame.height },
          currentFrame,
          cursor
        );
      } else if (
        screenBounds &&
        currentFrame.width * currentFrame.height >= screenBounds.width * screenBounds.height * 0.85
      ) {
        restoredFrame = restoredUnderCursor(
          {
            width: Math.round(Math.min(460, screenBounds.width * 0.58)),
            height: Math.round(Math.min(320, screenBounds.height * 0.64)),
          },
          currentFrame,
          cursor
        );
      }

      return {
        restoredFrame,
        framesToApply: this.tree.windowFrames(screenBounds),
        undo: {
          previousTree,
          windowID,
          savedFloatingFrame: savedFrame ? { ...savedFrame } : null,
        },
      };
    }

    restoreDetachUndo(undo, screenBounds) {
      this.setTree(undo.previousTree.clone());
      if (undo.savedFloatingFrame) {
        this.savedFloatingFrames.set(undo.windowID, { ...undo.savedFloatingFrame });
      }
      return this.tree.windowFrames(screenBounds);
    }

    closeWindow(windowID, screenBounds) {
      if (!this.isTiled(windowID)) return null;
      const treeBefore = this.tree.clone();
      const savedFrame = this.savedFloatingFrames.get(windowID) || null;
      const t = this.tree.clone();
      t.removeWindowAndCollapse(windowID);
      this.setTree(t);
      this.quitSnapshots.set(windowID, {
        treeBefore,
        revisionAfter: this.revision,
        savedFloatingFrame: savedFrame ? { ...savedFrame } : null,
      });
      return this.tree.windowFrames(screenBounds);
    }

    relaunchWindow(windowID, screenBounds) {
      const snap = this.quitSnapshots.get(windowID);
      if (!snap) return null;
      this.quitSnapshots.delete(windowID);
      // Only restore if the Space hasn't changed since the app quit
      if (snap.revisionAfter !== this.revision) return null;
      this.setTree(snap.treeBefore.clone());
      if (snap.savedFloatingFrame) {
        this.savedFloatingFrames.set(windowID, { ...snap.savedFloatingFrame });
      }
      return this.tree.windowFrames(screenBounds);
    }
  }

  const api = {
    splitFlush,
    restoredUnderCursor,
    LayoutTree,
    DropPlanner,
    SeamGeometry,
    SpaceLayoutStore,
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else {
    root.SeamstressCore = api;
  }
})(typeof globalThis !== 'undefined' ? globalThis : window);
