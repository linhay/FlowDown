//
//  ChatView.swift
//  FlowDown
//
//  Created by 秋星桥 on 1/20/25.
//

import Combine
import ConfigurableKit
import GlyphixTextFx
import RichEditor
import SnapKit
import Storage
import UIKit

class ChatView: UIView {
    var conversationIdentifier: Conversation.ID? = nil
    var cancellables: Set<AnyCancellable> = .init()

    let handlerColor: UIColor = .init {
        switch $0.userInterfaceStyle {
        case .light:
            .white
        default:
            .gray.withAlphaComponent(0.1)
        }
    }

    #if !targetEnvironment(macCatalyst)
        let escapeButton = EasyHitImageCircleButton(name: "sidebar.left", distinctStyle: .none)
    #endif

    let editor = RichEditorView()
    let editorBackgroundView = UIView().with {
        $0.backgroundColor = .background
        let sep = SeparatorView()
        $0.addSubview(sep)
        sep.snp.makeConstraints { make in
            make.left.top.right.equalToSuperview()
            make.height.equalTo(1)
        }
    }

    let sessionManager = ConversationSessionManager.shared
    private var messageListViews: [Conversation.ID: MessageListView] = [:]
    var currentMessageListView: MessageListView? {
        guard let id = conversationIdentifier else {
            return nil
        }
        if let listView = messageListViews[id] {
            return listView
        }

        // If the message list view is not found, create a new one.
        let listView = MessageListView()
        listView.session = sessionManager.session(for: id)
        messageListViews[id] = listView
        return listView
    }

    @BareCodableStorage(key: "Chat.Editor.Model.Name.Style", defaultValue: EditorModelNameStyle.trimmed)
    var editorModelNameStyle: EditorModelNameStyle {
        didSet { editor.updateModelName() }
    }

    @BareCodableStorage(key: "Chat.Editor.Model.Apply.Default", defaultValue: true)
    var editorApplyModelToDefault: Bool

    let title = TitleBar()

    var onCreateNewChat: (() -> Void)?
    var onSuggestNewChat: ((Conversation.ID) -> Void)?

