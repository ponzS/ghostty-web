export interface TerminalWorkSchedulerOptions {
  maxBytesPerFrame?: number;
  maxWritesPerFrame?: number;
  schedule?: (callback: () => void) => number;
  cancel?: (handle: number) => void;
}

export interface TerminalWorkSchedulerDiagnostics {
  queuedBytes: number;
  queuedWrites: number;
  scheduledFrameCount: number;
  drainedFrameCount: number;
  writeCount: number;
  byteCount: number;
  cancelledCount: number;
  failedCount: number;
  lastFrameBytes: number;
  lastFrameWrites: number;
}

type WorkItem = {
  data: Uint8Array;
  offset: number;
};

const defaultSchedule = (callback: () => void): number => requestAnimationFrame(callback);
const defaultCancel = (handle: number): void => cancelAnimationFrame(handle);

/**
 * Bounds terminal work per animation frame while preserving FIFO byte order.
 * The consumer owns terminal identity and decides how each chunk is applied.
 */
export class TerminalWorkScheduler {
  private readonly maxBytesPerFrame: number;
  private readonly maxWritesPerFrame: number;
  private readonly schedule: (callback: () => void) => number;
  private readonly cancel: (handle: number) => void;
  private readonly queue: WorkItem[] = [];
  private frameHandle?: number;
  private disposed = false;
  private draining = false;
  private diagnostics: TerminalWorkSchedulerDiagnostics = {
    queuedBytes: 0,
    queuedWrites: 0,
    scheduledFrameCount: 0,
    drainedFrameCount: 0,
    writeCount: 0,
    byteCount: 0,
    cancelledCount: 0,
    failedCount: 0,
    lastFrameBytes: 0,
    lastFrameWrites: 0,
  };

  constructor(
    private readonly writeChunk: (data: Uint8Array) => void,
    options: TerminalWorkSchedulerOptions = {}
  ) {
    this.maxBytesPerFrame = Math.max(1, options.maxBytesPerFrame ?? 256 * 1024);
    this.maxWritesPerFrame = Math.max(1, options.maxWritesPerFrame ?? 8);
    this.schedule = options.schedule ?? defaultSchedule;
    this.cancel = options.cancel ?? defaultCancel;
  }

  enqueue(data: Uint8Array): void {
    if (this.disposed || data.byteLength === 0) return;

    const copy = data.slice();
    this.queue.push({ data: copy, offset: 0 });
    this.diagnostics.queuedBytes += copy.byteLength;
    this.diagnostics.queuedWrites++;
    this.ensureScheduled();
  }

  cancelPending(): void {
    if (this.queue.length > 0) this.diagnostics.cancelledCount++;
    this.queue.length = 0;
    this.diagnostics.queuedBytes = 0;
    this.diagnostics.queuedWrites = 0;
    if (this.frameHandle !== undefined) {
      this.cancel(this.frameHandle);
      this.frameHandle = undefined;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.cancelPending();
  }

  getDiagnostics(): TerminalWorkSchedulerDiagnostics {
    return { ...this.diagnostics };
  }

  private ensureScheduled(): void {
    if (this.disposed || this.frameHandle !== undefined || this.draining) return;
    this.diagnostics.scheduledFrameCount++;
    this.frameHandle = this.schedule(() => {
      this.frameHandle = undefined;
      this.drainFrame();
    });
  }

  private drainFrame(): void {
    if (this.disposed || this.draining) return;
    this.draining = true;
    let frameBytes = 0;
    let frameWrites = 0;

    try {
      while (
        this.queue.length > 0 &&
        frameBytes < this.maxBytesPerFrame &&
        frameWrites < this.maxWritesPerFrame
      ) {
        const item = this.queue[0];
        const remainingBudget = this.maxBytesPerFrame - frameBytes;
        const remaining = item.data.byteLength - item.offset;
        const length = Math.min(remaining, remainingBudget);
        const chunk = item.data.slice(item.offset, item.offset + length);

        this.writeChunk(chunk);
        item.offset += length;
        frameBytes += length;
        frameWrites++;
        this.diagnostics.queuedBytes -= length;
        this.diagnostics.writeCount++;
        this.diagnostics.byteCount += length;

        if (item.offset === item.data.byteLength) {
          this.queue.shift();
          this.diagnostics.queuedWrites--;
        }
      }
    } catch (error) {
      this.diagnostics.failedCount++;
      this.draining = false;
      this.ensureScheduled();
      throw error;
    }

    this.draining = false;
    this.diagnostics.drainedFrameCount++;
    this.diagnostics.lastFrameBytes = frameBytes;
    this.diagnostics.lastFrameWrites = frameWrites;
    if (this.queue.length > 0) this.ensureScheduled();
  }
}
