import { describe, expect, test } from 'bun:test';
import { Ghostty, type GhosttyTerminal } from './ghostty';

function lineText(terminal: GhosttyTerminal, offset: number): string {
  return (
    terminal
      .getScrollbackLine(offset)
      ?.map((cell) => String.fromCodePoint(cell.codepoint || 32))
      .join('')
      .trim() ?? ''
  );
}

function numberedLines(count: number): string {
  return Array.from({ length: count }, (_, index) => `${index + 1}\r\n`).join('');
}

describe('GhosttyTerminal scrollback line limits', () => {
  for (const cols of [96, 128]) {
    for (const limit of [100, 5000]) {
      test(`keeps exactly ${limit} history lines at ${cols} columns`, async () => {
        const ghostty = await Ghostty.load();
        const terminal = ghostty.createTerminal(cols, 28, { scrollbackLimit: limit });

        try {
          terminal.write(numberedLines(6000));

          expect(terminal.getScrollbackLength()).toBe(limit);
          expect(lineText(terminal, 0)).toBe(String(5974 - limit));
          expect(lineText(terminal, limit - 1)).toBe('5973');
          expect(terminal.getScrollbackLine(limit)).toBeNull();
        } finally {
          terminal.free();
        }
      });
    }
  }

  test('maps grapheme reads into the logical scrollback window', async () => {
    const ghostty = await Ghostty.load();
    const terminal = ghostty.createTerminal(128, 28, { scrollbackLimit: 100 });
    const lines = Array.from({ length: 200 }, (_, index) => {
      const line = index + 1;
      if (line === 1) return `B\u0301 raw-oldest\r\n`;
      if (line === 74) return `A\u0301 logical-oldest\r\n`;
      return `${line}\r\n`;
    }).join('');

    try {
      terminal.write(lines);

      expect(terminal.getScrollbackLength()).toBe(100);
      expect(lineText(terminal, 0)).toBe('A logical-oldest');
      expect(terminal.getScrollbackGraphemeString(0, 0)).toBe('A\u0301');
    } finally {
      terminal.free();
    }
  });

  test('keeps the configured history after widening the terminal', async () => {
    const ghostty = await Ghostty.load();
    const terminal = ghostty.createTerminal(80, 28, { scrollbackLimit: 5000 });

    try {
      terminal.write(numberedLines(6000));
      expect(terminal.getScrollbackLength()).toBe(5000);

      terminal.resize(500, 28);

      expect(terminal.getScrollbackLength()).toBe(5000);
      expect(lineText(terminal, 0)).toBe('974');
      expect(lineText(terminal, 4999)).toBe('5973');
    } finally {
      terminal.free();
    }
  });
});
