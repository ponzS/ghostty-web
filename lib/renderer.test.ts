/**
 * Tests for Canvas Renderer
 *
 * Note: Most renderer tests are visual and require a browser environment.
 * These tests verify non-visual aspects like theme configuration.
 * Full visual tests are in examples/renderer-demo.html
 */

import { describe, expect, test } from 'bun:test';
import { CanvasRenderer, DEFAULT_THEME } from './renderer';
import type { IRenderable, IScrollbackProvider } from './renderer';
import type { GhosttyCell } from './types';

function cell(codepoint: number = 32): GhosttyCell {
  return {
    codepoint,
    fg_r: 204,
    fg_g: 204,
    fg_b: 204,
    bg_r: 0,
    bg_g: 0,
    bg_b: 0,
    flags: 0,
    width: 1,
    hyperlink_id: 0,
    grapheme_len: 0,
  };
}

function rendererHarness() {
  const canvas = document.createElement('canvas');
  const context = canvas.getContext('2d') as CanvasRenderingContext2D;
  let drawCalls = 0;
  context.fillRect = () => {
    drawCalls++;
  };
  context.clearRect = () => {
    drawCalls++;
  };
  context.fillText = () => {
    drawCalls++;
  };
  canvas.getContext = (() => context) as typeof canvas.getContext;
  return {
    renderer: new CanvasRenderer(canvas, { devicePixelRatio: 1 }),
    drawCalls: () => drawCalls,
  };
}

function renderable(cols: number, rows: number) {
  const viewport = Array.from({ length: cols * rows }, (_, index) => cell(65 + index));
  let viewportReads = 0;
  let lineReads = 0;
  let cleanCalls = 0;
  const buffer: IRenderable = {
    getViewport: () => {
      viewportReads++;
      return viewport;
    },
    getLine: (row) => {
      lineReads++;
      const start = row * cols;
      return viewport.slice(start, start + cols);
    },
    getCursor: () => ({ x: 0, y: 0, visible: false }),
    getDimensions: () => ({ cols, rows }),
    isRowDirty: () => true,
    needsFullRedraw: () => true,
    clearDirty: () => {
      cleanCalls++;
    },
  };
  return {
    buffer,
    viewportReads: () => viewportReads,
    lineReads: () => lineReads,
    cleanCalls: () => cleanCalls,
  };
}

describe('CanvasRenderer', () => {
  describe('Default Theme', () => {
    test('has all required ANSI colors', () => {
      expect(DEFAULT_THEME.black).toBe('#000000');
      expect(DEFAULT_THEME.red).toBe('#cd3131');
      expect(DEFAULT_THEME.green).toBe('#0dbc79');
      expect(DEFAULT_THEME.yellow).toBe('#e5e510');
      expect(DEFAULT_THEME.blue).toBe('#2472c8');
      expect(DEFAULT_THEME.magenta).toBe('#bc3fbc');
      expect(DEFAULT_THEME.cyan).toBe('#11a8cd');
      expect(DEFAULT_THEME.white).toBe('#e5e5e5');
    });

    test('has all bright ANSI colors', () => {
      expect(DEFAULT_THEME.brightBlack).toBe('#666666');
      expect(DEFAULT_THEME.brightRed).toBe('#f14c4c');
      expect(DEFAULT_THEME.brightGreen).toBe('#23d18b');
      expect(DEFAULT_THEME.brightYellow).toBe('#f5f543');
      expect(DEFAULT_THEME.brightBlue).toBe('#3b8eea');
      expect(DEFAULT_THEME.brightMagenta).toBe('#d670d6');
      expect(DEFAULT_THEME.brightCyan).toBe('#29b8db');
      expect(DEFAULT_THEME.brightWhite).toBe('#ffffff');
    });

    test('has foreground and background colors', () => {
      expect(DEFAULT_THEME.foreground).toBe('#d4d4d4');
      expect(DEFAULT_THEME.background).toBe('#1e1e1e');
    });

    test('has cursor colors', () => {
      expect(DEFAULT_THEME.cursor).toBe('#ffffff');
      expect(DEFAULT_THEME.cursorAccent).toBe('#1e1e1e');
    });

    test('has selection colors', () => {
      // Selection colors are now solid (not semi-transparent overlay)
      // Ghostty-style: selection bg = foreground color, selection fg = background color
      expect(DEFAULT_THEME.selectionBackground).toBe('#d4d4d4');
      expect(DEFAULT_THEME.selectionForeground).toBe('#1e1e1e');
    });
  });

  describe('Theme Color Format', () => {
    test('all colors are valid hex strings', () => {
      const hexPattern = /^#[0-9a-f]{6}$/i;

      expect(DEFAULT_THEME.black).toMatch(hexPattern);
      expect(DEFAULT_THEME.foreground).toMatch(hexPattern);
      expect(DEFAULT_THEME.background).toMatch(hexPattern);
      expect(DEFAULT_THEME.cursor).toMatch(hexPattern);
    });
  });

  describe('Scrollbar hover sizing', () => {
    test('expands from the compact width while keeping the right edge fixed', () => {
      const harness = rendererHarness();

      expect(harness.renderer.getScrollbarWidth()).toBe(3);
      harness.renderer.setScrollbarHoverProgress(0.5);
      expect(harness.renderer.getScrollbarWidth()).toBe(5.5);
      harness.renderer.setScrollbarHoverProgress(1);
      expect(harness.renderer.getScrollbarWidth()).toBe(8);
    });
  });

  describe('Atomic viewport materialization', () => {
    test('exports the active viewport once per frame', () => {
      const harness = rendererHarness();
      const terminal = renderable(4, 3);

      expect(harness.renderer.render(terminal.buffer, true)).toBe(true);
      expect(terminal.viewportReads()).toBe(1);
      expect(terminal.lineReads()).toBe(0);
      expect(terminal.cleanCalls()).toBe(1);
    });

    test('keeps the previous canvas when any visible history row is unavailable', () => {
      const harness = rendererHarness();
      const terminal = renderable(2, 3);
      expect(harness.renderer.render(terminal.buffer, true)).toBe(true);
      const committedDrawCalls = harness.drawCalls();

      const provider: IScrollbackProvider = {
        getScrollbackLength: () => 3,
        getScrollbackLine: (offset) => (offset === 1 ? null : [cell(72), cell(73)]),
      };

      expect(harness.renderer.render(terminal.buffer, true, 3, provider)).toBe(false);
      expect(harness.drawCalls()).toBe(committedDrawCalls);
      expect(terminal.cleanCalls()).toBe(1);
    });

    test('uses integer viewport rows for fractional scrollback mapping', () => {
      const harness = rendererHarness();
      const terminal = renderable(1, 2);
      const offsets: number[] = [];
      const provider: IScrollbackProvider = {
        getScrollbackLength: () => 5,
        getScrollbackLine: (offset) => {
          offsets.push(offset);
          return [cell(80 + offset)];
        },
      };

      expect(harness.renderer.render(terminal.buffer, true, 1.5, provider)).toBe(true);
      expect(offsets).toEqual([4]);
      expect(offsets).not.toContain(5);
    });
  });
});
