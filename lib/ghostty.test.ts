import { describe, expect, test } from 'bun:test';
import { Ghostty } from './ghostty';

describe('Ghostty WASM compatibility', () => {
  test('rejects a module without scrollback generation support', () => {
    const wasmInstance = {
      exports: {
        memory: new WebAssembly.Memory({ initial: 1 }),
      },
    } as unknown as WebAssembly.Instance;

    expect(() => new Ghostty(wasmInstance)).toThrow(
      'Incompatible Ghostty WASM: missing ghostty_terminal_get_scrollback_generation'
    );
  });
});
