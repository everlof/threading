# Native chat review

Research checked 2026-09-10. This is a review record for the experimental native renderer on macOS and its iPhone mirror.

## Sources and decisions

| Primary open-source reference | What it demonstrates | Threading decision |
| --- | --- | --- |
| [assistant-ui](https://github.com/assistant-ui/assistant-ui), [thread anatomy](https://www.assistant-ui.com/elements/thread) | Separate message, work, composer and action primitives; actions recede during streaming. | Preserve the native virtual table and distinct message/work rows. Keep the answer visually ahead of its activity log. |
| [assistant-ui viewport](https://www.assistant-ui.com/docs/api-reference/runtimes/thread-runtime), [AI Elements conversation](https://elements.ai-sdk.dev/components/conversation) | Explicit follow mode, turn anchoring, and a way back to the latest message. | Preserve Threading's following/anchored/free state machine and momentum protection. A new decision must not drag somebody away from older text. |
| [Streamdown](https://github.com/vercel/streamdown) | Streaming Markdown must account for incomplete syntax, memoization and interactive blocks. | Do not parse/rebuild a whole growing answer on every token. Plain live text remains a limitation of this pass; rich Markdown is authoritative when a message settles. |
| [AI Elements confirmation](https://elements.ai-sdk.dev/components/confirmation), [tool UI](https://www.assistant-ui.com/docs/tools/tool-ui) | Waiting, accepted and rejected states belong to the individual request. | Questions, permissions and exhausted usage have distinct identities and actions. No inferred approval, timer-submitted answer or permission inferred from a question selection. |
| [AI Elements reasoning](https://elements.ai-sdk.dev/components/reasoning) | Reasoning/work is secondary content behind an explicit disclosure. | Reuse the native work fold, add keyboard operation and focus rather than another log surface. |
| [assistant-ui smooth reveal](https://www.assistant-ui.com/docs/api-reference/utilities/miscellaneous), [Stream accessibility](https://getstream.io/chat/docs/sdk/react/guides/accessibility/) | Reduced-motion behavior, coherent accessible names, keyboard operation and focus lifecycle. | Animate small state changes only. Keep content and completion truthful; do not delay a finished response to finish a typewriter effect. |
| [ChatLayout](https://github.com/ekazaev/ChatLayout/blob/master/README.md), [native layout contract](https://ekazaev.github.io/ChatLayout/Classes/CollectionViewChatLayout.html) | Self-sizing UIKit cells, visible-item anchoring and deliberate reload/reconfigure operations. Keyboard inset changes need their own coordination. | Keep the shipping collection and stable question IDs; invalidate the changed form's height and preserve drafts through cell reuse. Retain the existing keyboard/scroll owner. |
| [MessageKit performance guidance](https://github.com/MessageKit/MessageKit/blob/main/Documentation/FAQs.md) | Blocking database, keychain and network work in cell delegate methods damages scrolling. | Question layout and selection remain bounded memory-only operations; sending routes through the connection after validation. |

These are transferable interaction patterns, not a recommendation to embed a web chat or add its
JavaScript dependencies to an AppKit product. The exact source implementations remain upstream.

## Question transport

[Official app-server documentation](https://learn.chatgpt.com/docs/app-server) identifies
`item/tool/requestUserInput` and `serverRequest/resolved`. The local installed Codex CLI's
`app-server generate-ts --experimental` output supplies the exact question and answer fields,
including the newer `isBlocking` flag. Generated bindings are private review artifacts under
`.build/chat-protocol`, not an additional checked-in protocol implementation.

The question presentation is deliberately host-only: Threading owns exact question IDs, answer
validation, focus, cancellation, turn/process lifetime, and provider response routing. The
permission row keeps its existing protected extension hook; question input is not permission to
change files or use an account. Usage recovery keeps its existing host-owned ribbon and actions.

## Scaling contract

Normal chat: tens to hundreds of turns, 20 streaming updates per second. Stress: 1,000 turns and
500 tools in an unresolved turn, using the repository's existing native stress fixture. The table
continues to mount O(visible) rows. A disclosure mutates its stable presentation identities and
must not construct collapsed content. No new per-token animation or whole-history parse is added.

Question form: at most three pending requests, three questions per request, six choices per
question. Only the current question page owns views. IDs/labels cap at 200 UTF-8 bytes, question
and choice descriptions at 2,000, each answer at 8,000. Malformed, oversized and secret requests
are refused explicitly instead of silently shortening the question. No provider call or file
operation runs in layout, focus or selection callbacks.

## Review scenarios

Each capture runs the real `ConversationViewController` and its virtualized transcript. IDs are
stable `native-chat-<state>-<theme>-<appearance>`, independent of provider request IDs. Separate
scenarios cover rich answers, active work, permission, usage refusal, interruption and streaming;
new question scenes cover the form and its selected state. System light/dark, Cyberpunk and
Swiss Minimalist exercise adaptive and authored themes.

Run `scripts/ui-evidence.sh --only native-chat-showcase` to regenerate the review. Existing
approved baselines require human review; generating this evidence does not accept new pixels.

## iPhone validation

The iPhone uses the shipping UIKit conversation route and virtual collection. Question metadata
has a separate ID space from permission cards; only current, authorized reply-capable clients
with input control may answer. Exact answers pass through the host validation again. The phone
stops its working orb for either blocking decision and observes that metadata independently of
streaming or composer availability. Diffable insertions honor Reduce Motion.

`conversation-question-*` scenarios cover custom dark, System dark, Swiss light, accessibility
text size and read-only state. Existing content-type, streaming, away-from-latest and permission
fixtures provide matched before/after comparisons in the ordinary iOS evidence runner.

The mobile review also exercises the iPhone SE (3rd generation), actual selection/cancellation
taps, and the largest accessibility content size. That exposed and fixed two layout issues:
symbols scaling beyond their fixed touch targets, and the composer placeholder extending into
the send button. Read-only clients can page through every question without gaining answer rights.

## What changed

| Before | After |
| --- | --- |
| Native Codex input requests had no inline question presentation. | Bounded, paged question cards on Mac and iPhone preserve exact request/question IDs and require an explicit answer. |
| The work status could continue to look busy during a permission decision. | Blocking questions and permissions stop the working animation/clock and name the action needed. Nonblocking questions keep the working state. |
| A drawn button could appear in the accessibility tree but return no hit at its visible position. | The shared control base supplies the missing cell-free hit, bounded by visibility; the app journey exercises Next and Send with real clicks. |
| The embedded changed-file table could grow through its card padding. | Plain embedded tables fit their own bounds, keeping line counts within the card. |
| A permission card led with the tool name and warning chrome. | Shared decision hierarchy names the request, shows the exact action, and gives its buttons distinct emphasis. |
| The conversation work fold was operated by a click gesture. | The existing design-system disclosure handles keyboard, focus and accessibility, with a short local chevron transition. |
| The iPhone's largest text could overwhelm icon targets and composer space. | Fixed symbol sizing, wrapping question text, vertical actions and a bounded placeholder keep the controls usable. |

The review package is generated under `.build/flow-review` with the existing evidence report
generator. Its comparison baseline is the starting commit `66a833f69`, not a newly accepted product
baseline. Eight initial adaptive System-light fixture images had mixed appearances and are
excluded from comparison; the corrected light captures are additional coverage. Their pixels
must not be presented as a product before/after improvement.

Live Markdown still uses plain text until settlement. Secret-input questions are refused rather
than rendered in an ordinary field. Physical-device pairing and a live provider-account round trip
are outside the recorded simulator and deterministic provider-fixture evidence.
