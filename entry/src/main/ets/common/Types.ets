// 数据模型：Scene/Phase/SessionResult（引擎与存储共用的唯一类型定义，arkts-no-decl-merging）

export class Phase {
  name: string = '';
  durationMs: number = 0;
  endSound: string = '';                 // 音库 id，'' = 无
  wakeEnabled: boolean = false;          // 本阶段内随机唤醒
  wakeMinMs: number = 180000;             // 随机间隔下限（默认 3 分钟）
  wakeMaxMs: number = 300000;            // 随机间隔上限（默认 5 分钟）
  microBreakMs: number = 10000;          // 微休息时长，0 = 只响不休息

  static of(name: string, durationMs: number): Phase {
    const p = new Phase();
    p.name = name;
    p.durationMs = durationMs;
    return p;
  }

  static wakeOf(name: string, durationMs: number, wakeMinMs: number, wakeMaxMs: number, microBreakMs: number): Phase {
    const p = Phase.of(name, durationMs);
    p.wakeEnabled = true;
    p.wakeMinMs = wakeMinMs;
    p.wakeMaxMs = wakeMaxMs;
    p.microBreakMs = microBreakMs;
    return p;
  }
}

export class Scene {
  id: string = '';
  name: string = '';
  colorIndex: number = 0;                // 0-5 对应 phase_0-5 色板
  loopCount: number = 0;                 // 0 = 无限循环
  phases: Phase[] = [];
  source: string = 'custom';             // 'template' | 'custom'

  static of(id: string, name: string, colorIndex: number, loopCount: number, phases: Phase[], source: string): Scene {
    const s = new Scene();
    s.id = id;
    s.name = name;
    s.colorIndex = colorIndex;
    s.loopCount = loopCount;
    s.phases = phases;
    s.source = source;
    return s;
  }
}

// 引擎结束一次运行后产出的会话结果（M2 持久化到 session 表）
export class SessionResult {
  sceneId: string = '';
  sceneName: string = '';
  startedAt: number = 0;
  endedAt: number = 0;
  status: string = 'stopped';            // 'completed' | 'stopped'
  completedCycles: number = 0;
  phaseNames: string[] = [];
  phaseTotals: number[] = [];            // 各阶段净时长 ms（排除暂停与微休息）
  phaseCounts: number[] = [];            // 各阶段自然完成次数
  phaseSkips: number[] = [];             // 各阶段被手动跳过次数
  totalPausedMs: number = 0;
  totalMicroMs: number = 0;
}
