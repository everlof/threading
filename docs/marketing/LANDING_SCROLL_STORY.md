# Landing-page scroll story

The landing page should demonstrate one coherent use of the product while the
visitor scrolls. It should not be a feature carousel or a scroll-jacked video.

## Recommendation

Use GSAP with ScrollTrigger for the desktop narrative. It has the pinning,
scrubbing, timeline labels, snapping controls, and responsive lifecycle needed
for a directed product walkthrough.

Keep browser scrolling native. Do not add a smooth-scroll replacement.

Use Motion only for small component transitions outside the main tour. Native
CSS scroll timelines can progressively enhance simple progress indicators, but
they should not own the core story.

## Storyboard

The product frame remains sticky while five short chapters move through it:

1. **Start the work.** A project opens with several sessions already active.
2. **Follow the signal.** Routine progress recedes; one session changes to
   Needs you.
3. **Make the decision.** The conversation opens at a scoped permission
   request and the user approves it.
4. **See the delegation.** A subagent tree expands and returns focused results.
5. **Review the outcome.** The view moves to Git review, then hands the same
   conversation to the iPhone companion.

Copy beside the frame changes at the same named timeline labels. The product
frame should do most of the explaining.

## Media model

Do not make the whole section one long video. Use real product media in layers:

- a real full-frame screenshot for each chapter;
- short recordings only for meaningful movement inside a chapter;
- crossfades, masks, and modest camera moves between scenes;
- the iPhone capture as a separate foreground layer in the handoff chapter.

GSAP controls the chapter timeline and, where useful, the current time of a
short recording. This keeps text selectable, allows responsive composition,
and avoids making the experience depend on continuous video seeking.

## Responsive behavior

- Desktop: pin the product frame for roughly five viewport heights and scrub
  between labeled chapters.
- Tablet: keep the sticky frame but reduce camera movement and chapter length.
- Mobile: do not pin a full-height canvas. Present the same scenes as a normal
  vertical sequence with light crossfades.
- Reduced motion: show the five static captures with no pinning or scrubbed
  media.

## Performance budget

- Load the first chapter image with the page.
- Preload the next chapter only when the tour approaches the viewport.
- Keep the initial product image under roughly 250 KB.
- Keep the complete desktop tour below roughly 3 MB before optional recordings.
- Never download desktop recordings on the reduced-motion or mobile paths.

## Build order

1. Capture the seven real product scenes.
2. Approve the visual sequence and copy as static frames.
3. Implement the responsive sticky layout.
4. Add the ScrollTrigger timeline.
5. Add short recordings only where static scene transitions fail to explain
   the interaction.
6. Test keyboard navigation, reduced motion, touch scrolling, and low-power
   Safari before polishing timing.

