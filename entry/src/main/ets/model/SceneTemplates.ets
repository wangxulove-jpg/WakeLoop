import { Phase, Scene } from '../common/Types';

const MIN: number = 60000;

// 内置模板：全部由 Scene/Phase 模型派生，用户可"另存为自定义"
export class SceneTemplates {
  static all(): Scene[] {
    const list: Scene[] = [];
    // 番茄钟：25 专注（随机唤醒 3-5min + 10s 微休息）/ 5 休息 × 4 轮
    list.push(Scene.of('tpl_pomodoro', '番茄钟', 0, 4, [
      Phase.wakeOf('专注', 25 * MIN, 3 * MIN, 5 * MIN, 10000),
      Phase.of('休息', 5 * MIN)
    ], 'template'));
    // BRAC 生理节律：90 专注（随机唤醒）/ 20 休息，无限
    list.push(Scene.of('tpl_brac', 'BRAC 循环', 1, 0, [
      Phase.wakeOf('专注', 90 * MIN, 3 * MIN, 5 * MIN, 10000),
      Phase.of('休息', 20 * MIN)
    ], 'template'));
    // 喝水提醒：60 分钟单阶段，无限
    list.push(Scene.of('tpl_water', '喝水提醒', 5, 0, [
      Phase.of('喝水', 60 * MIN)
    ], 'template'));
    // 久坐站立：45 工作 / 5 站立活动，无限
    list.push(Scene.of('tpl_stand', '久坐站立', 2, 0, [
      Phase.of('工作', 45 * MIN),
      Phase.of('站立活动', 5 * MIN)
    ], 'template'));
    // 小睡：20 分钟单阶段，1 轮
    list.push(Scene.of('tpl_nap', '小睡', 3, 1, [
      Phase.of('小睡', 20 * MIN)
    ], 'template'));
    // 学习循环：50 学习（随机唤醒 4-6min）/ 10 休息 × 3 轮
    list.push(Scene.of('tpl_study', '学习循环', 4, 3, [
      Phase.wakeOf('学习', 50 * MIN, 4 * MIN, 6 * MIN, 10000),
      Phase.of('休息', 10 * MIN)
    ], 'template'));
    return list;
  }
}
