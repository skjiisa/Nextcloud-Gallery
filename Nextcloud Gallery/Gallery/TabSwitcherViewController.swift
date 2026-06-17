//
//  TabSwitcherViewController.swift
//  Nextcloud Gallery
//
//  The Safari-style overview: every open tab as a card showing a snapshot of where
//  it's parked. Tap to switch, ✕ to close, + for a new tab.
//

import UIKit

final class TabSwitcherViewController: UIViewController {
    private let tabs: TabsModel
    private var collectionView: UICollectionView!
    private var observation: ObservationToken?

    init(tabs: TabsModel) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let nav = UINavigationBar()
        nav.translatesAutoresizingMaskIntoConstraints = false
        let item = UINavigationItem()
        item.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(newTab))
        item.leftBarButtonItem?.accessibilityLabel = "New Tab"
        item.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        nav.items = [item]
        view.addSubview(nav)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(TabCardCell.self, forCellWithReuseIdentifier: TabCardCell.reuseID)
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nav.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: nav.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.navItem = item
        updateTitle()

        observation = observeChanges { [weak self] in
            guard let self else { return }
            _ = self.tabs.tabs.map(\.id)
            _ = self.tabs.activeTabID
            self.collectionView.reloadData()
            self.updateTitle()
        }
    }

    private weak var navItem: UINavigationItem?

    private func updateTitle() {
        let count = tabs.tabs.count
        navItem?.title = "\(count) \(count == 1 ? "Tab" : "Tabs")"
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, env in
            let spacing: CGFloat = 16
            let inset: CGFloat = 16
            let width = env.container.effectiveContentSize.width
            let columns = max(2, Int((width - inset * 2 + spacing) / (150 + spacing)))
            let itemWidth = (width - inset * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cardHeight = itemWidth / 0.72 + 28 // card + title

            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(cardHeight)),
                subitems: [item]
            )
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
            return section
        }
    }

    @objc private func newTab() {
        tabs.newTab()
        tabs.isShowingSwitcher = false
    }

    @objc private func done() {
        tabs.isShowingSwitcher = false
    }
}

extension TabSwitcherViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.tabs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabCardCell.reuseID, for: indexPath) as! TabCardCell
        let tab = tabs.tabs[indexPath.item]
        cell.configure(snapshot: tab.snapshot, title: tab.title, isActive: tab.id == tabs.activeTabID) { [weak self] in
            self?.tabs.closeTab(tab.id)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let tab = tabs.tabs[indexPath.item]
        tabs.select(tab.id)
        tabs.isShowingSwitcher = false
    }
}

// MARK: - Card cell

final class TabCardCell: UICollectionViewCell {
    static let reuseID = "TabCardCell"

    private let card = UIView()
    private let imageView = UIImageView()
    private let placeholder = UIImageView(image: UIImage(systemName: "photo.on.rectangle.angled"))
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let cornerRadius: CGFloat = 14

    private var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.backgroundColor = .tertiarySystemFill
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imageView)

        placeholder.tintColor = .secondaryLabel
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = .init(pointSize: 34)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(placeholder)

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(weight: .bold)), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeButton.layer.cornerRadius = 14
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        card.addSubview(closeButton)

        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            imageView.topAnchor.constraint(equalTo: card.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snapshot: UIImage?, title: String, isActive: Bool, onClose: @escaping () -> Void) {
        self.onClose = onClose
        imageView.image = snapshot
        placeholder.isHidden = snapshot != nil
        titleLabel.text = title
        titleLabel.font = isActive ? .preferredFont(forTextStyle: .caption1).bold() : .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = isActive ? .label : .secondaryLabel
        card.layer.borderWidth = isActive ? 3 : 0
        card.layer.borderColor = isActive ? UIColor.tintColor.cgColor : UIColor.clear.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        placeholder.isHidden = false
    }

    @objc private func closeTapped() { onClose?() }
}
