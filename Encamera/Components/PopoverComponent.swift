//
//  PopoverComponent.swift
//  Encamera
//
//  Created by Alexander Freas on 27.02.24.
//

import SwiftUI
import Foundation
import UIKit
import EncameraCore

struct PopOverController<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var backgroundColor: Color
    var arrowDirection: UIPopoverArrowDirection
    var content: Content

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        return controller
    }

    func makeCoordinator() -> PopOverCoordinator {
        PopOverCoordinator(parent: self)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if isPresented {
            let controller = PopOverHostingView(rootView: content)
            controller.view.backgroundColor = .tertiarySystemBackground
            if let cgColor = self.backgroundColor.cgColor {
                controller.view.backgroundColor = UIColor(cgColor: cgColor)
            }
            controller.modalPresentationStyle = .popover
            controller.presentationController?.delegate = context.coordinator
            controller.popoverPresentationController?.sourceView = uiViewController.view
            controller.popoverPresentationController?.permittedArrowDirections = arrowDirection
            uiViewController.present(controller, animated: true)
        }
    }

    class PopOverCoordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var parent: PopOverController

        init(parent: PopOverController) {
            self.parent = parent
        }

        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
            .none
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            parent.isPresented = false
        }
    }
}

extension View {
    @ViewBuilder
    public func customPopover<Content: View>(isPresented: Binding<Bool>,
                                             color: Color,
                                             arrowDirection: UIPopoverArrowDirection = .down,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        self
            .background {
                PopOverController(isPresented: isPresented, backgroundColor: color, arrowDirection: arrowDirection, content: content())
            }
    }
}

class PopOverHostingView<Content: View>: UIHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = view.intrinsicContentSize
    }
}
