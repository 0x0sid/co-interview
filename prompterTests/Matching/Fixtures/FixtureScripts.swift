import Foundation

/// Four hand-written scripts (200-600 words, multiple paragraphs each) used as the ground truth
/// for the M1 fixture suite (§10.5, §16). Blank lines separate paragraphs so
/// `ScriptIndex.build(from:)`'s `.byParagraphs` segmentation has real boundaries to find, and the
/// "paragraph skip" fixture has somewhere real to skip to.
enum FixtureScripts {
    /// ~300 words, 4 paragraphs. Contains "going to" so the misrecognition fixture can exercise
    /// the "gonna"-style contraction corruption rule.
    static let productLaunch = """
    Today we are going to show you something we have been building for the last year. It is a \
    small device that fits in your pocket, and it is going to change the way you think about \
    your morning routine. We built it because we were tired of juggling five different apps \
    just to get out the door on time.

    The idea started on a napkin during a rainy afternoon in October. Two of our engineers were \
    stuck at the airport, and they realized that every travel app they owned was fighting for \
    their attention instead of working together. So they sketched a simpler version, one screen, \
    one button, and no notifications unless something actually mattered.

    Over the following months the team tested more than forty prototypes. Some were too heavy, \
    some drained the battery in a single afternoon, and one memorable version could not survive \
    a light rain shower. Each failure taught us something we could not have learned any other \
    way, and slowly the design became lighter, quieter, and far more durable.

    What you are looking at today is the result of that work. It ships next month, it is priced \
    fairly, and every part of it was designed to disappear into your daily life rather than \
    demand your attention. We think that is what good technology should do, and we cannot wait \
    for you to try it.
    """

    /// ~250 words, 3 paragraphs.
    static let cookingIntro = """
    Welcome back to the kitchen. Today we are making a rustic tomato soup that only needs six \
    ingredients and about forty minutes from start to finish. It is the kind of recipe you can \
    make on a weeknight without thinking too hard, and it tastes like it took all day.

    Start by roasting the tomatoes with a little olive oil, salt, and a few cloves of garlic \
    still in their skins. Roasting brings out a sweetness that boiling never quite reaches, and \
    the garlic turns soft and mellow instead of sharp. While that is in the oven, chop one onion \
    and let it soften slowly in a wide pot over low heat.

    Once the tomatoes are blistered and the garlic is golden, squeeze the cloves out of their \
    skins and add everything to the pot along with a splash of stock. Simmer for fifteen minutes, \
    blend until smooth, and finish with a swirl of cream and a handful of torn basil right before \
    serving. Simple food, done properly, is still the best food there is.
    """

    /// ~400 words, 4 paragraphs.
    static let personalEssay = """
    I moved to this city eight years ago with two suitcases and a job that lasted exactly four \
    months. I did not know a single person, and for the first few weeks I ate dinner standing up \
    in my kitchen because I had not yet bought a table. Looking back, that stretch of \
    uncertainty taught me more than any of the years that came after it.

    The turning point was small and almost embarrassing. I got lost trying to find a hardware \
    store and ended up asking a stranger for directions. She was walking the same way, so we \
    talked for twenty minutes, and by the end of it she had invited me to a dinner with six \
    people I had never met. Three of them are still close friends today.

    That is the part nobody tells you about starting over somewhere new. It rarely happens in one \
    dramatic moment. It happens in a hundred small ones, a conversation at a bus stop, a \
    coworker who remembers your coffee order, a neighbor who waters your plants without being \
    asked. Each one seems tiny until you add them up and realize they built the life you are \
    actually living.

    So if you are in that uncomfortable stretch right now, eating standing up in an empty \
    kitchen, I promise it does not last as long as it feels like it will. Say yes to the dinner. \
    Ask the stranger for directions. The city will not introduce itself to you, but it will \
    absolutely meet you halfway.
    """

    /// ~350 words, 4 paragraphs.
    static let techExplainer = """
    Every phone you own is constantly making a trade-off between battery life and how quickly it \
    responds to you, and most people never see that trade-off happen. It is decided thousands of \
    times a day by a small piece of software called a scheduler, and understanding it explains a \
    surprising amount of why your phone feels fast some days and sluggish on others.

    A scheduler's job is to decide which task gets the processor next. Your messaging app wants \
    to check for new messages, your weather widget wants to update, and some background service \
    wants to sync your photos, all at roughly the same moment. The scheduler has to pick an \
    order, and the order it picks changes how warm the phone gets and how long the battery lasts \
    until dinner.

    Modern chips make this easier by offering several types of processor cores on the same piece \
    of silicon. Small, efficient cores handle the constant low-effort work, checking a clock or \
    listening for a notification, while larger, faster cores wake up only when something \
    genuinely demands them, like opening a camera or loading a video. The scheduler's real skill \
    is knowing which core a task actually deserves.

    None of this is visible to you as a user, which is exactly the point. Good scheduling is \
    invisible scheduling. You only notice it when it fails, when the phone gets hot in your \
    pocket for no reason or the battery is somehow gone by lunchtime. The best compliment a \
    scheduler can receive is that nobody ever thinks about it at all.
    """

    static let all: [(name: String, text: String)] = [
        ("productLaunch", productLaunch),
        ("cookingIntro", cookingIntro),
        ("personalEssay", personalEssay),
        ("techExplainer", techExplainer),
    ]
}
