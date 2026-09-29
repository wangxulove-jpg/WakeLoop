import { ROUTE_SCENE_EDIT, ROUTE_SETTINGS, ROUTE_STATS } from '../common/Routes';
import { pxToVp } from '../common/UiUtils';

@Component
export struct HomePage {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageProp('topAvoidPx') topAvoidPx: number = 0;
  @StorageProp('bottomAvoidPx') bottomAvoidPx: number = 0;
  @State currentTab: number = 0;

  build() {
    Column() {
      this.topBar()
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          this.runningPlaceholder()
        }.tabBar($r('app.string.tab_running'))

        TabContent() {
          this.scenesPlaceholder()
        }.tabBar($r('app.string.tab_scenes'))
      }
      .layoutWeight(1)
      .barWidth('100%')
      .padding({ bottom: pxToVp(this.bottomAvoidPx) })
      .onChange((index: number) => {
        this.currentTab = index;
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  topBar() {
    Row() {
      Text($r('app.string.app_name'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text($r('app.string.title_stats'))
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onClick(() => {
          this.pathStack.pushPathByName(ROUTE_STATS, null);
        })

      Text($r('app.string.title_settings'))
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onClick(() => {
          this.pathStack.pushPathByName(ROUTE_SETTINGS, null);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 8 })
    .margin({ top: pxToVp(this.topAvoidPx) + 8 })
  }

  @Builder
  runningPlaceholder() {
    Column({ space: 12 }) {
      Text($r('app.string.running_empty_hint'))
        .fontSize(16)
        .fontColor($r('app.color.text_hint'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  scenesPlaceholder() {
    Column({ space: 12 }) {
      Text($r('app.string.scenes_empty_hint'))
        .fontSize(16)
        .fontColor($r('app.color.text_hint'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
