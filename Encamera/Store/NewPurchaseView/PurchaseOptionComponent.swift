import SwiftUI
import EncameraCore

protocol PurchaseOptionComponentProtocol {
    var id: String { get }
    var optionPeriod: String { get }
    var formattedPrice: String { get }
    var billingFrequency: String { get }
    var savingsPercentage: Double? { get }
}

struct PurchaseOptionComponentModel: PurchaseOptionComponentProtocol, Hashable {
    var id: String = UUID().uuidString
    var optionPeriod: String
    var formattedPrice: String
    var billingFrequency: String
    var savingsPercentage: Double?
}

class PurchaseOptionComponentViewModel: ObservableObject {
    @Published var selectedOption: PurchaseOptionComponentModel?
    var options: [PurchaseOptionComponentModel]

    init(options: [PurchaseOptionComponentModel]) {
        self.options = options
    }
}

struct VerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                Color.disabledButtonBackgroundColor
            )
            .frame(width: 1)
    }
}

struct PurchaseOptionComponent: View {
    @StateObject var viewModel: PurchaseOptionComponentViewModel

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ForEach(viewModel.options.indices, id: \.self) { index in
                    ZStack(alignment: .top) {
                        Button {
                            withAnimation {
                                viewModel.selectedOption = viewModel.options[index]
                            }
                        } label: {
                            buttonLabel(for: index)

                        }
                        .padding()
                        .background(viewModel.selectedOption == viewModel.options[index] ? Color.white : Color.clear)
                    }
                    if index < viewModel.options.count - 1 {
                        VerticalDivider()
                    }
                }
            }
            .frame(height: 149)
            .background(Color.black.opacity(0.8))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                Color.disabledButtonBackgroundColor
            ))
            Text(L10n.saveAmount(10).uppercased())
                .fontType(.pt10, on: .darkBackground, weight: .bold)
                .alignmentGuide(VerticalAlignment.top) { d in
                    d[VerticalAlignment.center]
                }
                .padding(.horizontal, 7)
                .background(
                    RoundedRectangle(cornerRadius: 40)    .fill(Color.purchasePopularForegroundShapeColor)

                        .frame(height: 22)

                )
        }
    }

    func buttonLabel(for index: Int) -> some View {
        VStack {
            Text(viewModel.options[index].optionPeriod.uppercased())
                .foregroundStyle(viewModel.selectedOption == viewModel.options[index] ? Color.black : Color.white.opacity(0.6))
                .fontType(.pt12, on: .darkBackground, weight: .bold)

            Spacer()
            Text(viewModel.options[index].formattedPrice)
                .foregroundStyle(viewModel.selectedOption == viewModel.options[index] ? Color.black : Color.white)
                .fontType(.pt20, on: .darkBackground, weight: .bold)
            Spacer()
            Text(viewModel.options[index].billingFrequency)
                .foregroundStyle(viewModel.selectedOption == viewModel.options[index] ? Color.black : Color.white.opacity(0.6))
                .fontType(.pt12, on: .darkBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    let options = [
        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month", savingsPercentage: 0.17),
        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year", savingsPercentage: nil),
        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time", savingsPercentage: nil)
    ]
    ZStack {
        PurchaseOptionComponent(viewModel: .init(options: options))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
}
