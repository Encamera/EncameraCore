import SwiftUI
import EncameraCore


protocol PremiumPurchasableCollection {
    var options: [any PremiumPurchasable] { get }
    var defaultSelection: (any PremiumPurchasable)? { get }
    func yearlySavings() -> SubscriptionSavings?

}

protocol PremiumPurchasable: Equatable, Hashable {
    var id: String { get }
    var optionPeriod: String { get }
    var formattedPrice: String { get }
    var billingFrequency: String { get }
    var purchaseActionText: String { get }
    var isEligibleForIntroOffer: Bool { get }
}

struct PurchaseOptionCollectionModel: PremiumPurchasableCollection {
    var defaultSelection: (any PremiumPurchasable)?
    
    var options: [any PremiumPurchasable]

    func yearlySavings() -> SubscriptionSavings? {
        return nil
    }
}

struct PurchaseOptionComponentModel: PremiumPurchasable, Hashable {
    var id: String = UUID().uuidString
    var optionPeriod: String
    var formattedPrice: String
    var billingFrequency: String
    var purchaseActionText: String = "Purchase"
    var isEligibleForIntroOffer: Bool = false
}

class PurchaseOptionComponentViewModel: ObservableObject {
    @Published var optionsCollection: PremiumPurchasableCollection

    var savingsString: String? {
        guard let savings = optionsCollection.yearlySavings() else { return nil }
        return savings.formattedTotalSavings
    }

    init(optionsCollection: PremiumPurchasableCollection) {
        self.optionsCollection = optionsCollection
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
    @ObservedObject var viewModel: PurchaseOptionComponentViewModel
    @Binding var selectedOption: (any PremiumPurchasable)?

    @State var defaultOption: (any PremiumPurchasable)? {
        didSet {
            selectedOption = defaultOption
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ForEach(viewModel.optionsCollection.options.indices, id: \.self) { index in
                    button(for: index)
                    if index < viewModel.optionsCollection.options.count - 1 {
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
            if let savings = viewModel.savingsString {
                savingsText(savingsString: savings)
            }
        }
        
    }

    func savingsText(savingsString: String) -> some View {
        Text(savingsString)
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

    func button(for index: Int) -> some View {
        Button {
            withAnimation {
                defaultOption = viewModel.optionsCollection.options[index]
            }
        } label: {
            buttonLabel(for: index)

        }
        .padding()
        .background(defaultOption?.id == viewModel.optionsCollection.options[index].id ? Color.white : Color.clear)
    }

    func buttonLabel(for index: Int) -> some View {
        VStack {
            let option = viewModel.optionsCollection.options[index]
            Text(option.optionPeriod.uppercased())
                .foregroundStyle(defaultOption?.id == option.id ? Color.black : Color.white.opacity(0.6))
                .fontType(.pt12, on: .darkBackground, weight: .bold)
            Spacer()
            Text(option.formattedPrice)
                .foregroundStyle(defaultOption?.id == option.id ? Color.black : Color.white)
                .fontType(.pt20, on: .darkBackground, weight: .bold)
            Spacer()
            Text(option.billingFrequency)
                .foregroundStyle(defaultOption?.id == option.id ? Color.black : Color.white.opacity(0.6))
                .fontType(.pt12, on: .darkBackground)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

//#Preview {
//    let options = PurchaseOptionCollectionModel(options: [
//        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month"),
//        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year"),
//        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time")
//    ])
//    ZStack {
//        PurchaseOptionComponent(viewModel: .init(options: options), selectedOption: .constant(options[1]))
//    }
//    .frame(maxWidth: .infinity, maxHeight: .infinity)
//    .background(Color.black)
//}
