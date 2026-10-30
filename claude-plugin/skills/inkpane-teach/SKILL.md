---
name: inkpane-teach
description: Teach, guide or explain visually on the user's real screen with Inkpane - circle the control to click, add arrows and short labels, number the steps, sketch diagrams on a whiteboard, and take screenshots to check the user's progress. Use when the user asks how to do something in an app on their computer, wants a walkthrough, asks "where is…", or when an explanation (a data flow, an architecture, how something works) would be clearer drawn. Needs the inkpane MCP tools.
---

# Teaching on the user's screen with Inkpane

Inkpane draws on top of everything on the user's screen. You point; **the user does
every click and keystroke themselves**. That is the point: people learn by doing, and
you cannot change anything on their system through Inkpane.

## Before you start

- **Ask once before the first screenshot** in a session ("May I look at your screen to
  show you where things are?"), unless the user already said screenshots are fine or
  asked you to look. A screenshot sends the user's screen to you. If they say no,
  explain in words, or draw on the whiteboard instead.
- Say so in one short line whenever you take a screenshot ("Taking a look…").
- Call `screen_info` once if there could be several monitors. Use the monitor the app
  is on; ask if you can't tell.

## The step loop

Never draw a whole procedure at once. For each step:

1. **Look**: `screenshot`. Coordinates are that image's pixels, origin top-left.
2. **Point at one thing** (see "Marks" below): usually one circle or arrow plus a label
   of 2–4 words, or a step marker.
3. **Explain in chat**, briefly: what to do and *why*. The screen shows *where*; the
   chat says *why*. Never put explanations on screen.
4. **Wait**: end your turn and ask the user to say "done" (or describe what happened)
   when they've done it.
5. **Check**: `screenshot` again. If it worked, `clear` and go to the next step. If not,
   see "When something goes wrong".

When the task is done: `clear`, sum up in a sentence or two, and offer to repeat any step.

## Marks

- **Circle a control**: `circle` with the control's own box `[left, top, right,
  bottom]`, read off the screenshot. Inkpane makes the ellipse big enough to frame it
  (an ellipse drawn on the control's own corners would cut through them). Give it a
  `label` and a `label_side` and the label is placed just outside the circle: pick the
  side where the screenshot shows **empty space** (a window margin, blank panel area, the
  desktop), never a side with buttons, list rows or text. Prefer this; it is the most
  forgiving mark.
- **Arrow**: from empty space towards the target; the head (second point) stops just
  short of the edge of what it points at. Use it when the target is small or crowded.
- **Label**: `add_text` placed in empty space next to the mark, never over the thing
  being marked or over text the user has to read. 2–4 words: "Click here", "Your
  Wi-Fi name", "Not this one". `x`, `y` is the label's top-left corner. Leave a gap of
  about 10 px from the circle; on a busy screen (lists, toolbars) put it beside the
  circle in an empty margin rather than under it, or point to it with a short arrow
  from a label in empty space.
- **Step markers** (`add_step_marker`) number things in order: 1, 2, 3. Use them to
  show the order of several clicks the user should do in one go, or to label parts of a
  screen while you explain them in chat ("1 is the search box, 2 …").
- **Highlighter**: a straight bar over one line of text ("read this line"). Use yellow.
- **Rectangle**: a whole region ("everything in this panel").
- **At most about three marks on screen.** Clear before the next step; `undo_last`
  removes just your latest mark.

### Colours (keep them consistent)

- **green**: do this / the right place
- **blue**: look here / information
- **orange** or **yellow** (highlighter): attention to a line of text
- **red**: a mistake, or "not this one". Nothing else.

On a light window, all of these show well; on very dark or very bright areas Inkpane adds
contrast to text automatically.

### Accuracy

Your coordinates come from your reading of the screenshot, which can be a few pixels
off. So:

- Prefer **generous circles** to precise underlines.
- For a small target in a crowded area, combine an arrow with a label naming it
  ("the gear icon").
- After drawing anything important, take a screenshot and look: if the mark is off,
  `undo_last` and draw it again. Don't apologise at length; just fix it.

## Making a tutorial

When the user asks you to *make a tutorial* (a guide others can follow later, e.g.
"read AppGlider's user guide and make a tutorial for adding a GitHub repo"):

1. **Research**: read the docs, the user guide or the code you're pointed at, so the
   steps are right. Note the exact names of buttons and fields.
2. **Plan**: list the steps (usually 4–8) in chat, with where the files will go
   (default `./tutorial-<topic>/`), and ask the user to confirm. Ask them to open the
   app at its starting screen, and mention that they can start a screen recorder
   (Spectacle, OBS) now if they want a video: your marks will be in it.
3. **Each step**, one at a time:
   - `screenshot`, then find the control and the app window's edges.
   - `callout` with the step number, one or two sentences (what to do and why), and a
     `side` with empty space; add a `circle` around the control when it is small.
   - `save_screenshot` to `step-NN.png`, with `region` set to the app's window plus a
     small margin, so nothing else of the user's desktop is in the tutorial.
   - Tell the user in chat what to do, and wait for "done" (or do it yourself if
     clicking tools are available and the user allowed it).
   - `screenshot` to check it worked, then `clear` before the next step.
4. **Result**: after the last step, save a final screenshot of the finished state, then
   write `tutorial.md` in the same folder: a title, one line on what it achieves, any
   requirements, then for each step a heading ("2. Open the Updates page"), the
   instruction as a sentence or two, and its image (`![Step 2](step-02.png)`), and a
   short "Done" section. Use the app's own words for buttons, in bold.
5. Offer extras only if wanted: a slideshow video of the images with ffmpeg, or an
   HTML version.

Callout text in a tutorial is written for the reader of the tutorial, not for the user
in front of you: "Click **Updates** in the sidebar to see apps with new versions."

## Whiteboard explanations

For ideas no app shows (how data flows, what a git branch is, how DNS resolves a name),
put up a board with `set_board` (`"whiteboard"`, or `"blackboard"` if the user prefers
dark). **The board hides the whole screen, including your chat with the user**, so the
board must teach on its own: the user reads it, not the chat. Their keyboard goes to
Inkpane, and a hint at the bottom tells them how to get back (Ctrl+W / Ctrl+B, or Esc
to close).

Make it look designed, like a good slide or a tidy Excalidraw sketch, not a plain
wireframe. The board is about 1568 × 656 (see `screen_info`). Lay it out on a grid:

```
 40 ┌ Title (size 30, ink) ───────────────────────────────┐
    │ accent line under it (3 px, the main colour)         │