    init() {
        super.init(frame: .zero)

        addSubview(editorBackgroundView)
        addSubview(editor)

        #if !targetEnvironment(macCatalyst)
            addSubview(escapeButton)
            defer { bringSubviewToFront(escapeButton) }
        #endif

        addSubview(title)

        editor.handlerColor = handlerColor
        editor.delegate = self
        editor.snp.makeConstraints { make in
            make.bottom.equalToSuperview()
            make.centerX.equalToSuperview()
            make.width.lessThanOrEqualTo(750)
            make.width.lessThanOrEqualToSuperview()
            make.width.equalToSuperview().priority(.low)
        }

        editorBackgroundView.snp.makeConstraints { make in
            make.bottom.left.right.equalToSuperview()
            make.top.equalTo(editor.snp.top).offset(-10)
        }

        #if !targetEnvironment(macCatalyst)
            escapeButton.backgroundColor = .clear
            escapeButton.snp.makeConstraints { make in
                make.top.equalTo(safeAreaLayoutGuide).inset(10)
                make.leading.equalTo(safeAreaLayoutGuide).inset(10)
                make.width.height.equalTo(40)
            }
            title.snp.makeConstraints { make in
                make.left.top.right.equalToSuperview()
                make.bottom.equalTo(escapeButton).offset(10)
            }
        #else
            title.snp.makeConstraints { make in
                make.left.top.right.equalToSuperview()
            }
        #endif

        title.onCreateNewChat = { [weak self] in
            self?.onCreateNewChat?()
        }
        title.onSuggestSelection = { [weak self] id in
            self?.onSuggestNewChat?(id)
        }

        editor.heightPublisher
            .ensureMainThread()
            .sink { [weak self] _ in
                self?.setNeedsLayout()
            }
            .store(in: &cancellables)

        Self.editorModelNameStyle.onChange
            .compactMap { try? $0.decodingValue() }
            .compactMap { EditorModelNameStyle(rawValue: $0) }
            .sink { [weak self] output in self?.editorModelNameStyle = output }
            .store(in: &cancellables)

        Self.editorApplyModelToDefault.onChange
            .compactMap { try? $0.decodingValue() }
            .sink { [weak self] output in self?.editorApplyModelToDefault = output }
            .store(in: &cancellables)

        ConversationManager.removeAllEditorObjectsPublisher
            .ensureMainThread()
            .sink { [weak self] _ in
                let id = self?.conversationIdentifier
                self?.prepareForReuse()
                guard let id else { return }
                self?.use(conversation: id)
            }
            .store(in: &cancellables)

        ModelManager.shared.modelChangedPublisher
            .ensureMainThread()
            .sink { [weak self] _ in
                self?.editor.updateModelName()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func focusEditor() {
        editor.focus()
    }

    func prepareForReuse() {
        // Removes the current message list view from the superview.
        currentMessageListView?.removeFromSuperview()
        conversationIdentifier = nil
        editor.prepareForReuse()
    }

    func use(conversation: Conversation.ID, completion: (() -> Void)? = nil) {
        if conversationIdentifier == conversation {
            completion?()
            return
        }
        conversationIdentifier = conversation
        if let listView = currentMessageListView {
            insertSubview(listView, belowSubview: editorBackgroundView)
            listView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        editor.use(identifier: conversation)
        title.use(identifier: conversation)

        offloadModelsToSession(modelIdentifier: modelIdentifier())
        removeUnusedListViews()
        DispatchQueue.main.async {
            completion?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        currentMessageListView?.contentSafeAreaInsets = .init(
            top: title.frame.maxY + 16,
            left: 0,
            bottom: bounds.height - editor.frame.minY + 16,
            right: 0
        )
    }

    private func removeUnusedListViews() {
        let conversationIDs = sdb.listConversations().map(\.id)
        let unusedKeys = messageListViews.keys.filter { !conversationIDs.contains($0) }

        for key in unusedKeys {
            messageListViews.removeValue(forKey: key)?.removeFromSuperview()
        }
    }
}

extension ChatView {
    class TitleBar: UIView {
        let stack = UIStackView().with {
            $0.axis = .horizontal
            $0.spacing = 16
            $0.alignment = .center
            $0.distribution = .fill
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let textLabel: GlyphixTextLabel = .init().with {
            $0.font = .preferredFont(forTextStyle: .body).bold
            $0.isBlurEffectEnabled = false
            $0.textColor = .label
            $0.textAlignment = .center
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.clipsToBounds = false
        }

        let label: UIView = .init()

        let icon = UIImageView().with {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .accent
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.snp.makeConstraints { make in
                make.width.height.equalTo(24)
            }
        }

        let menuButton = EasyMenuButton().with {
            $0.image = UIImage(systemName: "chevron.down")
            $0.tintColor = .gray.withAlphaComponent(0.5)
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.snp.makeConstraints { make in
                make.width.height.equalTo(18)
            }
        }

        let bg = UIView().with { $0.backgroundColor = .background }
        let sep = SeparatorView()

        let rightClick = RightClickFinder()
        var cancellables: Set<AnyCancellable> = .init()

        var onCreateNewChat: (() -> Void)?
        var onSuggestSelection: ((Conversation.ID) -> Void)?

        init() {
            super.init(frame: .zero)

            label.addSubview(textLabel)
            textLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
            }

            addSubview(bg)
            bg.snp.makeConstraints { make in
                make.left.bottom.right.equalToSuperview()
                make.top.equalToSuperview().offset(-128)
            }

            addSubview(stack)
            stack.snp.makeConstraints { make in
                make.edges.equalToSuperview().inset(20)
            }

            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(menuButton)

            #if !targetEnvironment(macCatalyst)
                icon.alpha = 0
            #endif

            addSubview(sep)
            sep.snp.makeConstraints { make in
                make.left.right.equalToSuperview()
                make.bottom.equalToSuperview()
                make.height.equalTo(1)
            }

            let gesture = UITapGestureRecognizer(target: self, action: #selector(tapped))
            #if targetEnvironment(macCatalyst)
                menuButton.addGestureRecognizer(gesture)
                menuButton.isUserInteractionEnabled = true
            #else
                addGestureRecognizer(gesture)
                isUserInteractionEnabled = true
            #endif
            rightClick.install(on: self) { [weak self] in self?.tapped() }

            ConversationManager.shared.conversations
                .ensureMainThread()
                .sink { [weak self] _ in
                    self?.use(identifier: self?.conv)
                }
                .store(in: &cancellables)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        deinit {
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
        }

        private var conv: Conversation.ID?

        func use(identifier: Conversation.ID?) {
            conv = identifier
            let conversation = ConversationManager.shared.conversation(identifier: identifier)
            textLabel.text = conversation?.title ?? String(localized: "Untitled")
            icon.image = conversation?.interfaceImage
        }

        @objc func tapped() {
            guard let conv else { return }
            guard let convMenu = ConversationManager.shared.menu(
                forConversation: conv,
                view: self,
                suggestNewSelection: onSuggestSelection ?? { _ in }
            ) else { return }
            #if targetEnvironment(macCatalyst)
                menuButton.present(menu: convMenu)
            #else
                menuButton.present(menu: .init(
                    children: [
                        UIMenu(
                            options: [.displayInline],
                            children: [
                                UIAction(
                                    title: String(localized: "Start New Chat"),
                                    image: UIImage(systemName: "plus")
                                ) { [weak self] _ in
                                    self?.onCreateNewChat?()
                                },
                            ]
                        ),
                        convMenu,
                    ]
                ))
            #endif
        }
    }
}

extension ChatView.TitleBar {
    class EasyMenuButton: UIImageView {
        open var easyHitInsets: UIEdgeInsets = .init(top: -16, left: -16, bottom: -16, right: -16)

        override open func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
            bounds.inset(by: easyHitInsets).contains(point)
        }
    }
}
