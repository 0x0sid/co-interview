import Foundation

/// Default seed text for `PromptTextInputScreen`'s paste-a-script flow — long enough to actually
/// exercise auto-scroll and sustained tracking when read aloud. Editable/replaceable there, not a
/// fixed fixture; kept here as plain Foundation content with no UI dependency, same as the M1
/// replay fixtures in `Matching/`.
enum PromptDemoFixture {
    static let defaultScriptText = """
    Welcome to Prompter. This is a longer test script, written specifically so you have enough \
    material to read aloud and actually see the cursor track your voice across several \
    paragraphs, not just one or two lines.

    As you speak, the current sentence should highlight, the text you've already read should \
    fade to a quieter tone, and the page should scroll to keep up with you automatically. If you \
    pause for a moment, the cursor should hold steady and wait for you, rather than guessing \
    ahead. If you stop talking entirely for a couple of seconds, it should freeze in place \
    completely, the same way a person keeps eye contact with you when you look up from the page.

    Try reading at your normal pace first. Then try skipping a sentence on purpose, the way you \
    might if you lost your place, and see whether the cursor recovers and finds you again \
    further down the script. Try repeating a phrase you already said, too, and notice that it \
    doesn't jump backward very far even when you do.

    Finally, try an ad-lib: say a few words that aren't in this script at all, as if you went off \
    on a tangent mid-sentence. The cursor should hold its position rather than chasing your \
    off-script words somewhere else in the text, and should pick back up smoothly once you \
    return to reading what's actually written here.

    That's the whole test. Thanks for reading all the way to the end.
    """
}
