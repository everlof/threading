import AppKit

/// The opening composer's shared view tree. Each host supplies its controls and greeting;
/// this view owns the choice row, bottom-flush column and the room above it for the greeting.
@MainActor
final class OpeningComposerContentView: NSView {
    enum HeroPlacement {
        case centered
        case fill
    }

    let choices = NSStackView()
    let column = NSStackView()
    let heroRegion = NSLayoutGuide()
    private var mountedBottom: NSLayoutConstraint?
    var bottomConstraint: NSLayoutConstraint {
        guard let mountedBottom else { preconditionFailure("opening column is not mounted") }
        return mountedBottom
    }

    init(choiceViews: [NSView], beforePrompt: [NSView] = [], prompt: NSView,
         actionRow: NSView, hero: NSView, heroPlacement: HeroPlacement = .centered) {
        super.init(frame: .zero)

        let spacer = NSView()
        PromptChrome.configureOpeningChoices(choices, choices: choiceViews, spacer: spacer)
        PromptChrome.configureOpeningColumn(column, choices: choices,
            beforePrompt: beforePrompt, prompt: prompt, actionRow: actionRow)
        mountedBottom = PromptChrome.mountOpeningColumn(column, in: self,
            prompt: prompt, actionRow: actionRow)
        addLayoutGuide(heroRegion)
        hero.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hero)

        NSLayoutConstraint.activate([
            choices.widthAnchor.constraint(equalTo: column.widthAnchor),
            heroRegion.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            heroRegion.bottomAnchor.constraint(equalTo: column.topAnchor),
            heroRegion.leadingAnchor.constraint(equalTo: leadingAnchor),
            heroRegion.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        switch heroPlacement {
        case .centered:
            NSLayoutConstraint.activate([
                hero.centerXAnchor.constraint(equalTo: heroRegion.centerXAnchor),
                hero.centerYAnchor.constraint(equalTo: heroRegion.centerYAnchor),
                hero.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                    constant: Design.Spacing.pane),
                hero.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                    constant: -Design.Spacing.pane)
            ])
        case .fill:
            NSLayoutConstraint.activate([
                hero.topAnchor.constraint(equalTo: heroRegion.topAnchor),
                hero.bottomAnchor.constraint(equalTo: heroRegion.bottomAnchor),
                hero.leadingAnchor.constraint(equalTo: heroRegion.leadingAnchor),
                hero.trailingAnchor.constraint(equalTo: heroRegion.trailingAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
