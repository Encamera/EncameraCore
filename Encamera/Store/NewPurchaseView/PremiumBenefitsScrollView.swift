import SwiftUI

struct PremiumBenefitsScrollView: View {
    var body: some View {
        BenefitsView()
    }
}

struct BenefitModel: Equatable {
    let iconName: String
    let text: String
}

struct BenefitsView: View {
    let benefits: [BenefitModel] = [
        BenefitModel(iconName: "photo", text: "Unlimited storage for photos & videos"),
        BenefitModel(iconName: "rectangle.stack", text: "Unlimited albums for your memories"),
        BenefitModel(iconName: "icloud", text: "iCloud storage & backup"),
        BenefitModel(iconName: "app.gift", text: "Change app icon"),
        BenefitModel(iconName: "key.icloud", text: "Backup keychain to iCloud"),
        BenefitModel(iconName: "eye.slash", text: "Hidden albums"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock all of these benefits:")
                .fontType(.pt24, on: .darkBackground, weight: .bold)
                .foregroundColor(.white)
            Spacer().frame(height: 24)
            ForEach(benefits, id: \..text) { benefit in
                BenefitItem(model: benefit)

                if benefit != benefits.last {
                    Divider()
                        .background(Color.gray)
                }
            }
        }
        .padding()
        .background(Color.black)
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
        }
    }
}

#Preview {
    PremiumBenefitsScrollView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.edgesIgnoringSafeArea(.all))
}
