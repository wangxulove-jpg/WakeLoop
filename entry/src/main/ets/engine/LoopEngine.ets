import { Phase, Scene, SessionResult } from '../common/Types';

export enum EngineStatus {
  Idle = 0,
  Running = 1,
  Paused = 2,
  Completed = 3
}

export enum EngineEventType {
  PhaseEnd = 0,        // 阶段自然结束（含挂起追赶，atMs 为精确边界时刻，服务层据此决定是否补播音）
  PhaseSkipped = 1,    // 手动跳过
  WakeFire = 2,        // 随机唤醒触发（随后进入微休息）
  MicroBreakEnd = 3,   // 微休息结束
  CycleComplete = 4,   // 一整轮完成
  SceneComplete = 5    // 场景全部轮数完成
}

export class EngineEvent {
  type: EngineEventType = EngineEventType.PhaseEnd;
  phaseIndex: number = 0;
  atMs: number = 0;
}

// 运行态快照：全部为绝对墙钟锚点，落盘后重启可精确恢复（轻后台核心）
export class EngineSnapshot {
  scene: Scene = new Scene();
  status: EngineStatus = EngineStatus.Idle;
  phaseIndex: number = 0;
  cycle: number = 1;
  sceneStartAt: number = 0;
  phaseStartAt: number = 0;
  frozenMs: number = 0;             // 当前阶段内已冻结（暂停 + 微休息累计）
  freezeStartAt: number = 0;        // >0 表示冻结中
  freezeIsPause: boolean = false;   // 冻结原因：true=手动暂停，false=微休息
  microBreakEndAt: number = 0;      // >0 表示微休息中
  nextWakeAt: number = 0;
  completedCycles: number = 0;
  phaseTotals: number[] = [];
  phaseCounts: number[] = [];
  phaseSkips: number[] = [];
  totalPausedMs: number = 0;
  totalMicroMs: number = 0;
}

// 唤醒迟到宽限：超过该值视为挂起期间错过，不触发只重排（D4 不补播）
const WAKE_GRACE_MS = 30000;

/**
 * 循环计时内核（纯逻辑，无 UI/存储依赖）。
 * 时间正确性：只存锚点（sceneStartAt/phaseStartAt/frozenMs/freezeStartAt），
 * recompute() 用墙钟追赶跨阶段推进，挂起/被杀后调用即恢复。
 * 随机唤醒：nextWake = 触发时刻 + rand(min,max)，相对增量（旧项目踩坑 #12 教训）。
 */
export class LoopEngine {
  private nowFn: () => number;
  private randFn: (minMs: number, maxMs: number) => number;
  private scene: Scene = new Scene();
  private hasScene: boolean = false;
  private status: EngineStatus = EngineStatus.Idle;
  private phaseIndex: number = 0;
  private cycle: number = 1;                 // 当前轮次（1 起）
  private sceneStartAt: number = 0;
  private phaseStartAt: number = 0;
  private frozenMs: number = 0;
  private freezeStartAt: number = 0;
  private freezeIsPause: boolean = false;
  private microBreakEndAt: number = 0;
  private nextWakeAt: number = 0;
  private completedCycles: number = 0;
  private phaseTotals: number[] = [];
  private phaseCounts: number[] = [];
  private phaseSkips: number[] = [];
  private totalPausedMs: number = 0;
  private totalMicroMs: number = 0;

  onEvent: (ev: EngineEvent) => void = (ev: EngineEvent) => {};

  constructor(nowFn?: () => number, randFn?: (minMs: number, maxMs: number) => number) {
    this.nowFn = nowFn !== undefined ? nowFn : () => Date.now();
    this.randFn = randFn !== undefined ? randFn
      : (minMs: number, maxMs: number) => minMs + Math.floor(Math.random() * (maxMs - minMs));
  }

  // ---------- 生命周期 ----------

  start(scene: Scene): void {
    this.scene = scene;
    this.hasScene = true;
    this.status = EngineStatus.Running;
    this.phaseIndex = 0;
    this.cycle = 1;
    this.completedCycles = 0;
    const now = this.nowFn();
    this.sceneStartAt = now;
    this.phaseStartAt = now;
    this.frozenMs = 0;
    this.freezeStartAt = 0;
    this.freezeIsPause = false;
    this.microBreakEndAt = 0;
    this.totalPausedMs = 0;
    this.totalMicroMs = 0;
    this.phaseTotals = [];
    this.phaseCounts = [];
    this.phaseSkips = [];
    for (let i = 0; i < scene.phases.length; i++) {
      this.phaseTotals.push(0);
      this.phaseCounts.push(0);
      this.phaseSkips.push(0);
    }
    this.rescheduleWakeFor(now);
  }

