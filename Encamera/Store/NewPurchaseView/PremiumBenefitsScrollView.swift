import SwiftUI
import EncameraCore


struct BenefitModel: Equatable {
    let iconName: String
    let text: String
    let comingSoon: Bool

    init(iconName: String, text: String, comingSoon: Bool = false) {
        self.iconName = iconName
        self.text = text
        self.comingSoon = comingSoon
    }
}

struct PremiumBenefitsScrollView: View {

    @Binding var isPremium: Bool

    let benefits: [BenefitModel] = [
        BenefitModel(iconName: "photo", text: L10n.PurchaseView.BenefitModel.unlimitedStorage),
        BenefitModel(iconName: "rectangle.stack", text: L10n.PurchaseView.BenefitModel.unlimitedAlbums),
        BenefitModel(iconName: "icloud", text: L10n.PurchaseView.BenefitModel.iCloudStorage),
        BenefitModel(iconName: "key.icloud", text: L10n.PurchaseView.BenefitModel.backupKeychain, comingSoon: false),
        BenefitModel(iconName: "app.gift", text: L10n.PurchaseView.BenefitModel.changeAppIcon, comingSoon: true),
        BenefitModel(iconName: "eye.slash", text: L10n.PurchaseView.BenefitModel.hiddenAlbums, comingSoon: true)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isPremium ? L10n.PurchaseView.yourBenefits : L10n.PurchaseView.unlockBenefits)
                .fontType(.pt24, on: .darkBackground, weight: .bold)
                .foregroundColor(.white)
            Spacer().frame(height: Spacing.pt16.rawValue)
            ForEach(benefits, id: \..text) { benefit in
                BenefitItem(model: benefit)

                if benefit != benefits.last {
                    Divider()
                        .background(Color.gray)
                }
            }
        }
        .padding()
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}

struct BenefitItem: View {
    let model: BenefitModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.iconName)
                .foregroundColor(Color.actionYellowGreen)
                .font(.title2)
                .frame(minWidth: 40)
            Text(model.text)
                .fontType(.pt14, on: .darkBackground)
                .foregroundColor(.white)
            Spacer()
            if model.comingSoon {
                Text(L10n.PurchaseView.BenefitModel.comingSoon.uppercased())
                    .fontType(.pt12, weight: .bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.disabledButtonTextColor)
                    .cornerRadius(4)
            }
        }
    }
}

#Preview {
    PremiumBenefitsScrollView(isPremium: .constant(true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.edgesIgnoringSafeArea(.all))
}
