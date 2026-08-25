import { describe, expect, test } from 'bun:test';
import { TerminalWorkScheduler } from './terminal-work-scheduler';

type FrameCallback = () => void;

function createManualScheduler(options: ConstructorParameters<typeof TerminalWorkScheduler>[1] = {}) {
  const frames: FrameCallback[] = [];
  const writes: Uint8Array[] = [];
  const scheduler = new TerminalWorkScheduler((data) => writes.push(data), {
    ...options,
    schedule: (callback) => {
      frames.push(callback);
      return frames.length;
    },
    cancel: () => undefined,
  });
  return { frames, scheduler, writes };
}

describe('TerminalWorkScheduler', () => {
  test('preserves FIFO order while respecting byte and write budgets', () => {
    const { frames, scheduler, writes } = createManualScheduler({
      maxBytesPerFrame: 4,
      maxWritesPerFrame: 2,
    });

    scheduler.enqueue(new Uint8Array([1, 2, 3]));
    scheduler.enqueue(new Uint8Array([4, 5, 6]));
    expect(frames).toHaveLength(1);

    frames.shift()!();
    expect([...writes.flatMap((chunk) => [...chunk])]).toEqual([1, 2, 3, 4]);
    expect(scheduler.getDiagnostics()).toMatchObject({
      queuedBytes: 2,
      queuedWrites: 1,
      drainedFrameCount: 1,
      lastFrameBytes: 4,
      lastFrameWrites: 2,
    });
    expect(frames).toHaveLength(1);

    frames.shift()!();
    expect([...writes.flatMap((chunk) => [...chunk])]).toEqual([1, 2, 3, 4, 5, 6]);
    expect(scheduler.getDiagnostics()).toMatchObject({
      queuedBytes: 0,
      queuedWrites: 0,
      drainedFrameCount: 2,
    });
  });

  test('splits one large input without reordering or dropping bytes', () => {
    const { frames, scheduler, writes } = createManualScheduler({
      maxBytesPerFrame: 3,
      maxWritesPerFrame: 8,
    });
    scheduler.enqueue(new Uint8Array([10, 11, 12, 13, 14]));

    while (frames.length > 0) frames.shift()!();

    expect(writes.map((chunk) => [...chunk])).toEqual([[10, 11, 12], [13, 14]]);
    expect(scheduler.getDiagnostics()).toMatchObject({ byteCount: 5, writeCount: 2 });
  });

  test('cancelPending prevents queued work from running', () => {
    const { frames, scheduler, writes } = createManualScheduler();
    scheduler.enqueue(new Uint8Array([1, 2]));
    scheduler.cancelPending();
    frames.shift()!();

    expect(writes).toHaveLength(0);
    expect(scheduler.getDiagnostics()).toMatchObject({
      queuedBytes: 0,
      queuedWrites: 0,
      cancelledCount: 1,
    });
  });

  test('a failed write is observable and the queue remains retryable', () => {
    const frames: FrameCallback[] = [];
    let attempts = 0;
    const scheduler = new TerminalWorkScheduler(
      () => {
        attempts++;
        if (attempts === 1) throw new Error('write failed');
      },
      {
        schedule: (callback) => {
          frames.push(callback);
          return frames.length;
        },
        cancel: () => undefined,
      }
    );
    scheduler.enqueue(new Uint8Array([1]));

    expect(() => frames.shift()!()).toThrow('write failed');
    expect(scheduler.getDiagnostics()).toMatchObject({ failedCount: 1, queuedBytes: 1 });
    frames.shift()!();
    expect(scheduler.getDiagnostics()).toMatchObject({ queuedBytes: 0, byteCount: 1 });
  });
});