  pause(): void {
    if (this.status !== EngineStatus.Running) {
      return;
    }
    const now = this.nowFn();
    if (this.isMicroBreaking()) {
      // 微休息中手动暂停：取消微休息，吸收实际经过部分
      const dur = now - this.freezeStartAt;
      this.frozenMs += dur;
      this.totalMicroMs += dur;
      this.microBreakEndAt = 0;
    }
    this.freezeStartAt = now;
    this.freezeIsPause = true;
    this.status = EngineStatus.Paused;
  }

  resume(): void {
    if (this.status !== EngineStatus.Paused) {
      return;
    }
    const now = this.nowFn();
    if (this.freezeStartAt > 0) {
      const dur = now - this.freezeStartAt;
      this.frozenMs += dur;
      this.totalPausedMs += dur;
      this.freezeStartAt = 0;
    }
    this.freezeIsPause = false;
    this.status = EngineStatus.Running;
  }

  skipPhase(): void {
    if (this.status !== EngineStatus.Running) {
      return;
    }
    const now = this.nowFn();
    let boundary = now;
    if (this.freezeStartAt > 0) {
      if (!this.freezeIsPause && this.microBreakEndAt > 0) {
        const end = Math.min(now, this.microBreakEndAt);
        const dur = end - this.freezeStartAt;
        this.frozenMs += dur;
        this.totalMicroMs += dur;
        boundary = end;
        this.microBreakEndAt = 0;
      } else {
        const dur = now - this.freezeStartAt;
        this.frozenMs += dur;
        this.totalPausedMs += dur;
        boundary = this.freezeStartAt;
      }
      this.freezeStartAt = 0;
      this.freezeIsPause = false;
      this.status = EngineStatus.Running;
    }
    this.recordPartial(boundary);
    this.phaseSkips[this.phaseIndex] += 1;
    this.emitEvent(EngineEventType.PhaseSkipped, this.phaseIndex, boundary);
    this.advanceAt(boundary);
    if (this.status === EngineStatus.Running) {
      this.phaseStartAt = boundary;
      this.frozenMs = 0;
      this.rescheduleWakeFor(boundary);
    }
  }

  // 结束并产出会话结果；finalStatus: 'completed' | 'stopped'
  finish(finalStatus: string): SessionResult | undefined {
    if (!this.hasScene || this.status === EngineStatus.Idle) {
      return undefined;
    }
    const now = this.nowFn();
    if (this.status === EngineStatus.Running) {
      if (this.isMicroBreaking()) {
        const end = Math.min(now, this.microBreakEndAt);
        const dur = end - this.freezeStartAt;
        this.frozenMs += dur;
        this.totalMicroMs += dur;
        this.microBreakEndAt = 0;
        this.freezeStartAt = 0;
        this.recordPartial(end);
      } else if (this.freezeStartAt > 0) {
        // 挂起瞬间被结束（罕见）：按冻结点截断
        this.recordPartial(this.freezeStartAt);
        this.freezeStartAt = 0;
      } else {
        this.recordPartial(now);
      }
    } else if (this.status === EngineStatus.Paused) {
      const dur = now - this.freezeStartAt;
      this.totalPausedMs += dur;
      this.recordPartial(this.freezeStartAt);
      this.freezeStartAt = 0;
    }
    // Completed：全部阶段已在推进时记录完毕

    const r = new SessionResult();
    r.sceneId = this.scene.id;
    r.sceneName = this.scene.name;
    r.startedAt = this.sceneStartAt;
    r.endedAt = now;
    r.status = finalStatus;
    r.completedCycles = this.completedCycles;
    r.phaseNames = this.copyStrings(this.scene.phases, (p: Phase) => p.name);
    r.phaseTotals = this.copyNums(this.phaseTotals);
    r.phaseCounts = this.copyNums(this.phaseCounts);
    r.phaseSkips = this.copyNums(this.phaseSkips);
    r.totalPausedMs = this.totalPausedMs;
    r.totalMicroMs = this.totalMicroMs;
    this.resetIdle();
    return r;
  }

  // ---------- 推进（前台每秒 tick / 回前台与重启后恢复共用） ----------

  tick(): void {
    this.recompute();
  }

