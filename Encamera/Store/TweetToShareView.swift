//
//  TweetToShareView.swift
//  Encamera
//
//  Created by Alexander Freas on 12.05.23.
//

import SwiftUI
import EncameraCore

struct TweetToShareView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack {
                    Text(L10n.tweetToRedeemOfferExplanation)
                        .padding()
                        .fontType(.pt24)
                        .lineLimit(nil)

                    Button(action: {
                        if let url = URL(string: "https://twitter.com/encamera_app") {
                            openURL(url)
                        }
                    }) {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                            Text(L10n.followUs)
                                .fontType(.medium)
                                .lineLimit(nil)
                        }
                    }
                    .primaryButton()
                    .padding()

                    Button(action: {
                        if let url = URL(string: "https://ctt.ac/R93eX") {
                            openURL(url)
                        }
                    }) {
                        HStack {
                            Image("twitter-logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                            Text(L10n.tapToTweet)
                                .fontType(.medium)
                                .lineLimit(nil)
                        }
                    }
                    .primaryButton()
                    .padding()

                    Text(L10n.youWillBeSentAPromoCode)
                        .padding()
                        .fontType(.pt24)
                        .lineLimit(nil)
                }
                .navigationTitle(L10n.getOneYearFree)
                .toolbar {
                    Button(L10n.close) {
                        dismiss()
                    }
                }
                
            }


        }
    }

    // Function to open the URL
    func openURL(_ url: URL) {
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

struct TweetToShareView_Previews: PreviewProvider {
    static var previews: some View {
        Text("hey").sheet(isPresented: .constant(true)) {
            TweetToShareView()
                .preferredColorScheme(.dark)
        }
        
    }
}
