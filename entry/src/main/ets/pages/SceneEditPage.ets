import { PageTitleBar } from '../components/PageTitleBar';

@Component
export struct SceneEditPage {
  @Consume('pathStack') pathStack: NavPathStack;

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        PageTitleBar({ title: $r('app.string.title_scene_edit'), onBack: () => this.pathStack.pop() })
        Text($r('app.string.scene_edit_empty_hint'))
          .fontSize(16)
          .fontColor($r('app.color.text_hint'))
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
  }
}
