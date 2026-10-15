import SwiftUI
import StripleCore
import StripleEngine

/// The strip: how columns are placed and sized, and the gaps around them.
struct LayoutTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("Strip") {
                Picker("Center the focused column", selection: store.binding(\.layout.centerMode)) {
                    ForEach(CenterMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                PercentRow(title: "Width of a new window", fraction: store.binding(\.layout.defaultWidth), range: 5...100)
                PercentRow(title: "Wider and narrower step", fraction: store.binding(\.layout.widthStep), range: 1...50, step: 1)
                PercentRow(title: "Taller and shorter step", fraction: store.binding(\.layout.heightStep), range: 1...50, step: 1)
                PresetWidthsEditor(store: store)
                NumberRow(title: "Tab bar height", value: store.binding(\.layout.tabBarHeight), range: 16...60)
            }

            Section("Gaps") {
                NumberRow(title: "Between windows", value: store.binding(\.layout.innerGap), range: 0...200)
                NumberRow(title: "Top edge", value: store.binding(\.layout.outerGaps.top), range: 0...400)
                NumberRow(title: "Bottom edge", value: store.binding(\.layout.outerGaps.bottom), range: 0...400)
                NumberRow(title: "Left edge", value: store.binding(\.layout.outerGaps.left), range: 0...400)
                NumberRow(title: "Right edge", value: store.binding(\.layout.outerGaps.right), range: 0...400)
            }
        }
        .formStyle(.grouped)
    }
}
