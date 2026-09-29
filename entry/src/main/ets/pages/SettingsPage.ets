import { PageTitleBar } from '../components/PageTitleBar';

@Component
export struct SettingsPage {
  @Consume('pathStack') pathStack: NavPathStack;

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        PageTitleBar({ title: $r('app.string.title_settings'), onBack: () => this.pathStack.pop() })
        Text($r('app.string.settings_empty_hint'))
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
