import { describe, it, expect } from '@ohos/hypium';
import { LoopEngine, EngineStatus, EngineEventType, EngineEvent, EngineSnapshot } from '../main/ets/engine/LoopEngine';
import { Phase, Scene, SessionResult } from '../main/ets/common/Types';
import { SceneTemplates } from '../main/ets/model/SceneTemplates';

// 可控时钟 + 固定随机的测试替身：rand 固定 20000ms，宽限 30s 内的迟到判定可精确复现
class Harness {
  now: number = 1000000;
  events: EngineEvent[] = [];
  engine: LoopEngine;

  constructor() {
    this.engine = new LoopEngine((): number => this.now, (minMs: number, maxMs: number): number => 20000);
    this.engine.onEvent = (ev: EngineEvent): void => {
      this.events.push(ev);
    };
  }

  step(ms: number): void {
    this.now += ms;
    this.engine.recompute();
  }

  count(type: EngineEventType): number {
    let n = 0;
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].type === type) {
        n++;
      }
    }
    return n;
  }
}

// 测试场景：专注 60s（唤醒 20s 固定间隔 + 微休息 10s）/ 休息 30s × 2 轮
function makeScene(): Scene {
  return Scene.of('test', '测试场景', 0, 2, [
    Phase.wakeOf('专注', 60000, 20000, 20000, 10000),
    Phase.of('休息', 30000)
  ], 'custom');
}

