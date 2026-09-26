// A chat window that can be resized from any edge or corner and moved by its
// title bar, like a desktop window (ChatWidget.jsx).
//
// The window starts docked above the chat button, at a preset size. The
// first drag of an edge or the title bar turns it into a free window at
// that spot. The expand button docks it again. The geometry reaches the
// stylesheet as four CSS variables (--chat-widget-left/-top/-width/-height):
// a place and size the visitor drags to can't be written in the stylesheet
// ahead of time.
import { useEffect, useRef, useState } from 'react';

const STORAGE_KEY = 'ae-rv-chat-size';
const MIN_WIDTH = 300;
const MIN_HEIGHT = 320;
const MARGIN = 8; // the window stays this far inside the browser window (px)
const KEY_STEP = 40; // arrow keys resize or move by this much (px)
// Phones: the window spans the screen, so nothing to drag (matches the
// stylesheet's breakpoint).
const PHONE = '(max-width: 640px)';

// The resize directions the window's edge and corner handles use.
export const EDGES = ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw'];

// Keeps a free window's rect usable and on screen.
// `mode` 'move' keeps the size and slides the window back on screen;
// anything else is a resize, where an edge that hits the browser window
// stops there and the opposite edge stays put.
export function clampRect(rect, mode = 'move') {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const maxWidth = Math.max(MIN_WIDTH, vw - 2 * MARGIN);
  const maxHeight = Math.max(MIN_HEIGHT, vh - 2 * MARGIN);
  let { left, top, width, height } = rect;
  if (mode === 'move') {
    width = Math.min(Math.max(width, MIN_WIDTH), maxWidth);
    height = Math.min(Math.max(height, MIN_HEIGHT), maxHeight);
  } else {
    if (left < MARGIN) {
      width -= MARGIN - left;
      left = MARGIN;
    }
    if (top < MARGIN) {
      height -= MARGIN - top;
      top = MARGIN;
    }
    width = Math.min(Math.max(Math.min(width, vw - MARGIN - left), MIN_WIDTH), maxWidth);
    height = Math.min(Math.max(Math.min(height, vh - MARGIN - top), MIN_HEIGHT), maxHeight);
  }
  left = Math.max(MARGIN, Math.min(left, vw - MARGIN - width));
  top = Math.max(MARGIN, Math.min(top, vh - MARGIN - height));
  return { left: Math.round(left), top: Math.round(top), width: Math.round(width), height: Math.round(height) };
}

// The rect after dragging by (dx, dy) with a handle ('move' or an edge).
export function dragRect(start, mode, dx, dy) {
  let { left, top, width, height } = start;
  if (mode === 'move') return clampRect({ left: left + dx, top: top + dy, width, height }, 'move');
  if (mode.includes('e')) width += dx;
  if (mode.includes('s')) height += dy;
  if (mode.includes('w')) {
    width = Math.max(MIN_WIDTH, width - dx);
    left = start.left + start.width - width;
  }
  if (mode.includes('n')) {
    height = Math.max(MIN_HEIGHT, height - dy);
    top = start.top + start.height - height;
  }
  return clampRect({ left, top, width, height }, mode);
}

function load() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? 'null');
    if (saved === 'expanded' || saved === 'compact') return saved;
    if (['left', 'top', 'width', 'height'].every((k) => Number.isFinite(saved?.[k]))) return saved;
  } catch {
    // Storage blocked or unreadable: the default size.
  }
  return null;
}

function save(size) {
  try {
    if (size) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(size));
  } catch {
    // Storage blocked: the size just resets on the next page.
  }
}

function setVars(panel, rect) {
  if (!panel) return;
  for (const key of ['left', 'top', 'width', 'height']) {
    if (rect) panel.style.setProperty(`--chat-widget-${key}`, `${rect[key]}px`);
    else panel.style.removeProperty(`--chat-widget-${key}`);
  }
}

// `defaultLarge`: the docked size before the visitor picks one. Returns:
//   mode       'compact' | 'expanded' | 'free'
//   toggle()   the expand button: dock, large <-> small
//   edgeProps(edge), moveProps   pointer handlers for the handles and the
//                                title bar
//   onKeyDown  for the keyboard handle: arrows resize, Shift+arrows move
export function useFloatingWindow(panelRef, open, defaultLarge) {
  const [size, setSize] = useState(load);
  const dragRef = useRef(null);
  const free = Boolean(size) && typeof size === 'object';
  const mode = free ? 'free' : (size ?? (defaultLarge ? 'expanded' : 'compact'));

  useEffect(() => save(size), [size]);

  // The panel only exists while the window is open.
  useEffect(() => setVars(panelRef.current, free ? size : null), [open, size]);

  // Keep a free window on screen when the browser window changes size.
  useEffect(() => {
    if (!free) return;
    const onResize = () =>
      setSize((current) => (current && typeof current === 'object' ? clampRect(current, 'move') : current));
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, [free]);

  function currentRect() {
    const r = panelRef.current.getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height };
  }

  function start(dragMode, event) {
    if (!panelRef.current || event.button !== 0 || window.matchMedia(PHONE).matches) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    const rect = clampRect(currentRect(), 'move');
    dragRef.current = { mode: dragMode, x: event.clientX, y: event.clientY, rect };
    setSize(rect);
    setVars(panelRef.current, rect);
  }

  function move(event) {
    const drag = dragRef.current;
    if (!drag) return;
    drag.last = dragRect(drag.rect, drag.mode, event.clientX - drag.x, event.clientY - drag.y);
    setVars(panelRef.current, drag.last);
  }

  function end() {
    const drag = dragRef.current;
    dragRef.current = null;
    if (drag?.last) setSize(drag.last);
  }

  const handlers = (dragMode) => ({
    onPointerDown: (event) => start(dragMode, event),
    onPointerMove: move,
    onPointerUp: end,
    onPointerCancel: end,
  });

  return {
    mode,
    toggle: () => setSize(mode === 'compact' ? 'expanded' : 'compact'),
    edgeProps: handlers,
    // The title bar moves the window, except where it has buttons.
    moveProps: {
      ...handlers('move'),
      onPointerDown: (event) => {
        if (!event.target.closest('button')) start('move', event);
      },
    },
    onKeyDown(event) {
      const step = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
      if (!step || !panelRef.current) return;
      event.preventDefault();
      const rect = currentRect();
      const [dx, dy] = [step[0] * KEY_STEP, step[1] * KEY_STEP];
      // The handle is the top-left corner: left/up makes the window bigger.
      setSize(event.shiftKey ? dragRect(rect, 'move', dx, dy) : dragRect(rect, 'nw', dx, dy));
    },
  };
}