  recompute(): void {
    // 注意：用访问器比较，避免早退守卫把 this.status 收窄为 Running 后，
    // 后续 === Completed 被 ArkTS 判为 no overlap（枚举字面量收窄误报）
    if (this.statusNow() !== EngineStatus.Running) {
      return;
    }
    const now = this.nowFn();

    // ① 微休息到时解冻（精确到 microBreakEndAt，挂起跨越也正确）
    if (this.freezeStartAt > 0 && !this.freezeIsPause && this.microBreakEndAt > 0 && now >= this.microBreakEndAt) {
      const dur = this.microBreakEndAt - this.freezeStartAt;
      this.frozenMs += dur;
      this.totalMicroMs += dur;
      this.freezeStartAt = 0;
      this.microBreakEndAt = 0;
      this.emitEvent(EngineEventType.MicroBreakEnd, this.phaseIndex, this.nowFn());
    }
    if (this.freezeStartAt > 0) {
      return; // 冻结中（手动暂停或微休息进行中）
    }

    // ② 随机唤醒：迟到在宽限内才触发，否则视为挂起期间错过，静默重排（D4 不补播）
    const ph = this.currentPhase();
    if (ph !== undefined) {
      if (ph.wakeEnabled) {
        if (this.nextWakeAt <= 0) {
          this.nextWakeAt = now + this.randFn(ph.wakeMinMs, ph.wakeMaxMs);
        } else if (now >= this.nextWakeAt) {
          if (now - this.nextWakeAt < WAKE_GRACE_MS) {
            this.freezeStartAt = now;
            this.freezeIsPause = false;
            this.emitEvent(EngineEventType.WakeFire, this.phaseIndex, now);
            // 相对增量排程（旧项目踩坑 #12）：从触发时刻起算下一次
            this.nextWakeAt = now + this.randFn(ph.wakeMinMs, ph.wakeMaxMs);
            if (ph.microBreakMs > 0) {
              this.microBreakEndAt = now + ph.microBreakMs;
            }
            return; // 进入微休息，本轮回到此为止
          } else {
            this.nextWakeAt = now + this.randFn(ph.wakeMinMs, ph.wakeMaxMs);
          }
        }
      } else if (this.nextWakeAt > 0) {
        this.nextWakeAt = 0;
      }
    }

    // ③ 阶段推进（挂起追赶：跨阶段循环推进，carry 保证累计精确）
    let guard = 0;
    while (this.statusNow() === EngineStatus.Running && guard < 1000000) {
      guard++;
      const cur = this.currentPhase();
      if (cur === undefined) {
        break;
      }
      const elapsed = this.elapsedAt(now);
      if (elapsed < cur.durationMs) {
        break;
      }
      const carry = elapsed - cur.durationMs;
      const boundary = now - carry;
      this.phaseTotals[this.phaseIndex] += boundary - this.phaseStartAt - this.frozenMs;
      this.phaseCounts[this.phaseIndex] += 1;
      this.emitEvent(EngineEventType.PhaseEnd, this.phaseIndex, boundary);
      this.advanceAt(boundary);
      if (this.status === EngineStatus.Completed) {
        break;
      }
      this.phaseStartAt = boundary;
      this.frozenMs = 0;
      this.rescheduleWakeFor(now);
    }
  }

  // ---------- 快照 ----------

  toSnapshot(): EngineSnapshot | undefined {
    if (!this.hasScene) {
      return undefined;
    }
    const s = new EngineSnapshot();
    s.scene = this.scene;
    s.status = this.status;
    s.phaseIndex = this.phaseIndex;
    s.cycle = this.cycle;
    s.sceneStartAt = this.sceneStartAt;
    s.phaseStartAt = this.phaseStartAt;
    s.frozenMs = this.frozenMs;
    s.freezeStartAt = this.freezeStartAt;
    s.freezeIsPause = this.freezeIsPause;
    s.microBreakEndAt = this.microBreakEndAt;
    s.nextWakeAt = this.nextWakeAt;
    s.completedCycles = this.completedCycles;
    s.phaseTotals = this.copyNums(this.phaseTotals);
    s.phaseCounts = this.copyNums(this.phaseCounts);
    s.phaseSkips = this.copyNums(this.phaseSkips);
    s.totalPausedMs = this.totalPausedMs;
    s.totalMicroMs = this.totalMicroMs;
    return s;
  }

  static fromSnapshot(snap: EngineSnapshot, nowFn?: () => number,
    randFn?: (minMs: number, maxMs: number) => number): LoopEngine {
    const e = new LoopEngine(nowFn, randFn);
    e.scene = snap.scene;
    e.hasScene = true;
    e.status = snap.status;
    e.phaseIndex = snap.phaseIndex;
    e.cycle = snap.cycle;
    e.sceneStartAt = snap.sceneStartAt;
    e.phaseStartAt = snap.phaseStartAt;
    e.frozenMs = snap.frozenMs;
    e.freezeStartAt = snap.freezeStartAt;
    e.freezeIsPause = snap.freezeIsPause;
    e.microBreakEndAt = snap.microBreakEndAt;
    e.nextWakeAt = snap.nextWakeAt;
    e.completedCycles = snap.completedCycles;
    e.phaseTotals = e.copyNums(snap.phaseTotals);
    e.phaseCounts = e.copyNums(snap.phaseCounts);
    e.phaseSkips = e.copyNums(snap.phaseSkips);
    e.totalPausedMs = snap.totalPausedMs;
    e.totalMicroMs = snap.totalMicroMs;
    return e;
  }

  // ---------- 查询 ----------