export default function localUnitTest() {
  describe('LoopEngineCore', () => {
    it('start_initial_state', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      expect(h.engine.getStatus()).assertEqual(EngineStatus.Running);
      expect(h.engine.getPhaseIndex()).assertEqual(0);
      expect(h.engine.getCycle()).assertEqual(1);
      expect(h.engine.getPhaseRemainMs()).assertEqual(60000);
      expect(h.engine.getPhaseProgress()).assertEqual(0);
      expect(h.engine.getNextWakeAt()).assertEqual(1020000);
    });

    it('tick_within_phase_progress', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(10000);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(10000);
      expect(h.engine.getPhaseRemainMs()).assertEqual(50000);
      expect(h.engine.getPhaseProgress() > 0.16 && h.engine.getPhaseProgress() < 0.17).assertTrue();
    });

    it('phase_end_carry_over', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(61000);
      // 60s 边界 +1s carry：进入休息阶段且已过 1s，边界精确到 1060000
      expect(h.engine.getPhaseIndex()).assertEqual(1);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(1000);
      expect(h.count(EngineEventType.PhaseEnd)).assertEqual(1);
      expect(h.events[0].atMs).assertEqual(1060000);
      // 唤醒 20s 处已迟到 41s > 30s 宽限 → 挂起语义，不触发
      expect(h.count(EngineEventType.WakeFire)).assertEqual(0);
    });

    it('cycle_wrap_and_scene_complete', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(61000);   // 第 1 轮专注完
      h.step(31000);   // 第 1 轮休息完 → 换轮
      expect(h.engine.getCycle()).assertEqual(2);
      expect(h.engine.getCompletedCycles()).assertEqual(1);
      expect(h.count(EngineEventType.CycleComplete)).assertEqual(1);
      h.step(61000);   // 第 2 轮专注完
      h.step(31000);   // 第 2 轮休息完 → 场景完成
      expect(h.engine.getStatus()).assertEqual(EngineStatus.Completed);
      expect(h.count(EngineEventType.SceneComplete)).assertEqual(1);
      expect(h.engine.getCompletedCycles()).assertEqual(2);
    });

    it('infinite_loop_never_completes', 0, () => {
      const scene = Scene.of('inf', '无限', 0, 0, [
        Phase.of('循环', 60000)
      ], 'custom');
      const h = new Harness();
      h.engine.start(scene);
      for (let i = 0; i < 8; i++) {
        h.step(60000);
      }
      expect(h.engine.getStatus()).assertEqual(EngineStatus.Running);
      expect(h.engine.getCompletedCycles()).assertEqual(8);
    });

    it('pause_freezes_and_resume_continues', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(10000);
      h.engine.pause();
      h.step(30000);   // 暂停期间时间流逝不计入
      expect(h.engine.isPaused()).assertTrue();
      expect(h.engine.getPhaseElapsedMs()).assertEqual(10000);
      h.engine.resume();
      expect(h.engine.getPhaseElapsedMs()).assertEqual(10000);
      h.step(50000);
      expect(h.engine.getPhaseIndex()).assertEqual(1); // 恰好净 60s，阶段结束
      expect(h.engine.getPhaseElapsedMs()).assertEqual(0);
    });

    it('suspension_catchup_across_phases', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      // 模拟挂起 155s：专注60+休息30+专注60+休息5 → 第 2 轮休息已过 5s
      h.step(155000);
      expect(h.engine.getStatus()).assertEqual(EngineStatus.Running);
      expect(h.engine.getCycle()).assertEqual(2);
      expect(h.engine.getCompletedCycles()).assertEqual(1);
      expect(h.engine.getPhaseIndex()).assertEqual(1);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(5000);
      expect(h.count(EngineEventType.PhaseEnd)).assertEqual(3);
      expect(h.count(EngineEventType.CycleComplete)).assertEqual(1);
      // D4：挂起期间错过的唤醒不补播
      expect(h.count(EngineEventType.WakeFire)).assertEqual(0);
    });

    it('wake_fires_and_micro_break_freezes', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(20000);   // 20s 处唤醒
      expect(h.count(EngineEventType.WakeFire)).assertEqual(1);
      expect(h.engine.isMicroBreaking()).assertTrue();
      expect(h.engine.getMicroBreakRemainMs()).assertEqual(10000);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(20000); // 冻结
      h.step(10000);   // 微休息结束
      expect(h.engine.isMicroBreaking()).assertFalse();
      expect(h.count(EngineEventType.MicroBreakEnd)).assertEqual(1);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(20000); // 冻结被吸收，不推进
      h.step(40000);   // 净时长 20+40=60s 达成
      expect(h.engine.getPhaseIndex()).assertEqual(1);
    });

    it('wake_reschedule_is_relative', 0, () => {
      // 旧项目踩坑 #12 回归：微休息结束后不得立即再触发
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(20000);   // 唤醒1 @1020000，nextWake=1040000（相对增量）
      expect(h.engine.getNextWakeAt()).assertEqual(1040000);
      h.step(10000);   // 微休息结束 @1030000，不得触发
      expect(h.count(EngineEventType.WakeFire)).assertEqual(1);
      h.step(10000);   // @1040000 第二次唤醒
      expect(h.count(EngineEventType.WakeFire)).assertEqual(2);
      expect(h.engine.getNextWakeAt()).assertEqual(1060000);
    });

    it('pause_during_microbreak_cancels_it', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(20000);   // 唤醒 @1020000，微休息至 1030000
      h.step(5000);    // 微休息中 @1025000
      expect(h.engine.isMicroBreaking()).assertTrue();
      h.engine.pause();
      expect(h.engine.isMicroBreaking()).assertFalse();
      expect(h.engine.isPaused()).assertTrue();
      expect(h.engine.getPhaseElapsedMs()).assertEqual(20000);
      h.step(10000);   // 暂停 10s
      h.engine.resume();  // @1035000：墙钟 35s，冻结 5s 微休 + 10s 暂停 = 净 20s
      expect(h.engine.getPhaseElapsedMs()).assertEqual(20000);
    });

    it('suspended_through_microbreak_absorbs_exactly', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(20000);       // 唤醒 @1020000，微休息至 1030000
      h.step(60000);       // 挂起跨越微休息结束，@1080000
      expect(h.engine.isMicroBreaking()).assertFalse();
      expect(h.count(EngineEventType.MicroBreakEnd)).assertEqual(1);
      // 80s 墙钟 - 10s 微休息 = 70s 净 ≥ 60s → 阶段结束于 1070000，休息已过 10s
      expect(h.engine.getPhaseIndex()).assertEqual(1);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(10000);
    });

    it('finish_totals_direct', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(155000);   // 155s = 90(轮1) + 60(轮2专注) + 5(轮2休息 partial)
      const r: SessionResult | undefined = h.engine.finish('stopped');
      expect(r === undefined).assertFalse();
      if (r !== undefined) {
        expect(r.startedAt).assertEqual(1000000);
        expect(r.endedAt).assertEqual(1155000);
        expect(r.completedCycles).assertEqual(1);
        expect(r.phaseTotals[0]).assertEqual(120000); // 60s × 2 轮自然完成
        expect(r.phaseTotals[1]).assertEqual(35000); // 30s 完成 + 5s partial
        expect(r.phaseCounts[0]).assertEqual(2);
        expect(r.phaseCounts[1]).assertEqual(1);
        expect(r.phaseNames.length).assertEqual(2);
        expect(r.phaseNames[0]).assertEqual('专注');
      }
      expect(h.engine.getStatus()).assertEqual(EngineStatus.Idle);
      expect(h.engine.finish('stopped')).assertUndefined();
    });

    it('skip_phase_partial_accounting', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(10000);
      h.engine.skipPhase();
      expect(h.engine.getPhaseIndex()).assertEqual(1);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(0);
      expect(h.count(EngineEventType.PhaseSkipped)).assertEqual(1);
      const r = h.engine.finish('stopped');
      if (r !== undefined) {
        expect(r.phaseTotals[0]).assertEqual(10000); // partial 计入
        expect(r.phaseCounts[0]).assertEqual(0);     // 自然完成不计数
        expect(r.phaseSkips[0]).assertEqual(1);
      }
    });

    it('skip_phase_during_microbreak', 0, () => {
      const h = new Harness();
      h.engine.start(makeScene());
      h.step(20000);    // 唤醒 + 微休息 @1020000
      h.step(5000);     // @1025000 微休息中
      h.engine.skipPhase();
      expect(h.engine.isMicroBreaking()).assertFalse();
      expect(h.engine.getPhaseIndex()).assertEqual(1);
      expect(h.engine.getPhaseElapsedMs()).assertEqual(0);
      const r = h.engine.finish('stopped');
      if (r !== undefined) {
        expect(r.phaseTotals[0]).assertEqual(20000); // 冻结不计入净时长
        expect(r.totalMicroMs).assertEqual(5000);   // 微休自唤醒时刻起已进行 5s
      }
    });

    it('snapshot_restore_catchup_with_microbreak', 0, () => {
      const h1 = new Harness();
      h1.engine.start(makeScene());
      h1.step(25000);   // @1025000：已触发唤醒并处于微休息中（微休至 1035000）
      expect(h1.engine.isMicroBreaking()).assertTrue();
      const snap: EngineSnapshot | undefined = h1.engine.toSnapshot();
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined) {
        let now2: number = 1155000; // 再挂起 130s
        const events2: EngineEvent[] = [];
        const eng = LoopEngine.fromSnapshot(snap, (): number => now2, (minMs: number, maxMs: number): number => 20000);
        eng.onEvent = (ev: EngineEvent): void => {
          events2.push(ev);
        };
        eng.recompute();
        // 总墙钟 155s，其中 10s 微休息被冻结吸收：净 145s = 轮1(60+30) + 轮2专注 55s（未满 60s）
        expect(eng.getCycle()).assertEqual(2);
        expect(eng.getCompletedCycles()).assertEqual(1);
        expect(eng.getPhaseIndex()).assertEqual(0);
        expect(eng.getPhaseElapsedMs()).assertEqual(55000);
        // 挂起中结束的微休息被精确吸收，事件可见
        let microEnd = 0;
        for (let i = 0; i < events2.length; i++) {
          if (events2[i].type === EngineEventType.MicroBreakEnd) {
            microEnd++;
          }
        }
        expect(microEnd).assertEqual(1);
      }
    });

    it('snapshot_restore_plain_catchup', 0, () => {
      // 不经过唤醒的干净快照恢复：25s 前台 + 130s 挂起 = 155s，同 suspension_catchup
      const scene = Scene.of('test2', '无唤醒场景', 0, 2, [
        Phase.of('专注', 60000),
        Phase.of('休息', 30000)
      ], 'custom');
      const h1 = new Harness();
      h1.engine.start(scene);
      h1.step(25000);
      const snap: EngineSnapshot | undefined = h1.engine.toSnapshot();
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined) {
        let now2: number = 1155000;
        const eng = LoopEngine.fromSnapshot(snap, (): number => now2, (minMs: number, maxMs: number): number => 20000);
        eng.recompute();
        expect(eng.getPhaseIndex()).assertEqual(1);
        expect(eng.getCycle()).assertEqual(2);
        expect(eng.getCompletedCycles()).assertEqual(1);
        expect(eng.getPhaseElapsedMs()).assertEqual(5000);
      }
    });

    it('templates_sane', 0, () => {
      const list: Scene[] = SceneTemplates.all();
      expect(list.length).assertEqual(6);
      for (let i = 0; i < list.length; i++) {
        expect(list[i].phases.length > 0).assertTrue();
        for (let j = 0; j < list[i].phases.length; j++) {
          expect(list[i].phases[j].durationMs > 0).assertTrue();
        }
        expect(list[i].loopCount >= 0).assertTrue();
      }
      expect(list[0].name).assertEqual('番茄钟');
      expect(list[0].loopCount).assertEqual(4);
      expect(list[0].phases[0].wakeEnabled).assertTrue();
      expect(list[2].loopCount).assertEqual(0); // 喝水无限
      expect(list[2].phases.length).assertEqual(1);
    });
  });
}
