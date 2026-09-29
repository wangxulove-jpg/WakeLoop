import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const TAG = 'WakeLoop';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    const dark: boolean = this.isDark(this.context.config);

    // 沉浸式：必须走异步 then 链（同步调用会静默失败，见 docs/鸿蒙App开发指南.md §1.1）
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      mainWindow.setWindowBackgroundColor(dark ? '#121212' : '#F1F3F5');
      mainWindow.setWindowLayoutFullScreen(true).then(() => {
        const barProps: window.SystemBarProperties = {
          statusBarContentColor: dark ? '#ffffff' : '#000000'
        };
        return mainWindow.setWindowSystemBarProperties(barProps);
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'getMainWindow failed: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      // 安全区高度写入 AppStorage，页面用 @StorageProp + pxToVp 避让
      const win = windowStage.getMainWindowSync();
      const topAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('topAvoidPx', topAvoid.topRect.height);
      const bottomAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('bottomAvoidPx', bottomAvoid.bottomRect.height);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 深浅色切换时刷新状态栏图标颜色（资源色由系统自动重匹配）
    window.getLastWindow(this.context).then((win: window.Window) => {
      const dark: boolean = this.isDark(newConfig);
      const props: window.SystemBarProperties = {
        statusBarContentColor: dark ? '#ffffff' : '#000000'
      };
      win.setWindowSystemBarProperties(props).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', JSON.stringify(err));
    });
  }

  private isDark(config: Configuration): boolean {
    return config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
}
