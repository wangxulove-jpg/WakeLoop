import { HomePage } from './HomePage';
import { SceneEditPage } from './SceneEditPage';
import { StatsPage } from './StatsPage';
import { SettingsPage } from './SettingsPage';
import { ROUTE_SCENE_EDIT, ROUTE_SETTINGS, ROUTE_STATS } from '../common/Routes';

// 全局路由表：所有 NavDestination 页面在此注册（参数强类型走 common/Routes）
@Entry
@Component
struct Index {
  @Provide('pathStack') pathStack: NavPathStack = new NavPathStack();

  @Builder
  pageMap(name: string) {
    if (name === ROUTE_STATS) {
      StatsPage()
    } else if (name === ROUTE_SETTINGS) {
      SettingsPage()
    } else if (name === ROUTE_SCENE_EDIT) {
      SceneEditPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      HomePage()
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .backgroundColor($r('app.color.page_bg'))
  }
}
