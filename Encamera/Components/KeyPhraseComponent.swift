import SwiftUI
import TagCloud
import SwiftUI

struct ItemView: View {
    let text: String

    var body: some View {
        HStack(spacing: Constants.spacing) {
            Text(text)
                .fontType(.pt16, weight: .bold)
                .foregroundColor(.white)
        }
        .padding(.all, Constants.padding)
        .background(Constants.backgroundColor)
        .cornerRadius(Constants.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Constants.cornerRadius)
                .inset(by: Constants.inset)
                .stroke(Constants.borderColor, lineWidth: Constants.lineWidth)
        )
    }
}

extension ItemView {
    private enum Constants {
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 10
        static let cornerRadius: CGFloat = 80
        static let inset: CGFloat = 0.5
        static let lineWidth: CGFloat = 0.5
        static let opacity: Double = 0.60
        static let backgroundColor = Color(red: 0.09, green: 0.09, blue: 0.09)
        static let borderColor = Color(red: 1, green: 1, blue: 1).opacity(0.10)
        static let fontSize: CGFloat = 14
        static let fontName = "Satoshi Variable"
    }
}

struct KeyPhraseComponent: View {
  let words: [String]

  var body: some View {
      TagCloudView(data: words) { element in
          ItemView(text: element)

      }
  }
}

#Preview {
    KeyPhraseComponent(words: ["Hello", "World", "I", "love", "Swift", "and", "tag", "clouds"])
}
