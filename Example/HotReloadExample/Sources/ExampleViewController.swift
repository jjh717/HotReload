import UIKit

// MARK: - UIKit Hot Reload Example
//
// How to test:
//   1. Run this app on the iOS Simulator (Debug build)
//   2. Change the background color or label text below
//   3. Press Cmd+S
//   4. The UI updates instantly without rebuilding

class ExampleViewController: UIViewController {

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "HotReload Example"
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "Edit this file and press Cmd+S.\nThe UI will update instantly."
        label.font = .systemFont(ofSize: 16)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit"
        makeUI()

        #if DEBUG && targetEnvironment(simulator)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(injected),
            name: Notification.Name("HotReloadInjected"),
            object: nil
        )
        #endif
    }

    private func makeUI() {
        // Try changing this color and press Cmd+S
        view.backgroundColor = .systemBackground

        view.addSubview(titleLabel)
        view.addSubview(descriptionLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    #if DEBUG && targetEnvironment(simulator)
    @objc func injected() {
        view.subviews.forEach { $0.removeFromSuperview() }
        makeUI()
    }
    #endif
}