  getScene(): Scene | undefined {
    return this.hasScene ? this.scene : undefined;
  }

  getStatus(): EngineStatus {
    return this.status;
  }

  getPhaseIndex(): number {
    return this.phaseIndex;
  }

  getCycle(): number {
    return this.cycle;
  }

  getCompletedCycles(): number {
    return this.completedCycles;
  }

  getPhase(): Phase | undefined {
    return this.currentPhase();
  }

  getPhaseElapsedMs(): number {
    const ph = this.currentPhase();
    if (ph === undefined || ph.durationMs <= 0) {
      return 0;
    }
    return Math.min(this.elapsedAt(this.nowFn()), ph.durationMs);
  }

  getPhaseRemainMs(): number {
    const ph = this.currentPhase();
    if (ph === undefined) {
      return 0;
    }
    return Math.max(ph.durationMs - this.elapsedAt(this.nowFn()), 0);
  }

  getPhaseProgress(): number {
    const ph = this.currentPhase();
    if (ph === undefined || ph.durationMs <= 0) {
      return 0;
    }
    const p = this.elapsedAt(this.nowFn()) / ph.durationMs;
    if (p < 0) {
      return 0;
    }
    if (p > 1) {
      return 1;
    }
    return p;
  }

  isPaused(): boolean {
    return this.status === EngineStatus.Paused;
  }

  isMicroBreaking(): boolean {
    return this.freezeStartAt > 0 && !this.freezeIsPause && this.microBreakEndAt > 0;
  }

  getMicroBreakRemainMs(): number {
    if (!this.isMicroBreaking()) {
      return 0;
    }
    return Math.max(this.microBreakEndAt - this.nowFn(), 0);
  }

  getNextWakeAt(): number {
    return this.nextWakeAt;
  }

  getSceneStartAt(): number {
    return this.sceneStartAt;
  }

  // ---------- 内部 ----------

  private statusNow(): EngineStatus {
    return this.status;
  }

  private currentPhase(): Phase | undefined {
    if (!this.hasScene || this.phaseIndex < 0 || this.phaseIndex >= this.scene.phases.length) {
      return undefined;
    }
    return this.scene.phases[this.phaseIndex];
  }

  private elapsedAt(now: number): number {
    const cap = this.freezeStartAt > 0 ? this.freezeStartAt : now;
    return cap - this.phaseStartAt - this.frozenMs;
  }

  private rescheduleWakeFor(now: number): void {
    const ph = this.currentPhase();
    if (ph !== undefined && ph.wakeEnabled) {
      this.nextWakeAt = now + this.randFn(ph.wakeMinMs, ph.wakeMaxMs);
    } else {
      this.nextWakeAt = 0;
    }
  }

  private recordPartial(boundary: number): void {
    const ph = this.currentPhase();
    if (ph === undefined) {
      return;
    }
    this.phaseTotals[this.phaseIndex] += boundary - this.phaseStartAt - this.frozenMs;
  }

  private advanceAt(boundary: number): void {
    this.phaseIndex += 1;
    if (this.phaseIndex >= this.scene.phases.length) {
      this.completedCycles += 1;
      this.emitEvent(EngineEventType.CycleComplete, this.phaseIndex - 1, boundary);
      this.phaseIndex = 0;
      this.cycle += 1;
      if (this.scene.loopCount > 0 && this.completedCycles >= this.scene.loopCount) {
        this.status = EngineStatus.Completed;
        this.emitEvent(EngineEventType.SceneComplete, this.scene.phases.length - 1, boundary);
      }
    }
  }

  private resetIdle(): void {
    this.hasScene = false;
    this.status = EngineStatus.Idle;
    this.phaseIndex = 0;
    this.cycle = 1;
    this.sceneStartAt = 0;
    this.phaseStartAt = 0;
    this.frozenMs = 0;
    this.freezeStartAt = 0;
    this.freezeIsPause = false;
    this.microBreakEndAt = 0;
    this.nextWakeAt = 0;
    this.completedCycles = 0;
    this.phaseTotals = [];
    this.phaseCounts = [];
    this.phaseSkips = [];
    this.totalPausedMs = 0;
    this.totalMicroMs = 0;
    this.scene = new Scene();
  }

  private emitEvent(type: EngineEventType, phaseIndex: number, atMs: number): void {
    const ev = new EngineEvent();
    ev.type = type;
    ev.phaseIndex = phaseIndex;
    ev.atMs = atMs;
    this.onEvent(ev);
  }

  private copyNums(src: number[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < src.length; i++) {
      out.push(src[i]);
    }
    return out;
  }

  private copyStrings(src: Phase[], pick: (p: Phase) => string): string[] {
    const out: string[] = [];
    for (let i = 0; i < src.length; i++) {
      out.push(pick(src[i]));
    }
    return out;
  }
}
