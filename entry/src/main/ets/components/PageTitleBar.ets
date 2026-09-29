import { pxToVp } from '../common/UiUtils';

// 公共页头：沉浸式下 NavDestination 系统 TitleBar 不避让状态栏，
// 统一 hideTitleBar(true) + 本组件（旧项目踩坑 #15 最终结论）
@Component
export struct PageTitleBar {
  @Prop title: ResourceStr = '';
  @StorageProp('topAvoidPx') topAvoidPx: number = 0;
  onBack: () => void = () => {};

  build() {
    Row({ space: 4 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(28)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .onClick(() => this.onBack())

      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: 4, right: 16 })
    .margin({ top: pxToVp(this.topAvoidPx) })
  }
}