110 │ ┌─ diagram area: x 40–1000 ──────────┐ ┌ notes panel ┐
    │ │ cards, arrows, step markers        │ │ x 1040–1528 │
    │ └────────────────────────────────────┘ └─────────────┘
560 │ ┌ key idea callout, full width or under the diagram ┐
    └────────────────────────────────────────────────────────┘
```

**Colours on a whiteboard** (use hex; keep to these so it looks consistent):

| Role | Fill (`fill_color`) | Outline (`color`) |
|---|---|---|
| The user / their device | `#dbeafe` | `#2563eb` |
| A service or server | `#ede9fe` | `#7c3aed` |
| Data, files, results | `#dcfce7` | `#16a34a` |
| Something that can go wrong | `#fee2e2` | `#dc2626` |
| Neutral / background thing | `#f1f5f9` | `#64748b` |
| Key idea callout | `#fef9c3` | `#ca8a04` |

- **Ink** for text: `#1e293b`; secondary text (arrow labels): `#475569`.
- **Cards**: `draw` `rectangle` with `fill_color` + `color` from the table, `width` 2,
  `label` the thing's name, `label_color` `#1e293b`, `size` 18. About 190 × 70 px.
  Use `ellipse` cards for start/end, `diamond` for a decision.
- **Arrows**: `#475569`, `width` 3; the flow you are explaining right now in the
  main colour. Leave 12 px between an arrow's ends and the cards it joins. Caption an
  arrow with its own `label` (size 15, `label_color` `#475569`): Inkpane places it
  beside the middle, clear of the line, so don't position arrow captions with
  `add_text`. Keep captions to a few words, and arrows long enough for them (150+ px).
  Two arrows between the same cards: run them 40+ px apart, not on top of each other.
- **Step markers** (`add_step_marker`, radius 13, the main colour) a quarter of the way
  along each arrow from its tail, 18 px to the side: the middle is the label's.
- **Arrange cards in rows and columns** so arrows run level or upright; avoid diagonal
  arrows. For a request and its reply, use two level arrows 36–44 px apart (request on
  top, pointing right; reply below, pointing left), each with its label: the top one's
  label lands above it, the bottom one's between the two, so keep them that far apart.
- **Title**: `add_text` size 30, ink, at (40, 34); then a `line` under its left part,
  3 px, in the main colour, about 160 px long, 12 px below the text.
- **Notes panel**: a card at (1040, 110)–(1528, 540) with fill `#f8fafc`, outline
  `#cbd5e1`, `width` 1.5, no label. Heading "How it works" (size 20, ink) at (1064, 126).
  Then one note per step from y 170, `add_text` size 16, ink, `max_width` 430,
  starting "1. ", "2. " …, 16 px apart (the tool says how tall each was).
- **Key idea**: a callout card (yellow row of the table) with one sentence, `label`
  size 17, along the bottom.
- Whitespace is design: align cards on a row or column, same sizes, equal gaps; leave
  the margins (40 px) empty. Never let text touch a line or another text.

On a **blackboard** use the same layout with fills `#1e293b`, outlines in bright
colours (`#60a5fa`, `#a78bfa`, `#4ade80`, `#f87171`, `#facc15`) and ink `#f1f5f9`.

Build it **in teaching order**: title, then the first card, its arrow and its note,
then the next part. The user watches it grow, like a teacher at a board.

In the chat, say just one line, such as "The diagram is on your whiteboard. Press
Ctrl+W to get back to your desktop." The explanation lives on the board. When the user
comes back with questions, you can add to the same board or `clear` it and draw again.

The whiteboard needs no screenshots, so it works even if the user declined them.

Write text with plain characters: the user's font may lack symbols such as arrows,
ticks or emoji (Inkpane turns → into ->). Draw an arrow instead of typing one.

## When something goes wrong

- **The user clicked the wrong thing**: screenshot, circle the right control in green,
  and if useful mark the wrong one in red with "not this". Explain the difference in
  one sentence.
- **The screen changed** (a dialog opened, the window moved): your old marks are now in
  the wrong place: `clear`, screenshot, and mark again.
- **A tool returns an error** (Inkpane not running, no permission for screenshots): tell
  the user plainly what it says. The first screenshot may show a desktop dialog asking
  to allow Inkpane to take screenshots; ask the user to allow it.

## Things to avoid

- Drawing every step at once, or more than ~3 marks.
- Long text on screen. Labels are short; explanations go in chat.
- Marks covering the thing they point at, or covering text the user must read.
- Taking screenshots without saying so, or when not teaching.
- `close`: it also wipes the user's own drawing. Only when the user says they're done.
- `clear` with `scope: "all"` unless the user asks: it removes their drawing too.
