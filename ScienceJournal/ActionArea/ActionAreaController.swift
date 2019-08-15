/*
 *  Copyright 2019 Google LLC. All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

import SnapKit
import UIKit

import third_party_objective_c_material_components_ios_components_AppBar_AppBar

extension ActionArea {

  /// Manages presentation and adaptivity for the Action Area.
  final class Controller: UIViewController {

    private struct Metrics {
      static let defaultAnimationDuration: TimeInterval = 0.4

      // The fractional width of the master content area.
      static let preferredPrimaryColumnWidthFraction: CGFloat = 0.6
    }

    private enum State {
      case normal
      case modal
    }

    /// The navigation controller that displays content in a master context.
    /// This is currently here for backwards compatibility. Consider using `show` if appropriate.
    let navController: UINavigationController = {
      let nc = UINavigationController()
      nc.isNavigationBarHidden = true
      return nc
    }()

    private let detailNavController: UINavigationController = {
      let nc = UINavigationController()
      nc.isNavigationBarHidden = true
      return nc
    }()

    // TODO: Make this non-optional
    private var buttonBarViewController: Bar?
    private let svController = UISplitViewController()
    private var presentedDetailViewController: UIViewController?
    private let preferredPrimaryColumnWidthFractionWhenDetailIsHidden: CGFloat = 1.0

    private var state: State = .normal {
      willSet {
        guard state != newValue else {
          fatalError("Setting the state to the existing state is not allowed.")
        }
      }

      didSet {
        guard let presentedDetailViewController = presentedDetailViewController else {
          fatalError("The state can only be changed when a detailViewController is shown.")
        }

        if state == .normal, presentedDetailViewController.parent == nil {
          // If there's no `parent`, the detail was already dismissed, so we need to clean up.
          self.presentedDetailViewController = nil
        }
        updateActionAreaBar()
      }
    }

    // MARK: - Initializers

    init() {
      precondition(FeatureFlags.isActionAreaEnabled,
                   "This class can only be used when Action Area is enabled.")
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
      super.viewDidLoad()

      navController.delegate = self
      detailNavController.delegate = self

      // Set `viewControllers` first to avoid warnings.
      svController.viewControllers = [navController, detailNavController]
      svController.presentsWithGesture = false
      // When set to `automatic`, iPad uses `primaryOverlay` in portrait orientations, which
      // can result in `viewDidAppear` not being called on detail view controllers.
      svController.preferredDisplayMode = .allVisible
      svController.delegate = self

      let longestDimension = max(UIScreen.main.bounds.height, UIScreen.main.bounds.width)
      svController.minimumPrimaryColumnWidth =
        floor(longestDimension * Metrics.preferredPrimaryColumnWidthFraction)
      svController.maximumPrimaryColumnWidth = longestDimension

      let buttonBarViewController = Bar(contentViewController: svController)
      addChild(buttonBarViewController)
      view.addSubview(buttonBarViewController.view)
      buttonBarViewController.view.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      buttonBarViewController.didMove(toParent: self)
      self.buttonBarViewController = buttonBarViewController

      updateSplitViewTraits(for: view.bounds.size)
      updateSplitViewDetailVisibility()
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
      // Update traits *before* calling `super`, which will delegate this call to children.
      updateSplitViewTraits(for: size)
      super.viewWillTransition(to: size, with: coordinator)
    }

    private func updateSplitViewTraits(for size: CGSize) {
      guard let buttonBarViewController = buttonBarViewController else { return }

      func overrideHorizontalSizeClassToCompact(_ vc: UIViewController) {
        let horizontallyCompact = UITraitCollection(horizontalSizeClass: .compact)
        setOverrideTraitCollection(horizontallyCompact, forChild: vc)
      }

      if UIDevice.current.userInterfaceIdiom == .pad {
        if size.isWiderThanTall {
          setOverrideTraitCollection(nil, forChild: buttonBarViewController)
        } else {
          overrideHorizontalSizeClassToCompact(buttonBarViewController)
        }
      } else {
        overrideHorizontalSizeClassToCompact(buttonBarViewController)
      }
    }

    private func updateSplitViewDetailVisibility() {
      let shouldShowDetail = navController.topViewController is MasterContent
      let preferredPrimaryColumnWidthFraction: CGFloat
      if shouldShowDetail {
        preferredPrimaryColumnWidthFraction = Metrics.preferredPrimaryColumnWidthFraction
      } else {
        preferredPrimaryColumnWidthFraction = preferredPrimaryColumnWidthFractionWhenDetailIsHidden
      }

      svController.preferredPrimaryColumnWidthFraction = preferredPrimaryColumnWidthFraction
    }

    private func removeUnusedDetailEmptyStates() {
      if svController.isExpanded {
        var topMasterContent: MasterContent?
        for vc in navController.viewControllers.reversed() {
          if let master = vc as? ActionArea.MasterContent {
            topMasterContent = master
            break
          }
        }
        if let topMasterContent = topMasterContent {
          detailNavController.popToViewController(topMasterContent.emptyState, animated: true)
        } else {
          detailNavController.setViewControllers([], animated: false)
        }
      }
    }

    private func removeDismissedDetailViewController() {
      if let presentedDetailViewController = presentedDetailViewController {
        let viewControllers = navController.viewControllers + detailNavController.viewControllers
        if !viewControllers.contains(presentedDetailViewController) {
          switch state {
          case .normal:
            self.presentedDetailViewController = nil
          case .modal:
            if svController.isExpanded {
              fatalError("The detailViewController cannot be dismissed in the modal state.")
            }
          }
        }
      }
    }

    private func updateActionAreaBar() {
      func items(for content: Content) -> [UIBarButtonItem] {
        switch content.mode {
        case let .stateless(items):
          return items.map(createBarButtonItem(from:))
        case let .stateful(nonModal, modal):
          switch state {
          case .normal:
            return nonModal.items
              .map(createBarButtonItem(from:)) + [wrapBarButtonItem(from: nonModal.primary)]
          case .modal:
            return modal.items
              .map(createBarButtonItem(from:)) + [wrapBarButtonItem(from: modal.primary)]
          }
        }
      }

      let newItems: [UIBarButtonItem]
      if let detail = presentedDetailViewController as? DetailContent {
        newItems = items(for: detail)
      } else if presentedDetailViewController != nil {
        newItems = []
      } else if let master = navController.topViewController as? MasterContent {
        newItems = items(for: master)
      } else {
        newItems = []
      }

      buttonBarViewController?.items = newItems
    }

    private func createBarButtonItem(from item: BarButtonItem) -> UIBarButtonItem {
      let barButtonItem = UIBarButtonItem(title: item.title,
                                          style: .plain,
                                          target: item,
                                          action: #selector(BarButtonItem.execute))
      barButtonItem.image = item.image
      return barButtonItem
    }

    // TODO: Figure out when/where to nil this out
    private var wrapper: BarButtonItem?

    private func wrapBarButtonItem(from item: BarButtonItem) -> UIBarButtonItem {
      let wrapper = BarButtonItem(
        title: item.title,
        image: item.image
      ) {
        item.action()
        self.toggleState()
      }
      self.wrapper = wrapper
      return createBarButtonItem(from: wrapper)
    }

    private func toggleState() {
      state = state == .normal ? .modal : .normal
    }

    // MARK: - API

    /// Present content in a master context.
    ///
    /// - Parameters:
    ///   - vc: The view controller to show.
    ///   - sender: The object calling this method.
    override func show(_ vc: UIViewController, sender: Any?) {
      guard state == .normal else {
        fatalError("View controllers cannot be pushed during a modal detail presentation.")
      }

      svController.show(vc, sender: sender)
    }

    /// Present content in a master context.
    ///
    /// - Parameters:
    ///   - vc: The view controller to show.
    ///   - sender: The object calling this method.
    func show(_ vc: MasterContent, sender: Any?) {
      guard state == .normal else {
        fatalError("View controllers cannot be pushed during a modal detail presentation.")
      }

      svController.show(vc, sender: sender)
    }

    /// Present content in a detail context.
    ///
    /// - Parameters:
    ///   - vc: The view controller to show.
    ///   - sender: The object calling this method.
    override func showDetailViewController(_ vc: UIViewController, sender: Any?) {
      guard presentedDetailViewController == nil else {
        fatalError("A detailViewController is already being shown.")
      }

      svController.showDetailViewController(vc, sender: sender)
    }

    /// Present content in a detail context.
    ///
    /// - Parameters:
    ///   - vc: The view controller to show.
    ///   - sender: The object calling this method.
    func showDetailViewController(_ vc: DetailContent, sender: Any?) {
      guard presentedDetailViewController == nil else {
        fatalError("A detailViewController is already being shown.")
      }

      svController.showDetailViewController(vc, sender: sender)
    }

    /// Re-present detail content that was dismissed in the `modal` state.
    ///
    /// Calling this method when no detail content was presented or the Action Area is not in the
    /// `modal` state is an error.
    func reshowDetail() {
      guard let presentedDetailViewController = presentedDetailViewController else {
        fatalError("A detailViewController is not currently being shown.")
      }
      guard state == .modal else {
        fatalError("The Action Area can only reshow in the modal state.")
      }

      if svController.isCollapsed {
        svController.showDetailViewController(presentedDetailViewController, sender: self)
      }
      // Otherwise the detailViewController is already on screen.
    }

  }

}

// MARK: - UISplitViewControllerDelegate

extension ActionArea.Controller: UISplitViewControllerDelegate {

  func primaryViewController(
    forCollapsing splitViewController: UISplitViewController
  ) -> UIViewController? {
    return nil // nil for default behavior
  }

  func splitViewController(_ splitViewController: UISplitViewController,
                           collapseSecondary secondaryViewController: UIViewController,
                           onto primaryViewController: UIViewController) -> Bool {
    if let presentedDetailViewController = presentedDetailViewController {
      detailNavController.setViewControllers([], animated: false)
      navController.pushViewController(presentedDetailViewController, animated: true)
    }
    return true // false for default behavior
  }

  func primaryViewController(
    forExpanding splitViewController: UISplitViewController
  ) -> UIViewController? {
    return nil // nil for default behavior
  }

  func splitViewController(
    _ splitViewController: UISplitViewController,
    separateSecondaryFrom primaryViewController: UIViewController
  ) -> UIViewController? {
    let emptyStates: [UIViewController] =
      navController.viewControllers.reduce(into: []) { emptyStates, vc in
        if let master = vc as? ActionArea.MasterContent {
          emptyStates.append(master.emptyState)
        }
      }
    detailNavController.setViewControllers(emptyStates, animated: false)
    if let presentedDetailViewController = presentedDetailViewController {
      navController.popViewController(animated: true)
      detailNavController.pushViewController(presentedDetailViewController, animated: true)
    }
    return detailNavController // nil for default behavior
  }

  func splitViewController(_ splitViewController: UISplitViewController,
                           show vc: UIViewController, sender: Any?) -> Bool {
    if let vc = vc as? ActionArea.MasterContent {
      if svController.isExpanded {
        if detailNavController.viewControllers.isEmpty {
          detailNavController.pushViewController(vc.emptyState, animated: false)
        } else {
          detailNavController.pushViewController(vc.emptyState, animated: true)
        }
      }
    }
    navController.pushViewController(vc, animated: true)
    return true // false for default behavior
  }

  func splitViewController(_ splitViewController: UISplitViewController,
                           showDetail vc: UIViewController, sender: Any?) -> Bool {
    presentedDetailViewController = vc
    if splitViewController.isCollapsed {
      navController.pushViewController(vc, animated: true)
    } else {
      detailNavController.pushViewController(vc, animated: true)
    }
    return true // false for default behavior
  }

}

// MARK: - UINavigationControllerDelegate

extension ActionArea.Controller: UINavigationControllerDelegate {

  func navigationController(_ navigationController: UINavigationController,
                            willShow viewController: UIViewController,
                            animated: Bool) {
    if navigationController == navController {
      removeDismissedDetailViewController()

      UIView.animate(withDuration: Metrics.defaultAnimationDuration) {
        self.updateActionAreaBar()
        self.updateSplitViewDetailVisibility()
        self.removeUnusedDetailEmptyStates()
      }
    }

    if navigationController == detailNavController {
      removeDismissedDetailViewController()
      updateActionAreaBar()
    }
  }

}

// MARK: - UISplitViewController Extensions

private extension UISplitViewController {

  var isExpanded: Bool { return !isCollapsed }

}

// MARK: - UIViewController Extensions

extension UIViewController {

  var actionAreaController: ActionArea.Controller? {
    var candidate: UIViewController? = parent
    while candidate != nil {
      if let aac = candidate as? ActionArea.Controller {
        return aac
      }
      candidate = candidate?.parent
    }
    return nil
  }

}

// MARK: - Speculative Types

// TODO: Ensure this handles existing issues or use one of the other superclasses.
// TODO: Consider making this private and wrapping content VCs that are not subclasses
//       of the other material header types.
final class MaterialHeaderContainerViewController: UIViewController {

  override var navigationItem: UINavigationItem {
    return content.navigationItem
  }

  private let appBar = MDCAppBar()
  private let content: UIViewController

  init(content: UIViewController) {
    self.content = content
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    addChild(content)
    view.addSubview(content.view)
    content.didMove(toParent: self)

    if let collectionViewController = content as? UICollectionViewController {
      appBar.configure(attachTo: self, scrollView: collectionViewController.collectionView)
    } else {
      appBar.configure(attachTo: self)
    }

    content.view.snp.makeConstraints { make in
      make.top.equalTo(appBar.navigationBar.snp.bottom)
      make.leading.bottom.trailing.equalToSuperview()
    }
  }

  override var description: String {
    return "\(type(of: self))(content: \(String(describing: content)))"
  }

}

// MARK: - Debugging

extension ActionArea.Controller {

  private func log(debuggingInfoFor svc: UISplitViewController?,
                   verbose: Bool = false,
                   function: String = #function) {
    guard let svc = svc else { return }
    var message = "ActionArea.\(type(of: self)).\(function)"
    message += " - vcs: \(svc.viewControllers.map(vcName(_:)))"
    message += ", isCollapsed: \(svc.isCollapsed)"
    message += ", displayMode: \(svc.displayMode)"
    if verbose {
      message += ", navController.vcs: \(navController.viewControllers.map(vcName(_:)))"
      message += ", detailNavController.vcs: \(detailNavController.viewControllers.map(vcName(_:)))"
    }
    print(message)
  }

  private func vcName(_ vc: UIViewController) -> String {
    if vc === navController {
      return "navController"
    } else if vc === detailNavController {
      return "detailNavController"
    } else {
      let d = String(describing: vc)
      if d.starts(with: "<third_party_sciencejournal") {
        return d.split(separator: ":").first?
          .split(separator: ".").last
          .map(String.init) ?? d
      } else {
        return d
      }
    }
  }

  private func logAsync(debuggingInfoFor svc: UISplitViewController?,
                        function: String = #function) {
    DispatchQueue.main.async {
      self.log(debuggingInfoFor: svc, verbose: true, function: function)
    }
  }

}

extension UISplitViewController.DisplayMode: CustomStringConvertible {

  public var description: String {
    switch self {
    case .automatic:
      return "automatic"
    case .primaryHidden:
      return "primaryHidden"
    case .allVisible:
      return "allVisible"
    case .primaryOverlay:
      return "primaryOverlay"
    }
  }

}
