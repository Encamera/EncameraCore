import SwiftUI
import EncameraCore

struct Feedback: Codable {
    let id: String
    let feedback: String
}

struct FeedbackView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var feedbackText: String = ""

    var body: some View {
        VStack {
            VStack(spacing: 34) {
                ViewHeader(title: L10n.FeedbackView.title, rightContent: {
                    Button {
                        dismiss()
                    } label: {
                        Image("Close-X")
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .foregroundStyle(.white)
                    }
                    .frostedButton()
                })
                Group {
                    Text(L10n.FeedbackView.subheading)
                        .fontType(.pt16, weight: .bold)

                    ZStack(alignment: .topLeading) {
                        if feedbackText.isEmpty {
                            Text(L10n.FeedbackView.placeholderText)
                                .foregroundColor(.gray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 12)
                        }
                        TextEditor(text: $feedbackText)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .fontType(.pt16)
                            .scrollContentBackgroundColor(.clear)
                            .background(Color.clear)
                            .becomeFirstResponder()
                    }
                }.padding(.leading, 17)
            }
            .padding(.bottom, 20)

            Spacer()

            DualButtonComponent(nextActive: .constant(false), bottomButtonTitle: L10n.FeedbackView.submit, bottomButtonAction: {
                submitFeedback()
            })
        }
        .gradientBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitFeedback() {
        let feedback = Feedback(id: UUID().uuidString, feedback: feedbackText)

        guard let postData = try? JSONEncoder().encode(feedback) else {
            print("Failed to encode feedback")
            return
        }

        var request = URLRequest(url: AppConstants.feedbackApiURL, timeoutInterval: Double.infinity)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = postData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else {
                print(String(describing: error))
                return
            }
            print(String(data: data, encoding: .utf8)!)
            DispatchQueue.main.async {
                dismiss()
            }
        }
        task.resume()
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

struct FeedbackView_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackView()
    }
}
